--[[
Reading done in Readest (on your phone, tablet or computer) counts in the
race, the same as reading on this device.

Two ways it gets here, used together:

  * Reading statistics. Readest syncs page-by-page reading statistics
    between devices, into the same statistics database KOReader keeps (its
    readest_syncstats). When the Ledger opens it asks Readest to pull them,
    and to pull its library's positions; both run in the background, and the
    Ledger redraws when they land.

  * Positions. Readest's library holds the furthest position you reached in
    each book and when. Each time the Ledger looks, a book that moved further
    in Readest than it is on this device was read somewhere else: those pages
    count, on the day Readest says they were read. Pages that the statistics
    sync already brought in for that stretch are taken off, so nothing counts
    twice whichever way it arrived.

Kept in the Ledger's settings as "readest_read": { log = { [hash] = { pct,
at, dev } }, gains = { { hash, t0, t1, lo, hi, pages }, ... } } (lo..hi:
the stretch of the book read elsewhere, as fractions; pages: book length).
--]]

local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local R = {}

-- Readest's plugin instance on this UI, when it's installed and signed in.
function R.plugin(ui)
    local rs = ui and ui.readest
    if type(rs) ~= "table" then return nil end
    local s = G_reader_settings:readSetting("readest_sync")
    if type(s) ~= "table" or not s.access_token or not s.user_id then return nil end
    return rs
end

-- ---------------------------------------------------------------- pulling
local listeners = {}
local hooked = false
local cached = nil   -- R.days / hours, until something changes
local pending = nil

local function notify()
    -- several pages of statistics arrive in a row: one redraw after the last
    if pending then UIManager:unschedule(pending) end
    pending = function()
        pending = nil
        cached = nil
        for _, cb in ipairs(listeners) do pcall(cb) end
    end
    UIManager:scheduleIn(2, pending)
end

-- Hear when Readest's statistics or library pulls land. Wraps two of its
-- module functions once, calling straight through to them.
local function hook()
    if hooked then return end
    hooked = true
    local stats = package.loaded["readest_syncstats"]
    if type(stats) == "table" and type(stats.applyRemote) == "function" then
        local orig = stats.applyRemote
        stats.applyRemote = function(...)
            local out = { pcall(orig, ...) }
            notify()
            if not out[1] then error(out[2], 0) end
            return unpack(out, 2)
        end
    end
    -- (Readest loads its library sync on first use; load it now so the
    -- wrap is in place before that)
    local books = package.loaded["library.syncbooks"]
    if not books then
        local ok, m = pcall(require, "library.syncbooks")
        if ok then books = m end
    end
    if type(books) == "table" and type(books.pullBooks) == "function" then
        local orig = books.pullBooks
        books.pullBooks = function(opts, cb)
            return orig(opts, function(...)
                notify()
                if cb then return cb(...) end
            end)
        end
    end
end

local last_pull = 0

-- Ask Readest for the latest statistics and positions, quietly; on_change
-- runs once they've landed. At most every five minutes, and only online.
function R.refresh(ui, on_change)
    local rs = R.plugin(ui)
    if not rs or not NetworkMgr:isOnline() then return end
    if os.time() - last_pull < 300 then return end
    last_pull = os.time()
    if on_change then listeners = { on_change } end
    local ok, err = pcall(function()
        hook()
        if rs.pullBookStats then rs:pullBookStats(false) end
        if rs.syncBooksLibrary then rs:syncBooksLibrary("pull", false) end
    end)
    if not ok then logger.warn("ledger: Readest pull failed:", err) end
end

-- ---------------------------------------------------------------- positions
-- How much of the stretch lo..hi of this book (fractions) the statistics
-- hold page turns for between two times (s), as a fraction of the book.
-- Each device counts in its own pages, so pages are taken as a share of
-- that row's total; this device's earlier reading outside the stretch
-- doesn't count.
local function statCovered(hash, t0, t1, lo, hi)
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then return 0 end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return 0 end
    local dok, db = pcall(SQ3.open, db_path, "ro")
    if not dok or not db then return 0 end
    local covered = 0
    pcall(function()
        local stmt = db:prepare([[SELECT count(DISTINCT p.page), max(p.total_pages) FROM page_stat_data p
            JOIN book b ON b.id = p.id_book
            WHERE b.md5 = ? AND p.start_time > ? AND p.start_time <= ? AND p.total_pages > 0
              AND p.page * 1.0 / p.total_pages > ? AND p.page * 1.0 / p.total_pages <= ?]])
        local row = stmt:reset():bind(hash, math.floor(t0), math.floor(t1), lo, hi + 0.01):step()
        local n, total = row and tonumber(row[1]), row and tonumber(row[2])
        if n and total and total > 0 then covered = n / total end
        stmt:close()
    end)
    db:close()
    return covered
end

local function state(store)
    local st = store:readSetting("readest_read") or {}
    st.log = st.log or {}
    st.gains = st.gains or {}
    return st
end

-- Look at each book's Readest position against this device's and note how
-- far it moved beyond both since the last look. What part of that was read
-- elsewhere is worked out when it's used (R.days), so statistics that sync
-- in later still cancel it out.
--   recs  the books this device knows (with pct, pages, hash, readest)
function R.observe(store, recs, now)
    if not store then return end
    now = now or os.time()
    local st = state(store)
    local changed = false
    for _, rec in ipairs(recs or {}) do
        local r = rec.readest
        if rec.hash and r and r.pct and r.updated_at then
            local dev = rec.pct or 0
            local l = st.log[rec.hash]
            if not l then
                -- first sight: nothing to count yet
                st.log[rec.hash] = { pct = r.pct, at = r.updated_at, dev = dev }
                changed = true
            elseif r.updated_at > l.at then
                local pages = (rec.pages and rec.pages > 0) and rec.pages or r.total or 300
                local lo = math.max(l.pct, dev)
                local gained = math.max(0, r.pct - lo) * pages
                if gained >= 1 then
                    st.gains[#st.gains + 1] = {
                        hash = rec.hash, t0 = l.at / 1000, t1 = r.updated_at / 1000,
                        lo = lo, hi = r.pct, pages = pages,
                    }
                end
                st.log[rec.hash] = { pct = math.max(l.pct, r.pct), at = r.updated_at, dev = dev }
                changed = true
            end
        end
    end
    if changed then
        local keep = now - 70 * 86400
        local kept = {}
        for _, g in ipairs(st.gains) do if g.t1 >= keep then kept[#kept + 1] = g end end
        st.gains = kept
        store:saveSetting("readest_read", st)
        store:flush()
        R.forget()
    end
end

-- Pages read in Readest, per day and per hour of day, after taking off what
-- the statistics already hold (worked out once, kept until something changes).
function R.forget() cached = nil end

local function tally(store)
    if cached then return cached end
    local days, hours = {}, {}
    for _, g in ipairs(state(store).gains) do
        local lo, hi = g.lo or 0, g.hi or 0
        local covered = statCovered(g.hash, g.t0, g.t1, lo, hi)
        local other = math.floor(math.max(0, (hi - lo) - covered) * (g.pages or 0) + 0.5)
        if other > 0 then
            local t = math.floor(g.t1)
            local day = os.date("%Y-%m-%d", t)
            days[day] = (days[day] or 0) + other
            local h = tonumber(os.date("%H", t))
            hours[h] = (hours[h] or 0) + other
        end
    end
    cached = { days = days, hours = hours }
    return cached
end

-- Pages read in Readest per day: { [date] = pages }.
function R.days(store)
    return store and tally(store).days or {}
end

-- Pages read in Readest from `since` (a "YYYY-MM-DD") on.
function R.pagesSince(store, since)
    local n = 0
    for d, p in pairs(R.days(store)) do if d >= since then n = n + p end end
    return n
end

-- Folds Readest's days and hours into Data.readingHabits() output (or
-- makes one, when this device has no statistics).
function R.mergeHabits(habits, store)
    local s = store and tally(store)
    if not s or not next(s.days) then return habits end
    habits = habits or { days = {}, hours = {} }
    local by_hour, turns = {}, 0
    -- habits.hours are shares; weigh them back up by this device's pages
    local own = 0
    for _, p in pairs(habits.days) do own = own + p end
    for h = 0, 23 do
        by_hour[h] = (habits.hours[h] or 0) * own
        turns = turns + by_hour[h]
    end
    for d, p in pairs(s.days) do
        habits.days[d] = (habits.days[d] or 0) + p
        if not habits.first or d < habits.first then habits.first = d end
    end
    for h, p in pairs(s.hours) do
        h = tonumber(h)
        if h then by_hour[h] = (by_hour[h] or 0) + p; turns = turns + p end
    end
    if turns > 0 then
        for h = 0, 23 do habits.hours[h] = (by_hour[h] or 0) / turns end
    end
    return habits
end

return R
