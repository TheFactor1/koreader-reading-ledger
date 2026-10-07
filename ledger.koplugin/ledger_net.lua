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
    local ok, code, resp_headers = pcall(function() return socket.skip(1, requester.request(req)) end)
    socketutil:reset_timeout()
    if not ok then return nil, "connection error: " .. tostring(code) end
    if type(code) ~= "number" then return nil, "connection error: " .. tostring(code) end
    if code ~= 200 then return nil, "HTTP " .. tostring(code), resp_headers end
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
-- Follows redirects (Open Library's covers often move to archive.org; the
-- HTTPS requester doesn't follow them by itself).
function Net.fetchFile(url, path)
    if lfs.attributes(path, "mode") == "file" then return path end
    local body, err, headers
    for _ = 1, 4 do
        body, err, headers = request("GET", url, nil, nil, 10, 20)
        local to = not body and type(headers) == "table" and (headers.location or headers.Location)
        if not (to and tostring(err):match("^HTTP 30[1278]")) then break end
        url = to:match("^https?://") and to or (url:match("^(https?://[^/]+)") .. to)
    end
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
    local url = string.format("%s/search.json?title=%s%s&fields=cover_i,language&limit=8", OPENLIBRARY,
        urlencode(title), author and author ~= "" and ("&author=" .. urlencode(author)) or "")
    local d, err = getJSON(url)
    if not d then return nil, err end
    -- (an English edition's cover when there's one: the first match can be
    -- a translation -- Red Rising came back as "Amanecer rojo")
    -- English only first, then English among others, then anything
    local best, best_score
    for _, doc in ipairs(type(d.docs) == "table" and d.docs or {}) do
        local cover = type(doc) == "table" and num(doc.cover_i)
        if cover then
            local langs = type(doc.language) == "table" and doc.language or {}
            local all = table.concat(langs, " ")
            local score = (all == "eng" and 2) or (all:find("eng", 1, true) and 1) or 0
            if not best_score or score > best_score then best, best_score = cover, score end
        end
    end
    local id = best
    if not id then return nil end
    local file = Net.fetchFile(string.format("https://covers.openlibrary.org/b/id/%d-M.jpg", id),
        string.format("%s/ol-%d.jpg", covers_dir, id))
    -- (a cover that wouldn't download is "try again", not "none")
    if not file then return nil, "download failed" end
    return file
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
-- The book after this one in its series, from Hardcover: the series in
-- order, one book per position, without compilations, partial editions or
-- merged duplicates (Hardcover's own guide, "Getting All Books in a
-- Series"), then the first one after this book that you haven't read.
-- -> { series, position, next = { id, title, author, year, position, cover,
--    status_id } | nil } or nil, err
function Net.hardcoverSeriesNext(token, book_id, covers_dir)
    local data, err = Net.hardcover(token, [[
        query LedgerSeries($id: Int!) {
            books_by_pk(id: $id) {
                book_series(where: {compilation: {_eq: false}}, order_by: {featured: desc}, limit: 1) {
                    position
                    series {
                        name
                        book_series(
                            distinct_on: position
                            order_by: [{position: asc}, {book: {users_count: desc}}]
                            where: {book: {canonical_id: {_is_null: true}, is_partial_book: {_eq: false}}, compilation: {_eq: false}}
                        ) {
                            position
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
            }
        }
    ]], { id = book_id })
    if not data then return nil, err end
    local b = type(data.books_by_pk) == "table" and data.books_by_pk
    local bs = b and type(b.book_series) == "table" and b.book_series[1]
    local series = type(bs) == "table" and type(bs.series) == "table" and bs.series
    local here = type(bs) == "table" and num(bs.position)
    if not series or not here then return { none = true } end
    local out = { series = str(series.name), position = here }
    -- the books after this one: whole numbers first (a 2.5 is a novella)
    local after = {}
    for _, e in ipairs(type(series.book_series) == "table" and series.book_series or {}) do
        local pos = type(e) == "table" and num(e.position)
        local bk = type(e) == "table" and type(e.book) == "table" and e.book
        if pos and bk and num(bk.id) and pos > here then
            local c = type(bk.contributions) == "table" and bk.contributions[1]
            after[#after + 1] = { id = num(bk.id), title = str(bk.title), year = num(bk.release_year), position = pos,
                author = type(c) == "table" and type(c.author) == "table" and str(c.author.name) or nil,
                image = type(bk.cached_image) == "table" and str(bk.cached_image.url) or nil }
        end
    end
    if #after == 0 then return out end
    -- skip the ones you've already read (Hardcover status 3)
    local ids = {}
    for _, a in ipairs(after) do ids[#ids + 1] = a.id end
    local mine = Net.hardcover(token, [[
        query LedgerSeriesMine($ids: [Int!]) {
            me { user_books(where: {book_id: {_in: $ids}}) { book_id status_id } }
        }
    ]], { ids = ids })
    local status = {}
    local me = type(mine) == "table" and type(mine.me) == "table" and mine.me[1]
    for _, ub in ipairs(type(me) == "table" and type(me.user_books) == "table" and me.user_books or {}) do
        if type(ub) == "table" and num(ub.book_id) then status[num(ub.book_id)] = num(ub.status_id) end
    end
    local pick
    for _, whole in ipairs({ true, false }) do
        for _, a in ipairs(after) do
            if status[a.id] ~= 3 and (not whole or a.position == math.floor(a.position)) then pick = a; break end
        end
        if pick then break end
    end
    if pick then
        pick.status_id = status[pick.id]
        if pick.image and covers_dir then
            pick.cover = Net.fetchFile(pick.image, string.format("%s/hc-%d.jpg", covers_dir, pick.id))
        end
        pick.image = nil
        out.next = pick
    end
    return out
end

-- Your Hardcover "Read" shelf: { { id, title, author, date = "YYYY-MM-DD" } },
-- newest first. One of the places a finished book is known from.
function Net.hardcoverRead(token, limit)
    local data, err = Net.hardcover(token, [[
        query LedgerRead($limit: Int!) {
            me {
                user_books(where: {status_id: {_eq: 3}}, order_by: {last_read_date: desc_nulls_last}, limit: $limit) {
                    book_id
                    last_read_date
                    book {
                        title
                        contributions(where: {contribution: {_eq: "Author"}}) { author { name } }
                        book_series(where: {compilation: {_eq: false}}, order_by: {featured: desc}, limit: 1) { position series { name } }
                    }
                }
            }
        }
    ]], { limit = limit or 300 })
    if not data then return nil, err end
    local me = type(data.me) == "table" and data.me[1]
    local out = {}
    for _, ub in ipairs(type(me) == "table" and type(me.user_books) == "table" and me.user_books or {}) do
        local b = type(ub) == "table" and type(ub.book) == "table" and ub.book
        if b and str(b.title) then
            local c = type(b.contributions) == "table" and b.contributions[1]
            local bs = type(b.book_series) == "table" and b.book_series[1]
            out[#out + 1] = { id = num(ub.book_id), title = str(b.title), date = str(ub.last_read_date),
                author = type(c) == "table" and type(c.author) == "table" and str(c.author.name) or nil,
                series = type(bs) == "table" and type(bs.series) == "table" and str(bs.series.name) or nil,
                position = type(bs) == "table" and num(bs.position) or nil }
        end
    end
    return out
end

-- ---------------------------------------------------------------- vibes
-- Hardcover's vibes: recommendation feeds it keeps fresh (once a day).
-- Yours -- "Recommendations" and "Top Picks" behind its Discover page, and
-- any you've made -- and the ones you've liked from other readers.
-- -> { { id, title, kind = "discover"|"mine"|"liked", by } } (needs the
-- key's read:vibes scope; nil, err without it)
function Net.hardcoverVibes(token)
    local me, err = Net.hardcover(token, "query LedgerMe { me { id } }")
    local my_id = me and type(me.me) == "table" and type(me.me[1]) == "table" and num(me.me[1].id)
    if not my_id then return nil, err or "no user" end
    local data, err2 = Net.hardcover(token, [[
        query LedgerVibes($me: Int!) {
            vibes(where: {user_id: {_eq: $me}, vibe_type: {_in: [0, 1, 3]}}, order_by: {vibe_type: desc}) { id title vibe_type }
            likes(where: {user_id: {_eq: $me}, likeable_type: {_eq: "Vibe"}}, order_by: {created_at: desc}, limit: 20) {
                vibe { id title user { username } }
            }
        }
    ]], { me = my_id })
    if not data then return nil, err2 end
    local out = {}
    -- (Discover's two first: Recommendations, then Top Picks)
    local order = { [1] = 1, [3] = 2, [0] = 3 }
    local mine = {}
    for _, v in ipairs(type(data.vibes) == "table" and data.vibes or {}) do
        if type(v) == "table" and num(v.id) and str(v.title) then
            mine[#mine + 1] = { id = num(v.id), title = str(v.title), kind = (num(v.vibe_type) == 0) and "mine" or "discover",
                rank = order[num(v.vibe_type) or 0] or 9 }
        end
    end
    table.sort(mine, function(a, b) return a.rank < b.rank end)
    for _, v in ipairs(mine) do v.rank = nil; out[#out + 1] = v end
    for _, l in ipairs(type(data.likes) == "table" and data.likes or {}) do
        local v = type(l) == "table" and type(l.vibe) == "table" and l.vibe
        if v and num(v.id) and str(v.title) then
            out[#out + 1] = { id = num(v.id), title = str(v.title), kind = "liked",
                by = type(v.user) == "table" and str(v.user.username) or nil }
        end
    end
    return out
end

-- A vibe's books, best first: its ranked pool, without the ones you've
-- already read or set aside on Hardcover. -> { { id, title, author, year,
-- cover, status_id } } (status 1: on your Want to Read)
function Net.hardcoverVibeBooks(token, vibe_id, limit, covers_dir)
    limit = limit or 24
    local data, err = Net.hardcover(token, "query LedgerVibe($id: Int!) { vibes_by_pk(id: $id) { cached_book_ids } }", { id = vibe_id })
    if not data then return nil, err end
    local v = type(data.vibes_by_pk) == "table" and data.vibes_by_pk
    local ids = {}
    for _, id in ipairs(v and type(v.cached_book_ids) == "table" and v.cached_book_ids or {}) do
        if num(id) and #ids < limit * 2 then ids[#ids + 1] = num(id) end
    end
    if #ids == 0 then return {} end
    local b, err2 = Net.hardcover(token, [[
        query LedgerVibeBooks($ids: [Int!]) {
            books(where: {id: {_in: $ids}}) { id title release_year cached_contributors cached_image }
            me { user_books(where: {book_id: {_in: $ids}}) { book_id status_id } }
        }
    ]], { ids = ids })
    if not b then return nil, err2 end
    local by_id, status = {}, {}
    for _, bk in ipairs(type(b.books) == "table" and b.books or {}) do
        if type(bk) == "table" and num(bk.id) then by_id[num(bk.id)] = bk end
    end
    local me = type(b.me) == "table" and b.me[1]
    for _, ub in ipairs(type(me) == "table" and type(me.user_books) == "table" and me.user_books or {}) do
        if type(ub) == "table" and num(ub.book_id) then status[num(ub.book_id)] = num(ub.status_id) end
    end
    local out = {}
    for _, id in ipairs(ids) do     -- (the vibe's order)
        local bk = by_id[id]
        local st = status[id]
        -- (read, reading, paused, not finished, ignored: not a discovery)
        if bk and str(bk.title) and (not st or st == 1) then
            local author
            for _, c in ipairs(type(bk.cached_contributors) == "table" and bk.cached_contributors or {}) do
                if type(c) == "table" and type(c.author) == "table" and (type(c.contribution) ~= "string" or c.contribution == "Author") then
                    author = str(c.author.name); if author then break end
                end
            end
            local item = { id = id, title = str(bk.title), author = author, year = num(bk.release_year), status_id = st }
            local img = type(bk.cached_image) == "table" and str(bk.cached_image.url)
            if img and covers_dir then item.cover = Net.fetchFile(img, string.format("%s/hc-%d.jpg", covers_dir, id)) end
            out[#out + 1] = item
            if #out >= limit then break end
        end
    end
    return out
end

-- ---------------------------------------------------------------- friends
-- People you follow on Hardcover: { { id, username, name } }.
function Net.hardcoverFollows(token)
    local data, err = Net.hardcover(token, [[
        query LedgerFollows { me { followed_users(limit: 100) { followed_user { id username name } } } }
    ]])
    if not data then return nil, err end
    local me = type(data.me) == "table" and data.me[1]
    local out = {}
    for _, f in ipairs(type(me) == "table" and type(me.followed_users) == "table" and me.followed_users or {}) do
        local u = type(f) == "table" and type(f.followed_user) == "table" and f.followed_user
        if u and num(u.id) and str(u.username) then
            out[#out + 1] = { id = num(u.id), username = str(u.username), name = str(u.name) }
        end
    end
    table.sort(out, function(a, b) return a.username:lower() < b.username:lower() end)
    return out
end

-- A Hardcover user by username: { id, username, name } or nil.
function Net.hardcoverUser(token, username)
    local data, err = Net.hardcover(token, [[
        query LedgerUser($u: citext!) { users(where: {username: {_eq: $u}}, limit: 1) { id username name } }
    ]], { u = username })
    if not data then return nil, err end
    local u = type(data.users) == "table" and data.users[1]
    if type(u) ~= "table" or not num(u.id) then return nil, "not found" end
    return { id = num(u.id), username = str(u.username), name = str(u.name) }
end

-- A friend's reading, as far as their Hardcover privacy lets you see it:
-- the books they're reading now (by Hardcover book id: where they are) and
-- the pages they've read since `since` (their progress updates' deltas).
-- -> { reading = { [book_id] = { title, pct, pages, total } }, pages = n }
function Net.hardcoverFriend(token, user_id, since)
    local data, err = Net.hardcover(token, [[
        query LedgerFriend($id: Int!, $since: timestamptz!) {
            users(where: {id: {_eq: $id}}, limit: 1) {
                username
                user_books(where: {status_id: {_eq: 2}}, order_by: {updated_at: desc}, limit: 20) {
                    book_id
                    book { title pages }
                    user_book_reads(order_by: {id: desc}, limit: 1) { progress progress_pages edition { pages } }
                }
            }
            reading_journals(where: {user_id: {_eq: $id}, event: {_eq: "progress_updated"}, action_at: {_gte: $since}},
                             order_by: {action_at: desc}, limit: 300) { metadata }
        }
    ]], { id = user_id, since = os.date("!%Y-%m-%dT%H:%M:%SZ", since) })
    if not data then return nil, err end
    local u = type(data.users) == "table" and data.users[1]
    if type(u) ~= "table" then return nil, "not found" end
    local out = { username = str(u.username), reading = {}, pages = 0 }
    for _, ub in ipairs(type(u.user_books) == "table" and u.user_books or {}) do
        local id = type(ub) == "table" and num(ub.book_id)
        local r = id and type(ub.user_book_reads) == "table" and ub.user_book_reads[1]
        if type(r) == "table" then
            local total = (type(r.edition) == "table" and num(r.edition.pages)) or (type(ub.book) == "table" and num(ub.book.pages))
            local pct = num(r.progress)
            local pages = num(r.progress_pages)
            if not pct and pages and total and total > 0 then pct = 100 * pages / total end
            if pct then
                out.reading[tostring(id)] = { title = type(ub.book) == "table" and str(ub.book.title) or nil,
                    pct = math.max(0, math.min(1, pct / 100)), pages = pages, total = total }
            end
        end
    end
    for _, j in ipairs(type(data.reading_journals) == "table" and data.reading_journals or {}) do
        local d = type(j) == "table" and type(j.metadata) == "table" and num(j.metadata.pages_delta)
        if d and d > 0 then out.pages = out.pages + d end
    end
    return out
end

function Net.hardcoverWhoAmI(token)
    local data, err = Net.hardcover(token, "query { me { username } }")
    if not data then return nil, err end
    local me = type(data.me) == "table" and data.me[1]
    return type(me) == "table" and str(me.username) or nil, (type(me) ~= "table") and "rejected" or nil
end

return Net
