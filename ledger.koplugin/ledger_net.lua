--[[
Network calls for the Reading Ledger. Everything here runs inside a Bg.run
child (see ledger_bg.lua): no UIManager, no widgets, no settings writes --
only HTTP, files in the Ledger's own cache folder, and plain return values.

Two independent sources, neither going through anyone's server:
  * Open Library -- trending lists, no key or account.
  * Hardcover    -- only with the reader's own API key.
--]]

local JSON = require("json")
local http = require("socket.http")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local Net = {}

local HARDCOVER_URL = "https://api.hardcover.app/v1/graphql"
local OPENLIBRARY = "https://openlibrary.org"

-- JSON null decodes to KOReader's null sentinel (a truthy function); treat
-- anything that isn't the expected type as absent.
local function str(v) return type(v) == "string" and v ~= "" and v or nil end
local function num(v) return type(v) == "number" and v or nil end

local function request(method, url, headers, body, block_timeout, total_timeout)
    socketutil:set_timeout(block_timeout or 10, total_timeout or 30)
    local sink_t = {}
    local req = {
        method = method, url = url, headers = headers or {},
        sink = ltn12.sink.table(sink_t),
        source = body and ltn12.source.string(body) or nil,
    }
    local requester = url:match("^https:") and https or http
    local ok, code = pcall(function() return socket.skip(1, requester.request(req)) end)
    socketutil:reset_timeout()
    if not ok then return nil, "connection error: " .. tostring(code) end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    return table.concat(sink_t)
end

local function getJSON(url)
    local body, err = request("GET", url, { ["Accept"] = "application/json" })
    if not body then return nil, err end
    local ok, d = pcall(JSON.decode, body)
    if not ok or type(d) ~= "table" then return nil, "bad JSON" end
    return d
end

-- Downloads url to path unless it's already there. Returns path or nil.
function Net.fetchFile(url, path)
    if lfs.attributes(path, "mode") == "file" then return path end
    local body = request("GET", url, nil, nil, 10, 20)
    if not body or #body < 200 then return nil end
    local tmp = path .. ".part"
    local f = io.open(tmp, "wb")
    if not f then return nil end
    f:write(body); f:close()
    os.rename(tmp, path)
    return path
end

-- A cover for a book that has none of its own (or isn't on this device),
-- from Open Library: its search by title and author, the first edition
-- there with a cover. -> path of the downloaded image, or nil when Open
-- Library has none (nil, err when it couldn't be asked).
local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+"))
end

function Net.openLibraryCover(title, author, covers_dir)
    if not title or title == "" or not covers_dir then return nil end
    local url = string.format("%s/search.json?title=%s%s&fields=cover_i&limit=5", OPENLIBRARY,
        urlencode(title), author and author ~= "" and ("&author=" .. urlencode(author)) or "")
    local d, err = getJSON(url)
    if not d then return nil, err end
    for _, doc in ipairs(type(d.docs) == "table" and d.docs or {}) do
        local id = num(doc.cover_i)
        if id then
            return Net.fetchFile(string.format("https://covers.openlibrary.org/b/id/%d-M.jpg", id),
                string.format("%s/ol-%d.jpg", covers_dir, id))
        end
    end
    return nil
end

-- Open Library trending. period: "daily" | "weekly" | "monthly".
-- (Its subject search sorted by trending returns anthologies and classics,
-- so there is no per-genre list.)
function Net.openLibraryTrending(period, limit, covers_dir)
    limit = limit or 8
    local url = string.format("%s/trending/%s.json?limit=%d", OPENLIBRARY, period or "weekly", limit)
    local list_key = "works"
    local d, err = getJSON(url)
    if not d then return nil, err end
    local out = {}
    for _, w in ipairs(d[list_key] or {}) do
        local title = str(w.title)
        if title then
            local authors = type(w.author_name) == "table" and w.author_name or {}
            local item = {
                title = title,
                author = str(authors[1]),
                year = num(w.first_publish_year),
                key = str(w.key),
                cover_id = num(w.cover_i),
            }
            if item.cover_id and covers_dir then
                item.cover = Net.fetchFile(
                    string.format("https://covers.openlibrary.org/b/id/%d-M.jpg", item.cover_id),
                    string.format("%s/ol-%d.jpg", covers_dir, item.cover_id))
            end
            out[#out + 1] = item
        end
    end
    return out
end

function Net.hardcover(token, query, variables)
    if not token or token == "" then return nil, "no key" end
    token = token:gsub("^[Bb]earer%s+", "")
    local body = JSON.encode({ query = query, variables = variables or {} })
    local resp, err = request("POST", HARDCOVER_URL, {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
        ["Authorization"] = "Bearer " .. token,
    }, body)
    if not resp then
        if err == "HTTP 401" or err == "HTTP 403" then return nil, "rejected" end
        return nil, err
    end
    local ok, d = pcall(JSON.decode, resp)
    if not ok or type(d) ~= "table" then return nil, "bad JSON" end
    -- an unknown or expired key: {"error":"invalid_token", ...}
    if str(d.error) then return nil, "rejected" end
    if type(d.errors) == "table" and d.errors[1] then
        local m = type(d.errors[1]) == "table" and str(d.errors[1].message)
        return nil, m or "Hardcover error"
    end
    if type(d.data) ~= "table" then return nil, "no data" end
    return d.data
end

-- The front page's Hardcover box: who you are, shelf counts, this year's goal.
function Net.hardcoverFront(token)
    local data, err = Net.hardcover(token, [[
        query LedgerFront {
            me {
                username
                want: user_books_aggregate(where: {status_id: {_eq: 1}}) { aggregate { count(columns: [book_id], distinct: true) } }
                reading: user_books_aggregate(where: {status_id: {_eq: 2}}) { aggregate { count(columns: [book_id], distinct: true) } }
                read: user_books_aggregate(where: {status_id: {_eq: 3}}) { aggregate { count(columns: [book_id], distinct: true) } }
                goals(order_by: {end_date: desc}, limit: 1) { goal metric progress start_date end_date description }
            }
        }
    ]])
    if not data then return nil, err end
    local me = type(data.me) == "table" and data.me[1]
    if type(me) ~= "table" then return nil, "no account" end
    local function count(a)
        return type(a) == "table" and type(a.aggregate) == "table" and num(a.aggregate.count) or 0
    end
    local out = {
        username = str(me.username),
        want = count(me.want), reading = count(me.reading), read = count(me.read),
    }
    local g = type(me.goals) == "table" and me.goals[1]
    if type(g) == "table" and num(g.goal) then
        out.goal = {
            goal = num(g.goal), progress = math.floor((num(g.progress) or 0) + 0.5),
            metric = str(g.metric) or "book", description = str(g.description),
            end_date = str(g.end_date),
        }
    end
    return out
end

-- Your Hardcover Want to Read shelf, most recently added first (same fields
-- Bookbridge's shelf view uses). Covers are fetched into covers_dir.
function Net.hardcoverWant(token, limit, covers_dir)
    local data, err = Net.hardcover(token, [[
        query LedgerWant($limit: Int!) {
            me {
                user_books(where: {status_id: {_eq: 1}}, order_by: {updated_at: desc}, limit: $limit) {
                    book {
                        id
                        title
                        release_year
                        cached_image
                        contributions(where: {contribution: {_eq: "Author"}}) { author { name } }
                    }
                }
            }
        }
    ]], { limit = limit or 12 })
    if not data then return nil, err end
    local me = type(data.me) == "table" and data.me[1]
    if type(me) ~= "table" or type(me.user_books) ~= "table" then return nil, "no shelf" end
    local out = {}
    for _, ub in ipairs(me.user_books) do
        local b = type(ub) == "table" and type(ub.book) == "table" and ub.book
        if b and str(b.title) then
            local c = type(b.contributions) == "table" and b.contributions[1]
            local author = type(c) == "table" and type(c.author) == "table" and str(c.author.name) or nil
            local item = { title = str(b.title), author = author, year = num(b.release_year), id = num(b.id) }
            local img = type(b.cached_image) == "table" and str(b.cached_image.url)
            if img and covers_dir and item.id then
                item.cover = Net.fetchFile(img, string.format("%s/hc-%d.jpg", covers_dir, item.id))
            end
            out[#out + 1] = item
        end
    end
    return out
end

-- One book's status and rating on your Hardcover account.
function Net.hardcoverUserBook(token, book_id)
    local data, err = Net.hardcover(token, [[
        query LedgerUserBook($id: Int!) {
            me { user_books(where: {book_id: {_eq: $id}}, limit: 1) { status_id rating } }
            books_by_pk(id: $id) { title rating series: book_series(limit: 1) { position series { name } } }
        }
    ]], { id = book_id })
    if not data then return nil, err end
    local out = {}
    local me = type(data.me) == "table" and data.me[1]
    local ub = type(me) == "table" and type(me.user_books) == "table" and me.user_books[1]
    if type(ub) == "table" then
        out.status_id = num(ub.status_id)
        out.rating = num(ub.rating)
    end
    local b = type(data.books_by_pk) == "table" and data.books_by_pk
    if b then
        out.avg_rating = num(b.rating)
        local s = type(b.series) == "table" and b.series[1]
        if type(s) == "table" and type(s.series) == "table" then
            out.series = str(s.series.name)
            out.series_position = num(s.position)
        end
    end
    return out
end

-- Checks a key: returns the username, or nil + "rejected"/error.
function Net.hardcoverWhoAmI(token)
    local data, err = Net.hardcover(token, "query { me { username } }")
    if not data then return nil, err end
    local me = type(data.me) == "table" and data.me[1]
    return type(me) == "table" and str(me.username) or nil, (type(me) ~= "table") and "rejected" or nil
end

return Net
