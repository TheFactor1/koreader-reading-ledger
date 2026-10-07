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
    -- "Author - Title" is how Bookbridge names downloads; other sources
    -- name them "Title - Author", so the book's own metadata (KOReader's
    -- cover-browser cache, when it has read the book) wins over the guess
    local bim_ok, BIM = pcall(require, "bookinfomanager")
    for _, r in ipairs(found) do
        local author, title = r.title:match("^(.-)%s+%-%s+(.+)$")
        if author and title then r.author, r.title = author, title end
        if bim_ok and BIM then
            local iok, info = pcall(BIM.getBookInfo, BIM, r.file, false)
            if iok and info then
                if type(info.title) == "string" and info.title ~= "" then r.title = info.title end
                if type(info.authors) == "string" and info.authors ~= "" then r.author = info.authors:gsub("\n.*", "") end
            end
        end
    end
    return found
end

-- Every book on the device under the given folders, for the library.
-- Title/author come from KOReader's cover-browser cache when it has them
-- (cheap), the sidecar for books you've opened (status, progress), and the
-- file name ("Author - Title") otherwise. Bounded like justIn().
function Data.library(dirs, readest, matches)
    local bim_ok, BIM = pcall(require, "bookinfomanager")
    local last_open = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory then
        for _, item in ipairs(ReadHistory.hist or {}) do
            if item.file then last_open[item.file] = item.time end
        end
    end
    local out, seen, scanned = {}, {}, 0
    local function add(path, attr)
        local rec
        if DocSettings:hasSidecarFile(path) then
            rec = Data.localRecord(path, last_open[path])
        end
        local guessed = false
        if not rec then
            rec = { file = path, title = basenameTitle(path), opened = false }
            -- a guess from the file name, "Author - Title" (as often
            -- "Title - Author": the book's own metadata below wins)
            local author, title = rec.title:match("^(.-)%s+%-%s+(.+)$")
            if author and title then rec.author, rec.title, guessed = author, title, true end
        end
        if bim_ok and BIM then
            local iok, info = pcall(BIM.getBookInfo, BIM, path, false)
            if iok and info then
                if not rec.opened and type(info.title) == "string" and info.title ~= "" then rec.title = info.title end
                if (guessed or not rec.author) and type(info.authors) == "string" and info.authors ~= "" then
                    rec.author = info.authors:gsub("\n.*", "")
                end
                if not rec.series and type(info.series) == "string" and info.series ~= "" then
                    rec.series, rec.series_index = info.series, tonumber(info.series_index)
                end
            end
        end
        rec.added = attr.modification
        rec.last_open = last_open[path]
        Data.enrich(rec, readest, matches)
        out[#out + 1] = rec
    end
    local function walk(dir, depth)
        if depth > 4 or scanned > 6000 then return end
        local iok, iter, dir_obj = pcall(lfs.dir, dir)
        if not iok then return end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                scanned = scanned + 1
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    walk(path, depth + 1)
                elseif attr and attr.mode == "file" and isBook(name) and not seen[path]
                        and not name:match("%.downloading$") then
                    seen[path] = true
                    add(path, attr)
                end
            end
        end
    end
    for _, d in ipairs(dirs) do
        if d and lfs.attributes(d, "mode") == "directory" then walk(d, 1) end
    end
    return out
end

-- The library's status for a record: "reading" | "new" | "finished" | "unread"
function Data.status(rec)
    if Data.isFinished(rec) then return "finished" end
    if rec.opened and (rec.pct or 0) > 0 then return "reading" end
    if not rec.opened and rec.added and rec.added >= os.time() - 21 * 86400 then return "new" end
    return "unread"
end

-- Readest's synced position for every book it knows: hash -> {pct, total
-- (in Readest's own pages), updated_at (ms), status}.
function Data.readestPositions(ui)
    local settings = G_reader_settings:readSetting("readest_sync")
    if type(settings) ~= "table" or not settings.user_id or not settings.access_token then
        return nil -- not installed or not signed in
    end
    -- (straight from Readest's database: its library store builds a full
    -- object per book, about five times slower on a Kindle)
    local rows
    do
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
                total = total,
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
function Data.collect(ui, opts, t)
    opts = opts or {}
    local Timing = require("ledger_timing")
    local readest = Data.readestPositions(ui)
    Timing.lap(t, "data.readest")
    local matches = Data.hardcoverMatches()
    Timing.lap(t, "data.matches")
    local hist = Data.history(30)
    Timing.lap(t, "data.history")
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
    Timing.lap(t, "data.justIn")

    -- No history (cleared, or books opened some other way): books in
    -- progress from the library instead, most recently read first (by when
    -- their sidecar was last written).
    if not lead then
        local in_progress = {}
        for _, rec in ipairs(Data.library(dirs, readest, matches)) do
            if Data.status(rec) == "reading" and rec.status ~= "abandoned" then
                local found = DocSettings.findSidecarFile and DocSettings:findSidecarFile(rec.file)
                rec.last_open = found and lfs.attributes(found, "modification") or rec.added
                in_progress[#in_progress + 1] = rec
            end
        end
        table.sort(in_progress, function(a, b) return (a.last_open or 0) > (b.last_open or 0) end)
        for _, rec in ipairs(in_progress) do
            if not lead then lead = rec else reading[#reading + 1] = rec end
        end
    end

    return {
        lead = lead,
        reading = reading,
        just_in = just_in,
        readest_signed_in = readest ~= nil,
        history = hist,
    }
end

-- Your reading habits over the last `weeks` weeks (default 8), from
-- KOReader's statistics:
--   days     { ["2026-10-04"] = pages, ... } for every day you read
--   hours    [0..23] share of your page turns in each hour (sums to 1)
--   first    the first day the statistics saw (as "YYYY-MM-DD"), or nil
-- nil when there are no statistics at all.
local habits_cache = nil   -- { fp, weeks, out }: until the statistics change
                           -- (synced reading from other devices lands on
                           -- past days too)

-- (callers get their own copy: the merge with Readest and this device's
-- progress adds to it, and the cache must not keep those additions)
local function copyHabits(h)
    if not h then return nil end
    local out = { days = {}, hours = {}, first = h.first }
    for d, n in pairs(h.days) do out.days[d] = n end
    for k, v in pairs(h.hours) do out.hours[k] = v end
    return out
end

function Data.readingHabits(weeks, now)
    weeks = weeks or 8
    now = now or os.time()
    -- (the fingerprint: row count, newest turn and sums, and today's date)
    local fp = Data.statsFingerprint() or os.date("%Y-%m-%d", now)
    if habits_cache and habits_cache.fp == fp and habits_cache.weeks == weeks then
        return copyHabits(habits_cache.out)
    end
    local out = Data._readingHabits(weeks, now)
    habits_cache = { fp = fp, weeks = weeks, out = out }
    return copyHabits(out)
end

function Data._readingHabits(weeks, now)
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then return nil end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return nil end
    local dok, db = pcall(SQ3.open, db_path, "ro")
    if not dok or not db then return nil end
    local since = now - weeks * 7 * 86400
    local out = { days = {}, hours = {} }
    local turns = 0
    local function rows(sql, fn)
        pcall(function()
            local stmt = db:prepare(sql)
            stmt:reset():bind(since)
            while true do
                local row = stmt:step()
                if not row then break end
                fn(row)
            end
            stmt:close()
        end)
    end
    rows("SELECT date(start_time, 'unixepoch', 'localtime'), count(DISTINCT id_book || ':' || page) FROM page_stat_data WHERE start_time >= ? GROUP BY 1",
        function(row) out.days[tostring(row[1])] = tonumber(row[2]) or 0 end)
    local by_hour = {}
    rows("SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER), count(*) FROM page_stat_data WHERE start_time >= ? GROUP BY 1",
        function(row)
            local h, n = tonumber(row[1]), tonumber(row[2]) or 0
            if h then by_hour[h] = n; turns = turns + n end
        end)
    db:close()
    if turns == 0 then return nil end
    for h = 0, 23 do out.hours[h] = (by_hour[h] or 0) / turns end
    for d in pairs(out.days) do
        if not out.first or d < out.first then out.first = d end
    end
    return out
end

-- What KOReader's statistics know about one book (a few quick queries; the
-- day counts come from Ledger:readingCounts):
--   pace        seconds per page in this book (nil if none recorded)
--   all_pace    seconds per page across everything, last 30 days
--   book_start  first page turn the statistics saw in this book (time)
--   book_start_pct  where in the book that was (fraction)
--   book_end    the last page turn (time)
--   today       0 here; the Currently reading page fills it in
function Data.readingStats(hash)
    local out = { today = 0 }
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then return out end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return out end
    local dok, db = pcall(SQ3.open, db_path, "ro")
    if not dok or not db then return out end
    local function row(sql, ...)
        local r
        local args = { ... }
        pcall(function()
            local stmt = db:prepare(sql)
            r = stmt:reset():bind(unpack(args)):step()
            stmt:close()
        end)
        return r or {}
    end
    local r = row("SELECT sum(duration), count(*) FROM page_stat_data WHERE start_time >= ?", os.time() - 30 * 86400)
    local secs, pages = tonumber(r[1]), tonumber(r[2])
    if secs and pages and pages > 0 then out.all_pace = secs / pages end
    if hash then
        local id = tonumber(row("SELECT id FROM book WHERE md5 = ?", hash)[1])
        if id then
            r = row("SELECT sum(duration), count(*), min(start_time), max(start_time + duration) FROM page_stat_data WHERE id_book = ?", id)
            secs, pages = tonumber(r[1]), tonumber(r[2])
            if secs and pages and pages > 0 then out.pace = secs / pages end
            out.book_start, out.book_end = tonumber(r[3]), tonumber(r[4])
            -- where you were when the statistics first saw this book (you may
            -- have started it elsewhere), as a fraction of the book
            r = row("SELECT page, total_pages FROM page_stat_data WHERE id_book = ? ORDER BY start_time LIMIT 1", id)
            local first_page, first_total = tonumber(r[1]), tonumber(r[2])
            if first_page and first_total and first_total > 0 then
                out.book_start_pct = math.max(0, (first_page - 1) / first_total)
            end
        end
    end
    db:close()
    -- the book's page turns on every device, for its race (Race.state)
    if hash then out.turns = Data.bookTurns(hash) end
    return out
end

-- When Readest is further on: what the two buttons say, and a line saying
-- why there are two. Pages when the book's length is known, else percent.
--   "Continue from p. 203" / "Stay on p. 181" / "Readest is further on (2 h ago)."
function Data.jumpLabels(rec)
    local r = rec.readest or {}
    local pages = rec.pages and rec.pages > 0 and rec.pages
    local function at(pct, verb_page, verb_pct)
        if pages then return string.format("%s p. %d", verb_page, math.max(1, math.floor(pct * pages + 0.5))) end
        return string.format("%s %d%%", verb_pct, math.floor(pct * 100 + 0.5))
    end
    local ahead = at(r.pct or 0, "Continue from", "Continue from")
    local here = at(rec.pct or 0, "Stay on", "Stay at")
    local ago = Data.ago(r.updated_at)
    local note = ago and string.format("Readest is further on (%s).", ago) or "Readest is further on."
    return ahead, here, note
end

-- "about 6 h left" from a pace and the pages still to go.
function Data.timeLeft(pace, pages, pct)
    if not (pace and pages and pages > 0) then return nil end
    local left = pace * pages * (1 - (pct or 0))
    if left < 60 then return "almost done" end
    if left < 3600 then return string.format("about %d min left", math.floor(left / 60 + 0.5)) end
    local h = left / 3600
    if h < 10 then return string.format("about %.1f h left", h):gsub("%.0 h", " h") end
    return string.format("about %d h left", math.floor(h + 0.5))
end

-- The book's description: the sidecar's doc_props, else the cover cache.
-- HTML tags and entities stripped, whitespace collapsed.
local desc_cache = {}

function Data.description(rec)
    local key = rec.file and (rec.file .. ":" .. tostring(rec.last_open)) or nil
    if key and desc_cache[key] ~= nil then return desc_cache[key] or nil end
    local d = Data._description(rec)
    if key then desc_cache[key] = d or false end
    return d
end

function Data._description(rec)
    local desc
    if rec.file and DocSettings:hasSidecarFile(rec.file) then
        local ok, ds = pcall(DocSettings.open, DocSettings, rec.file)
        if ok and ds then
            local props = ds:readSetting("doc_props") or {}
            if type(props.description) == "string" then desc = props.description end
        end
    end
    if not desc then
        local bok, BIM = pcall(require, "bookinfomanager")
        if bok and BIM and rec.file then
            local iok, info = pcall(BIM.getBookInfo, BIM, rec.file, false)
            if iok and info and type(info.description) == "string" then desc = info.description end
        end
    end
    if not desc or desc == "" then return nil end
    desc = desc:gsub("<[^>]+>", " "):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&quot;", '"')
        :gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("%s+", " ")
    return (desc:gsub("^%s+", ""):gsub("%s+$", ""))
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

-- ---------------------------------------------------------------- the race's record
-- The race is rebuilt from the statistics (ledger_race.lua, Race.timeline),
-- which Readest syncs between devices -- so it reads ALL of them, the same
-- way on every device, and nothing that only this device saw.

local function openStats()
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then return nil end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return nil end
    local dok, db = pcall(SQ3.open, db_path, "ro")
    if not dok or not db then return nil end
    return db
end

local function eachRow(db, sql, args, fn)
    pcall(function()
        local stmt = db:prepare(sql)
        stmt:reset()
        if args then stmt:bind(unpack(args)) end
        while true do
            local row = stmt:step()
            if not row then break end
            fn(row)
        end
        stmt:close()
    end)
end

-- The race reads finished days only (today never decides anything), and
-- page turns dated before 2010 or after tomorrow -- a Kindle whose clock
-- reset after a flat battery writes 1970 -- are left out.
local function sane()
    local t = os.date("*t")
    local midnight = os.time{ year = t.year, month = t.month, day = t.day, hour = 0 }
    return 1262304000, midnight   -- 2010-01-01 .. local midnight
end

-- What the statistics hold up to last midnight, in one line: changes
-- whenever page turns are added or arrive from another device.
function Data.statsFingerprint()
    local db = openStats()
    if not db then return nil end
    local lo, hi = sane()
    local fp
    eachRow(db, "SELECT count(*), max(start_time), sum(duration), sum(total_pages) FROM page_stat_data WHERE start_time >= ? AND start_time < ?",
        { lo, hi }, function(row)
            fp = table.concat({ tonumber(row[1]) or 0, tonumber(row[2]) or 0, tonumber(row[3]) or 0, tonumber(row[4]) or 0 }, ":")
        end)
    db:close()
    return fp and (fp .. "@" .. hi) or nil
end

local all_cache = nil   -- { fp, out }
-- Every finished day in the statistics: { days = { [date] = distinct pages },
-- hours_by_day = { [date] = { [0..23] = page turns } }, hours (all of them,
-- as shares), first = date, fp }.
function Data.allHabits()
    local fp = Data.statsFingerprint()
    if not fp then return nil end
    if all_cache and all_cache.fp == fp then return all_cache.out end
    local db = openStats()
    if not db then return nil end
    local lo, hi = sane()
    local out = { days = {}, hours = {}, hours_by_day = {}, fp = fp }
    eachRow(db, "SELECT date(start_time, 'unixepoch', 'localtime'), count(DISTINCT id_book || ':' || page) FROM page_stat_data WHERE start_time >= ? AND start_time < ? GROUP BY 1",
        { lo, hi }, function(row)
            local d = tostring(row[1])
            out.days[d] = tonumber(row[2]) or 0
            if not out.first or d < out.first then out.first = d end
        end)
    local by_hour, turns = {}, 0
    eachRow(db, "SELECT date(start_time, 'unixepoch', 'localtime'), CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER), count(*) FROM page_stat_data WHERE start_time >= ? AND start_time < ? GROUP BY 1, 2",
        { lo, hi }, function(row)
            local d, h, n = tostring(row[1]), tonumber(row[2]), tonumber(row[3]) or 0
            if h then
                out.hours_by_day[d] = out.hours_by_day[d] or {}
                out.hours_by_day[d][h] = n
                by_hour[h] = (by_hour[h] or 0) + n; turns = turns + n
            end
        end)
    db:close()
    if turns == 0 then out = nil
    else for h = 0, 23 do out.hours[h] = (by_hour[h] or 0) / turns end end
    all_cache = { fp = fp, out = out }
    return out
end

-- One book's reading, day by day, from its page turns (on any device):
--   rows   { { t = start time, frac = where in the book (0..1) } ... } by time
--   total  the book's length in pages (the longest any device counted)
--   hash   its checksum
-- nil when the statistics haven't seen it.
function Data.bookTurns(hash, db_in)
    if not hash then return nil end
    local db = db_in or openStats()
    if not db then return nil end
    -- (one checksum can have more than one book row -- a title edited on
    -- one device: all of them, so every device reads the same turns)
    local title
    eachRow(db, "SELECT title FROM book WHERE md5 = ? ORDER BY id LIMIT 1", { hash }, function(row)
        title = row[1] and tostring(row[1]) or nil
    end)
    local lo = sane()
    local out = { rows = {}, total = 0, hash = hash, title = title }
    eachRow(db, "SELECT start_time, page, total_pages FROM page_stat_data WHERE id_book IN (SELECT id FROM book WHERE md5 = ?) AND start_time >= ? AND start_time < ? ORDER BY start_time, page, total_pages",
        { hash, lo, os.time() + 86400 }, function(row)
            local t, page, tot = tonumber(row[1]), tonumber(row[2]), tonumber(row[3])
            if t and page and tot and tot > 0 then
                out.rows[#out.rows + 1] = { t = t, page = page, tot = tot,
                    frac = math.min(1, page / tot), first_frac = math.max(0, (page - 1) / tot) }
                if tot > out.total then out.total = tot end
            end
        end)
    if #out.rows == 0 then out = nil end
    if not db_in then db:close() end
    return out
end

-- The books the statistics show you reaching the end of (any device):
-- { [hash] = turns (as Data.bookTurns) }. For the race tally, which must
-- count the same books everywhere.
function Data.finishedTurns()
    local db = openStats()
    if not db then return {} end
    local hashes = {}
    eachRow(db, "SELECT b.md5 FROM page_stat_data p JOIN book b ON b.id = p.id_book WHERE p.total_pages > 0 GROUP BY p.id_book HAVING max(p.page * 1.0 / p.total_pages) >= 0.9",
        nil, function(row) if row[1] then hashes[#hashes + 1] = tostring(row[1]) end end)
    local out = {}
    for _, h in ipairs(hashes) do out[h] = Data.bookTurns(h, db) end
    db:close()
    return out
end

return Data
