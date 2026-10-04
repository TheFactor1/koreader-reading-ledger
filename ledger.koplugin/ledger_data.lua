--[[
The Ledger's data layer: one record per book, joining what each source knows.

  This Kindle  -- ReadHistory + each book's sidecar (progress, status, title,
                  partial-md5), and new files nobody has opened yet.
  Readest      -- its library database: the synced position of every book and
                  when it last changed (it does not record WHICH device).
  Bookbridge   -- its Hardcover matches (partial-md5 -> Hardcover book id).

All of this is local and fast, so it runs in the UI process on every show.
Remote data (Hardcover account, trending, requests) lives in ledger_cache and
is refreshed in the background by main.lua.
--]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Data = {}

local BOOK_EXT = {
    epub = true, pdf = true, mobi = true, azw3 = true, azw = true, fb2 = true,
    cbz = true, djvu = true, txt = true, kepub = true, docx = true, rtf = true,
}

local function isBook(path)
    local ext = path:match("%.([^./]+)$")
    return ext and BOOK_EXT[ext:lower()] or false
end

local function basenameTitle(path)
    local name = path:match("([^/]+)$") or path
    return (name:gsub("%.[^.]+$", ""))
end

local function readJSONFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a"); f:close()
    if not c or c == "" then return nil end
    local ok, d = pcall(JSON.decode, c)
    return ok and type(d) == "table" and d or nil
end

-- What this device knows about one file. Returns a record or nil.
function Data.localRecord(file, last_open)
    if lfs.attributes(file, "mode") ~= "file" then return nil end
    local rec = { file = file, last_open = last_open, title = basenameTitle(file) }
    if not DocSettings:hasSidecarFile(file) then
        rec.opened = false
        return rec
    end
    local ok, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok or not ds then return rec end
    rec.opened = true
    local props = ds:readSetting("doc_props") or {}
    if type(props.title) == "string" and props.title ~= "" then rec.title = props.title end
    if type(props.authors) == "string" and props.authors ~= "" then
        rec.author = props.authors:gsub("\n.*", "")
    end
    if type(props.series) == "string" and props.series ~= "" then
        rec.series = props.series
        rec.series_index = tonumber(props.series_index)
    end
    rec.pct = tonumber(ds:readSetting("percent_finished"))
    local summary = ds:readSetting("summary") or {}
    rec.status = summary.status -- "reading" | "complete" | "abandoned" | nil
    rec.hash = ds:readSetting("partial_md5_checksum")
    rec.pages = tonumber((ds:readSetting("stats") or {}).pages) or tonumber(ds:readSetting("doc_pages"))
    return rec
end

function Data.isFinished(rec)
    return rec.status == "complete" or (rec.pct and rec.pct >= 0.995) or false
end

-- Recently opened books, newest first.
function Data.history(limit)
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory then return {} end
    if ReadHistory.reload then pcall(ReadHistory.reload, ReadHistory) end
    local out = {}
    for _, item in ipairs(ReadHistory.hist or {}) do
        if #out >= (limit or 30) then break end
        if item.file and not item.dim then
            local rec = Data.localRecord(item.file, item.time)
            if rec then out[#out + 1] = rec end
        end
    end
    return out
end

-- New books: files in the given folders added recently and never opened.
-- Bounded (depth and file count) so a big library can't stall the page.
function Data.justIn(dirs, max_age_days, limit)
    local cutoff = os.time() - (max_age_days or 21) * 86400
    local found, seen, scanned = {}, {}, 0
    local function walk(dir, depth)
        if depth > 3 or scanned > 4000 then return end
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                scanned = scanned + 1
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    walk(path, depth + 1)
                elseif attr and attr.mode == "file" and isBook(name)
                        and attr.modification >= cutoff and not seen[path]
                        and not name:match("%.downloading$") and not DocSettings:hasSidecarFile(path) then
                    seen[path] = true
                    found[#found + 1] = { file = path, title = basenameTitle(path), added = attr.modification, opened = false }
                end
            end
        end
    end
    for _, d in ipairs(dirs) do
        if d and lfs.attributes(d, "mode") == "directory" then walk(d, 1) end
    end
    table.sort(found, function(a, b) return a.added > b.added end)
    while #found > (limit or 6) do table.remove(found) end
    -- "Author - Title" is how Bookbridge names downloads
    for _, r in ipairs(found) do
        local author, title = r.title:match("^(.-)%s+%-%s+(.+)$")
        if author and title then r.author, r.title = author, title end
    end
    return found
end

-- Readest's synced position for every book it knows: hash -> {pct, updated_at, status}.
function Data.readestPositions(ui)
    local settings = G_reader_settings:readSetting("readest_sync")
    if type(settings) ~= "table" or not settings.user_id or not settings.access_token then
        return nil -- not installed or not signed in
    end
    local rows
    local store = ui and ui.readest and ui.readest.getLibraryStore and ui.readest:getLibraryStore()
    if store and store.listBooks then
        local ok, r = pcall(store.listBooks, store, {})
        if ok then rows = r end
    end
    if not rows then
        -- Readest not loaded in this context: read its database directly.
        local db_path = DataStorage:getSettingsDir() .. "/readest_library.sqlite3"
        if lfs.attributes(db_path, "mode") ~= "file" then return {} end
        local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
        if not ok then return {} end
        local dok, db = pcall(SQ3.open, db_path, "ro")
        if not dok or not db then return {} end
        rows = {}
        pcall(function()
            local stmt = db:prepare("SELECT hash, progress_lib, reading_status, updated_at FROM books WHERE user_id = ? AND deleted_at IS NULL")
            stmt:reset():bind(settings.user_id)
            local row = stmt:step()
            while row do
                rows[#rows + 1] = { hash = row[1], progress_lib = row[2], reading_status = row[3], updated_at = tonumber(row[4]) }
                row = stmt:step()
            end
            stmt:close()
        end)
        db:close()
    end
    local out = {}
    for _, r in ipairs(rows) do
        local cur, total
        if type(r.progress_lib) == "string" then
            cur, total = r.progress_lib:match("^%[%s*(%d+)%s*,%s*(%d+)%s*%]$")
        end
        cur, total = tonumber(cur), tonumber(total)
        if r.hash then
            out[r.hash] = {
                pct = (cur and total and total > 0) and math.min(1, cur / total) or nil,
                updated_at = tonumber(r.updated_at),
                status = r.reading_status,
            }
        end
    end
    return out
end

-- Bookbridge's Hardcover matches: partial-md5 -> { book_id, title }.
function Data.hardcoverMatches()
    local map = readJSONFile(DataStorage:getSettingsDir() .. "/shelfmark_hardcover_map.json") or {}
    local out = {}
    for md5, e in pairs(map) do
        if type(e) == "table" and type(e.book_id) == "number" and e.decision ~= "skip" then
            out[md5] = { book_id = e.book_id, title = e.title }
        end
    end
    return out
end

-- Fills in the Readest position and Hardcover match on a record, in place.
function Data.enrich(rec, readest, matches)
    if rec.hash then
        local r = readest and readest[rec.hash]
        if r then rec.readest = r end
        local m = matches and matches[rec.hash]
        if m then rec.hardcover_id = m.book_id end
    end
    return rec
end

-- True when Readest holds a position meaningfully ahead of this device:
-- that's when "Continue from Readest" is offered (its sync only moves forward).
function Data.readestAhead(rec)
    local r = rec.readest
    if not r or not r.pct then return false end
    return r.pct - (rec.pct or 0) >= 0.01
end

-- Everything the front page shows that's local. Returns a table.
function Data.collect(ui, opts)
    opts = opts or {}
    local readest = Data.readestPositions(ui)
    local matches = Data.hardcoverMatches()
    local hist = Data.history(30)
    for _, rec in ipairs(hist) do Data.enrich(rec, readest, matches) end

    local lead, reading = nil, {}
    for _, rec in ipairs(hist) do
        if not Data.isFinished(rec) and rec.status ~= "abandoned" then
            if not lead then lead = rec else reading[#reading + 1] = rec end
        end
    end

    local dirs = {}
    local home = G_reader_settings:readSetting("home_dir")
    if home then dirs[#dirs + 1] = home end
    if opts.download_dir and opts.download_dir ~= home then dirs[#dirs + 1] = opts.download_dir end
    local just_in = Data.justIn(dirs, 21, 6)

    return {
        lead = lead,
        reading = reading,
        just_in = just_in,
        readest_signed_in = readest ~= nil,
        history = hist,
    }
end

-- Pages turned today, from KOReader's own reading statistics (0 if the
-- statistics plugin has nothing).
function Data.pagesToday()
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then return 0 end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return 0 end
    local t = os.date("*t")
    local midnight = os.time{ year = t.year, month = t.month, day = t.day, hour = 0 }
    local n = 0
    local dok, db = pcall(SQ3.open, db_path, "ro")
    if not dok or not db then return 0 end
    pcall(function()
        local stmt = db:prepare("SELECT count(DISTINCT id_book || ':' || page) FROM page_stat_data WHERE start_time >= ?")
        local row = stmt:reset():bind(midnight):step()
        n = row and tonumber(row[1]) or 0
        stmt:close()
    end)
    db:close()
    return n
end

-- Days since any book was last opened (nil if never).
function Data.daysSinceReading(hist)
    local last = hist and hist[1] and hist[1].last_open
    if not last then return nil end
    return math.floor((os.time() - last) / 86400)
end

-- "2 h ago", "yesterday", "3 days ago" from a millisecond timestamp.
function Data.ago(ms)
    if not ms then return nil end
    local s = os.time() - math.floor(ms / 1000)
    if s < 120 then return "just now" end
    if s < 3600 then return math.floor(s / 60) .. " min ago" end
    if s < 86400 then return math.floor(s / 3600) .. " h ago" end
    if s < 2 * 86400 then return "yesterday" end
    return math.floor(s / 86400) .. " days ago"
end

-- Small JSON cache for remote data, so the page draws instantly offline.
local CACHE_PATH = DataStorage:getSettingsDir() .. "/ledger_cache.json"

function Data.loadCache()
    return readJSONFile(CACHE_PATH) or {}
end

function Data.saveCache(t)
    local tmp = CACHE_PATH .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    local ok, s = pcall(JSON.encode, t)
    if not ok then f:close(); logger.warn("ledger cache encode failed:", s); return false end
    f:write(s); f:close()
    return os.rename(tmp, CACHE_PATH)
end

function Data.coversDir()
    local d = DataStorage:getDataDir() .. "/cache/ledger-covers"
    if lfs.attributes(d, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(d)
    end
    return d
end

return Data
