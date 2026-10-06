--[[
The race is rebuilt from the (synced) statistics, so every device with the
same statistics must show the same race, whenever and however often it
looked. Checks that, and the rules the replay is made of.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/race_replay.lua
--]]
package.path = "./?.lua;" .. package.path
package.loaded["ledger_data"] = { readestAhead = function() return false end }
local Race = require("ledger_race")

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

-- a reproducible "random" (not math.random: the same on every run)
local seed = 12345
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end

local DAY = 86400
local t0 = os.time{ year = 2026, month = 1, day = 5, hour = 12 }
local function dateOf(t) return os.date("%Y-%m-%d", t) end

-- Two years of evenings: 20 pages on weekdays, 45 at weekends (+-40%), a
-- slump after a year, skipped days; 300-page books back to back, read on
-- "device A" (300 pages) and "device B" (its own page count, 320) on
-- alternate days. Returns the statistics as the replay sees them.
local function reading(ndays)
    seed = 12345
    local days, books = {}, {}
    local book, at = 1, 0
    for i = 0, ndays - 1 do
        local t = t0 + i * DAY
        local wd = os.date("*t", t).wday
        local n = (wd == 1 or wd == 7) and 45 or 20
        if i > 365 then n = math.floor(n * 0.6) end
        if rnd() < 0.2 then n = 0 end
        n = math.floor(n * (0.6 + 0.8 * rnd()))
        if n > 0 then
            days[dateOf(t)] = n
            local b = books[book] or { rows = {}, total = 0, hash = "book" .. book, title = "Book " .. book }
            books[book] = b
            local total = (i % 2 == 0) and 300 or 320
            for k = 1, n do
                at = math.min(1, at + 1 / 300)
                b.rows[#b.rows + 1] = { t = t + 9 * 3600 + k * 60, frac = at, first_frac = math.max(0, at - 1 / total) }
                if total > b.total then b.total = total end
            end
            if at >= 1 then book, at = book + 1, 0 end
        end
    end
    return days, books
end

local function habitsOf(days, upto, fp)
    local h = { days = {}, hours = {}, fp = fp }
    for d, n in pairs(days) do
        if d < upto then
            h.days[d] = n
            if not h.first or d < h.first then h.first = d end
        end
    end
    for x = 0, 23 do h.hours[x] = (x >= 21 and x <= 23) and 1 / 3 or 0 end
    return h
end

local function sameResults(a, b, before)
    for d, r in pairs(a.results) do
        if not before or d < before then
            local o = b.results[d]
            if not o or o.won ~= r.won or o.target ~= r.target or o.you ~= r.you then return false, d end
        end
    end
    for d in pairs(b.results) do if (not before or d < before) and not a.results[d] then return false, d end end
    return true
end

local days, books = reading(730)
local now = t0 + 729 * DAY + 20 * 3600        -- the last day, 8 pm
local today = dateOf(now)

-- 1. two devices, same statistics, same moment: the same race
local tA = os.clock()
local A = Race.timeline(habitsOf(days, today, "A"), "dog", now)
local secs = os.clock() - tA
local B = Race.timeline(habitsOf(days, today, "B"), "dog", now)
local same, at = sameResults(A, B)
ck(same and A.factor == B.factor, "two devices with the same statistics: same days won, same tuning" .. (at and (" (differs " .. at .. ")") or ""))
ck(secs < 1.5, string.format("two years replayed in %.2f s (desktop; the Kindle is ~5x slower, once per new batch of statistics)", secs))

-- 2. a device that looked every day vs one that only looks now: the same
local looked
for i = 600, 729, 7 do
    looked = Race.timeline(habitsOf(days, dateOf(t0 + i * DAY), "C" .. i), "dog", t0 + i * DAY + 20 * 3600)
end
local C = Race.timeline(habitsOf(days, today, "C-final"), "dog", now)
ck(sameResults(A, C) and A.factor == C.factor, "looking often or once makes no difference")

-- 3. old days stay decided as time moves on
local earlier = Race.timeline(habitsOf(days, dateOf(t0 + 500 * DAY), "E"), "dog", t0 + 500 * DAY + 20 * 3600)
ck(sameResults(earlier, A, dateOf(t0 + 500 * DAY)), "days already decided don't change later")

-- 4. late statistics: B missed three days, then they arrive
local late = {}
for d, n in pairs(days) do late[d] = n end
for i = 700, 702 do late[dateOf(t0 + i * DAY)] = nil end
local Bmissing = Race.timeline(habitsOf(late, today, "B-missing"), "dog", now)
ck(not sameResults(A, Bmissing), "without three days of another device's reading, the race differs (as it should)")
local Bsynced = Race.timeline(habitsOf(days, today, "B-synced"), "dog", now)
ck(sameResults(A, Bsynced) and A.factor == Bsynced.factor, "once they sync in, both devices agree again")

-- 5. a book's race: same on both devices, from the page turns
local current
for i = #books, 1, -1 do if books[i].rows[#books[i].rows].frac < 1 then current = books[i]; break end end
current = current or books[#books]
local rec = { pct = 0.1, pages = 250, hash = current.hash }    -- this device's own page count differs
local sA = Race.state(rec, { turns = current, today = 0 }, nil, "cat", "dog", A, now)
local sB = Race.state({ pct = 0.1, pages = 280, hash = current.hash }, { turns = current, today = 0 }, nil, "cat", "dog", B, now)
ck(sA.rival_pages == sB.rival_pages and sA.you_pages == sB.you_pages and sA.total == sB.total,
    string.format("a book's race: the same on both devices (rival p.%d, you p.%d of %d)", sA.rival_pages, sA.you_pages, sA.total))
ck(sA.total == current.total, "the race uses the book's length from the statistics, not this device's page count")

-- 6. finished books: the same results everywhere
local finished = {}
for _, b in ipairs(books) do if b.rows[#b.rows].frac >= 0.98 then finished[b.hash] = b end end
local wA, lA, listA = Race.tally(A, finished)
local wB, lB = Race.tally(B, finished)
ck(wA == wB and lA == lB and wA + lA > 5, string.format("finished books: %d won, %d lost -- the same on both devices", wA, lA))
ck(listA[1] and listA[1].title and listA[1].hash, "a result names its book")

-- 7. a two-week break restarts a book's race where you picked it up
local paused = { rows = {}, total = 300, hash = "paused", title = "Paused" }
local tp = t0 + 700 * DAY
for k = 1, 30 do paused.rows[#paused.rows + 1] = { t = tp + k * 60, frac = k / 300, first_frac = (k - 1) / 300 } end
local back = tp + 20 * DAY
for k = 31, 40 do paused.rows[#paused.rows + 1] = { t = back + k * 60, frac = k / 300, first_frac = (k - 1) / 300 } end
local br = Race.bookRace(paused, A, 300, now)
ck(br and br.start == back + 31 * 60, "after a 20-day pause the race restarts where you picked the book up")

-- 8. a book not opened yet: the rival waits level with you
local peek = Race.state({ pct = 0.2, pages = 300 }, {}, nil, "cat", "dog", A, now, true)
ck(math.abs(peek.rival_pages - peek.you_pages) <= math.max(1, peek.today_target), "a book not started: the rival waits level with you")

-- 9. the tuning still does its job: you're ahead about as often as the animal says
for _, id in ipairs({ "tortoise", "cat", "dog" }) do
    local T = Race.timeline(habitsOf(days, today, "tune-" .. id), id, now)
    local won, of = Race.record(T, 120, now)
    local a = Race.animal(id)
    local share = won / math.max(1, of)
    ck(of > 60 and math.abs(share - a.win) < 0.2,
        string.format("%-8s ahead on %d%% of the last 120 days (aims for %d%%)", id, math.floor(share * 100 + 0.5), math.floor(a.win * 100 + 0.5)))
end

-- 10. the rabbit still naps every third day
local R = Race.timeline(habitsOf(days, today, "rabbit"), "rabbit", now)
local naps, seen = 0, 0
for i = 600, 728 do
    seen = seen + 1
    if not R.results[dateOf(t0 + i * DAY)] then naps = naps + 1 end
end
ck(math.abs(naps / seen - 1 / 3) < 0.05, string.format("the rabbit naps on a third of days (%d of %d)", naps, seen))

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
