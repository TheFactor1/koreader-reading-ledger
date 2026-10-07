--[[
The race: you against a rival, over the whole book and day by day.

You pick your runner (cat, dog, rabbit or tortoise) and a rival. The rival
learns your reading habits from KOReader's statistics (last 8 weeks) and
races you on them:

  * How much: what you usually read on that day of the week (leaning on
    your overall average until it has seen enough of them), nudged by
    whether you've been reading more or less lately. The animal sets how much more than that it reads.
  * When: it reads at the hours you usually read, so it doesn't run off in
    the morning when you only read at night.
  * How hard: after each day it checks whether you out-read it over the
    week before and tunes itself so you're ahead about as often as its
    animal says (tortoise mostly, cat two weeks in three, dog and rabbit
    about half). The rabbit is fast but naps every third day.
  * Kept close: in a book, a rival more than a day or two ahead of you eases
    off, and one far behind pushes, so the race stays a race. It can still
    win, and so can you.

Your place is the furthest of this device and Readest.

Nothing about the race is stored: it is rebuilt from the statistics,
which Readest syncs between devices, so every device shows the same race
(see "the replay" below).
--]]

local Race = {}

-- mult: how much more than your expected day the rival reads, before tuning.
-- win: how often you should be ahead of it once it's tuned. Each day it
--      asks: over the last `window` days (default a week), did you read more
--      than it did? Judging by the week evens out your light and heavy days,
--      so winning that often also means winning about that many books.
-- nap(day_number): true on days it doesn't read.
Race.ANIMALS = {
    { id = "tortoise", label = "Tortoise", name = "Shelly", hint = "Easy -- you'll be ahead most of the time",
      run = { "turtle_walk0", "turtle_walk1", "turtle_walk2", "turtle_walk3" }, still = "turtle_walk0",
      scale = 0.75, mult = 1.0, win = 0.85 },
    { id = "cat", label = "Cat", name = "Biscuit", hint = "Fair -- you'll be ahead about 2 weeks in 3",
      run = { "cat_run0", "cat_run1", "cat_run2", "cat_run3", "cat_run4", "cat_run5" }, still = "cat_run2",
      scale = 1, mult = 1.15, win = 0.65 },
    { id = "dog", label = "Dog", name = "Pip", hint = "Hard -- about half the time",
      run = { "dog_run0", "dog_run1", "dog_run2", "dog_run3" }, still = "dog_run1",
      scale = 0.85, mult = 1.3, win = 0.5 },
    { id = "rabbit", label = "Rabbit", name = "Clover", hint = "Hard and streaky -- fast, but naps every third day",
      run = { "rabbit_run0", "rabbit_run1", "rabbit_run2", "rabbit_run3", "rabbit_run4", "rabbit_run5" },
      still = "rabbit_run0", nap_sprite = "rabbit_idle5",
      scale = 1, mult = 1.6, win = 0.5, window = 6, nap = function(n) return n % 3 == 2 end },
}

local BY_ID = {}
for _, a in ipairs(Race.ANIMALS) do BY_ID[a.id] = a end

function Race.animal(id) return BY_ID[id] or BY_ID.cat end

-- Your expected pages a day when there are no statistics yet.
Race.DEFAULT_PACE = 20
-- Book length to race over when the book's page count isn't known.
Race.DEFAULT_PAGES = 300

local WEEKDAYS = { "Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays" }

-- ---------------------------------------------------------------- dates
local function noon(t)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day, hour = 12 }
end
-- (remembered: the replay asks about the same few hundred days tens of
-- thousands of times, and os.date/os.time are slow on an e-reader -- the
-- replay took 0.8 s on a Kindle before, which every home screen waited for)
local date_of, time_of, wday_of, n_dates = {}, {}, {}, 0
local function dateOf(t)
    local d = date_of[t]
    if not d then
        d = os.date("%Y-%m-%d", t)
        if n_dates >= 20000 then date_of, n_dates = {}, 0 end
        date_of[t], n_dates = d, n_dates + 1
    end
    return d
end
local function timeOf(date)
    local t = time_of[date]
    if not t then
        local y, m, d = date:match("^(%d+)-(%d+)-(%d+)$")
        t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
        time_of[date] = t
    end
    return t
end
-- the day of the week of a date (1 = Sunday)
local function wdayOf(date)
    local w = wday_of[date]
    if not w then w = os.date("*t", timeOf(date)).wday; wday_of[date] = w end
    return w
end
local function nextDate(date) return dateOf(timeOf(date) + 86400) end
-- a running day number, for the rabbit's naps
local function dayNumber(date) return math.floor(timeOf(date) / 86400) end

-- ---------------------------------------------------------------- habits
-- A model of your reading from Data.readingHabits() (nil: no statistics).
--   expected(date)  pages you'd usually read that day
--   share(t)        how much of a day's reading you've usually done by time t
--   overall         pages per calendar day (zero days included)
--   per_reading_day pages on days you read
function Race.model(habits, now)
    now = now or os.time()
    local m = { habits = habits }
    local today = dateOf(now)
    local wd_sum, wd_n = {}, {}
    for w = 1, 7 do wd_sum[w], wd_n[w] = 0, 0 end
    local total, n, recent, recent_n, reading_days = 0, 0, 0, 0, 0
    -- when the reading by hour is known day by day, the hours are learned from
    -- the same eight weeks (so a day is only decided by what came before it)
    local by_hour, turns = habits and habits.hours_by_day and {} or nil, 0
    if habits and habits.first then
        -- every calendar day from the first one seen (at most 8 weeks) to yesterday
        local noon_now = noon(now)
        local t = math.max(timeOf(habits.first), noon_now - 56 * 86400)
        while dateOf(t) < today do
            local d = dateOf(t)
            local pages = habits.days[d] or 0
            local w = wdayOf(d)
            wd_sum[w], wd_n[w] = wd_sum[w] + pages, wd_n[w] + 1
            total, n = total + pages, n + 1
            if pages > 0 then reading_days = reading_days + 1 end
            if t >= noon_now - 14 * 86400 then recent, recent_n = recent + pages, recent_n + 1 end
            local hd = by_hour and habits.hours_by_day[d]
            if hd then for h, c in pairs(hd) do by_hour[h] = (by_hour[h] or 0) + c; turns = turns + c end end
            t = t + 86400
        end
    end
    if n >= 3 and total > 0 then
        m.overall = total / n
        m.per_reading_day = total / math.max(1, reading_days)
        m.trend = recent_n > 0 and math.max(0.7, math.min(1.4, (recent / recent_n) / m.overall)) or 1
        m.weekday = {}
        -- each weekday's average, leaning on your overall average until that
        -- weekday has been seen a few times (two imaginary average days)
        for w = 1, 7 do m.weekday[w] = (wd_sum[w] + 2 * m.overall) / (wd_n[w] + 2) end
        m.learned = true
        m.span = n
    else
        m.overall, m.per_reading_day, m.trend = Race.DEFAULT_PACE, Race.DEFAULT_PACE, 1
        m.weekday = {}
        for w = 1, 7 do m.weekday[w] = Race.DEFAULT_PACE end
    end
    -- hours: yours, or evenly from 7 am to midnight
    local hours
    if by_hour then
        if turns > 0 then
            hours = {}
            for h = 0, 23 do hours[h] = (by_hour[h] or 0) / turns end
        end
    else
        hours = habits and habits.hours
    end
    if not hours then
        hours = {}
        for h = 0, 23 do hours[h] = h >= 7 and 1 / 17 or 0 end
    end
    m.hours = hours
    function m.expected(date)
        local w = wdayOf(date)
        -- your usual for that weekday; never under a fifth of your overall
        -- day, so skipping days lets the rival creep up
        return math.max(m.weekday[w], 0.2 * m.overall) * m.trend
    end
    function m.share(t)
        local d = os.date("*t", t)
        local done = 0
        for h = 0, d.hour - 1 do done = done + (hours[h] or 0) end
        return math.min(1, done + (hours[d.hour] or 0) * d.min / 60)
    end
    return m
end

-- ---------------------------------------------------------------- the replay
--[[
The race is rebuilt from KOReader's statistics every time, not remembered:
the statistics are synced between your devices (by Readest), so every
device that has them gets the same race -- same rival, same days won, same
books won -- whichever one you happen to look at, and whenever.

For that, a day is only ever decided by what came before it: the rival's
idea of your habits on a day is learned from the statistics before that
day, and its tuning steps day by day from the first day the statistics
have. A book's race starts at your first page turn in it (and again where
you picked it up after a break of two weeks), and each day the rival keeps
close to where you were at the end of that day. Late page turns -- a device
that was offline for a few days -- are simply part of the next replay, on
every device alike.
--]]

local BREAK = 14 * 86400        -- a pause this long in a book restarts its race
local FINISH = 0.98             -- where in the book counts as reaching the end
-- On a day you don't open the book, the rival in it goes at this share of
-- its pace: putting a book down costs a little, not the race (Matt,
-- 2026-10-07: twelve days away from All Systems Red and the rival was 75%
-- ahead; he chose "slower when you're away" over "waits for you").
local AWAY = 0.25

-- The rival's share for a day: your expected day, its animal, its tuning.
-- 0 on a nap day.
local function dayTarget(m, a, factor, date)
    if a.nap and a.nap(dayNumber(date)) then return 0 end
    return m.expected(date) * a.mult * factor
end

local timeline_cache = { key = nil, T = nil }

-- You and the rival day by day, from the first day in the statistics to
-- yesterday (habits: Data.allHabits()). -> T with
--   model(date)  your habits as known at the start of that day
--   factor       the rival's tuning now; factor_on[date] that day's
--   results      [date] = { rival, you, target, won }
function Race.timeline(habits, rival, now)
    now = now or os.time()
    local today = dateOf(now)
    local key = tostring(habits and habits.fp) .. "|" .. tostring(rival) .. "|" .. today
    if timeline_cache.key == key then return timeline_cache.T end
    local a = Race.animal(rival)
    local T = { rival = rival, today = today, now = now, habits = habits, factor_on = {}, results = {}, models = {} }
    function T.model(date)
        local m = T.models[date]
        if not m then m = Race.model(habits, timeOf(date)); T.models[date] = m end
        return m
    end
    local factor = 1
    if habits and habits.first then
        local function pages(date) return habits.days[date] or 0 end
        local d = habits.first
        while d < today do
            local m = T.model(d)
            T.factor_on[d] = factor
            local target = dayTarget(m, a, factor, d)
            if target > 0 then
                -- had you out-read it over the animal's window (a week; six
                -- days, two naps, for the rabbit)?
                local you_sum, its_sum, t = 0, 0, timeOf(d)
                for back = 0, (a.window or 7) - 1 do
                    local dd = dateOf(t - back * 86400)
                    you_sum = you_sum + pages(dd)
                    its_sum = its_sum + dayTarget(m, a, factor, dd)
                end
                local won = you_sum >= its_sum
                T.results[d] = { rival = rival, you = pages(d), target = math.floor(target + 0.5), won = won }
                -- a small step each day: your wins make it harder, its wins easier
                factor = math.max(0.4, math.min(1.7, factor * math.exp(0.08 * ((won and 1 or 0) - a.win))))
            end
            d = nextDate(d)
        end
    end
    T.factor = factor
    T.factor_on[today] = factor
    timeline_cache = { key = key, T = T }
    return T
end

-- Days you've beaten the rival lately: won, out of.
function Race.record(T, days, now)
    local since = dateOf((now or os.time()) - (days or 30) * 86400)
    local won, of = 0, 0
    for d, r in pairs(T and T.results or {}) do
        if d >= since then
            of = of + 1
            if r.won then won = won + 1 end
        end
    end
    return won, of
end

-- In a book, keep it close: how hard the rival goes given the gap in days
-- of your reading (positive: the rival is ahead).
local function band(gap_days)
    if gap_days > 3 then return 0.6, "easing off" end
    if gap_days > 1.5 then return 0.85, "easing off" end
    if gap_days < -3 then return 1.2, "pushing" end
    if gap_days < -1.5 then return 1.1, "pushing" end
    return 1, nil
end

-- A book's race up to time t, from its page turns (turns: Data.bookTurns).
-- Everything is as of t: the book's length is the longest any device had
-- counted by then (a device added later doesn't rewrite old races).
-- -> { start, frac (the rival at the start of t's day), you (you then),
--      total (pages, as of t) }
function Race.bookRace(turns, T, total_hint, t)
    local rows = turns.rows
    local last = 0
    for i = 1, #rows do if rows[i].t <= t then last = i end end
    if last == 0 then return nil end
    -- the race starts at the first turn, or after the last long break before t
    local seg = 1
    for i = 2, last do if rows[i].t - rows[i - 1].t >= BREAK then seg = i end end
    local total = 0
    for i = 1, last do if (rows[i].tot or 0) > total then total = rows[i].tot end end
    if total <= 0 then total = total_hint or Race.DEFAULT_PAGES end
    local start, start_frac = rows[seg].t, rows[seg].first_frac
    -- where you were at the end of each day: the page you stopped on (the
    -- day's last turn), not the furthest one you saw -- a flick to the end
    -- and back isn't reading it (Matt's All Systems Red, 2026-09-25: pages
    -- 44, 99, 153 in twenty minutes, then back to page 5, and the race put
    -- him at 99% with the rival finished)
    local you_end = {}
    for i = seg, last do
        you_end[dateOf(rows[i].t)] = math.max(start_frac, rows[i].frac)
    end
    local a = Race.animal(T.rival)
    local start_date, upto = dateOf(start), dateOf(t)
    local frac, you = start_frac, start_frac
    local d = start_date
    while d < upto do
        you = you_end[d] or you
        local m = T.model(d)
        local mult = band((frac - you) * total / math.max(1, m.overall))
        local part = d == start_date and (1 - m.share(start)) or 1
        if not you_end[d] then part = part * AWAY end   -- (a day you didn't open it)
        frac = math.min(1, frac + dayTarget(m, a, T.factor_on[d] or T.factor, d) * mult * part / total)
        d = nextDate(d)
    end
    return { start = start, frac = frac, you = you_end[upto] or you, total = total, read_today = you_end[upto] ~= nil }
end

-- When you finished a book, from its page turns: the first turn at the
-- end (98%) after reading through most of it in one go (a jump to the
-- endnotes isn't finishing); or, for a book whose back matter you skipped,
-- the last turn of a read-through that reached 90% and then stopped for
-- good (two weeks). -> time | nil
function Race.finishedAt(turns, now)
    local rows = turns.rows
    local seen, n_seen, seg_tot = {}, 0, 0
    local function reset() seen, n_seen, seg_tot = {}, 0, 0 end
    for i = 1, #rows do
        local r = rows[i]
        if i > 1 and r.t - rows[i - 1].t >= BREAK then reset() end
        local key = (r.page or math.floor(r.frac * 1000)) .. "/" .. (r.tot or 0)
        if not seen[key] then seen[key] = true; n_seen = n_seen + 1 end
        if (r.tot or 0) > seg_tot then seg_tot = r.tot end
        local covered = seg_tot > 0 and n_seen / seg_tot or 0
        if r.frac >= FINISH and covered >= 0.5 then return r.t end
        local is_last = i == #rows or rows[i + 1].t - r.t >= BREAK
        if is_last and r.frac >= 0.9 and covered >= 0.6 and (now or os.time()) - r.t >= BREAK then return r.t end
    end
    return nil
end

-- The rival's place at time t (rival pages, the day's target, mood).
local function rivalAt(br, T, a, total, you_pages, t)
    local day = dateOf(t)
    local m = T.model(day)
    local factor = T.factor_on[day] or T.factor
    local target = dayTarget(m, a, factor, day)
    local mult, mood = band((br.frac * total - you_pages) / math.max(1, m.overall))
    local from = dateOf(br.start) == day and m.share(br.start) or 0
    -- (not opened today: the away pace, as on the days before)
    local pace = br.read_today == false and AWAY or 1
    local pages = math.min(total, math.floor(br.frac * total + target * mult * pace * math.max(0, m.share(t) - from) + 0.5))
    return pages, target, mood, m, factor
end

-- The race for one book.
--   rec    the book (pct, pages, hash, readest)
--   stats  Data.readingStats(rec.hash), with .turns (its page turns) and .today
--   T      Race.timeline() (a table with .timeline, as Ledger:raceModel()
--          returns, works too)
--   peek   look without starting a race (a book not opened yet): the rival
--          waits level with you
-- Returns: total, you_pages, you_pct, rival_pages, rival_pct, rate (the
-- rival's pages a day at the moment), napping, rival_done, ahead (rival
-- pages minus yours), today_target, today, mood ("easing off", "pushing")
function Race.state(rec, stats, _store, _you, rival, T, now, peek)
    now = now or os.time()
    stats = stats or {}
    if T and T.timeline then T = T.timeline end
    T = T or Race.timeline(nil, rival, now)
    local turns = stats.turns
    -- the race runs in the statistics' pages (the same on every device) and
    -- is shown in this device's own (what its page footer says)
    local own = (rec.pages and rec.pages > 0) and rec.pages or nil
    local you_pct = math.max(rec.pct or 0, rec.readest and rec.readest.pct or 0)
    local a = Race.animal(T.rival)   -- (the timeline's rival: one animal throughout)
    local br = not peek and turns and Race.bookRace(turns, T, own, now)
    if br then you_pct = math.max(you_pct, br.you) end
    local race_total = (br and br.total) or own or Race.DEFAULT_PAGES
    br = br or { start = now, frac = you_pct }   -- not started: level with you
    local rival_race, target, mood, m, factor = rivalAt(br, T, a, race_total, math.floor(you_pct * race_total + 0.5), now)
    local total = own or race_total
    local rival_pct = rival_race / race_total
    local you_pages = math.floor(you_pct * total + 0.5)
    local rival_pages = math.min(total, math.floor(rival_pct * total + 0.5))
    return {
        total = total,
        pages_known = own ~= nil or (turns and turns.total > 0) or false,
        you_pages = you_pages, you_pct = you_pct,
        rival_pages = rival_pages, rival_pct = rival_pct,
        rate = math.floor(m.overall * a.mult * factor * (a.nap and 2 / 3 or 1) + 0.5),
        napping = target == 0,
        -- a dead heat goes to you: you turned the last page
        rival_done = rival_pages >= total and you_pages < total,
        ahead = rival_pages - you_pages,
        today_target = math.floor(target + 0.5),
        today = stats.today or 0,
        mood = mood,
    }
end

-- A finished book's result, from its page turns: did you reach the end
-- before the rival? Judged at the page turn that reached it.
-- -> { won, by, rival, at, title } (by: pages ahead, yours or the rival's) | nil
function Race.result(turns, T)
    if not turns or not T then return nil end
    local at = Race.finishedAt(turns, T.now)
    if not at then return nil end
    local br = Race.bookRace(turns, T, nil, at)
    if not br then return nil end
    local total = br.total
    local rival_pages = rivalAt(br, T, Race.animal(T.rival), total, total, at)
    local won = rival_pages < total
    return { won = won, by = won and (total - rival_pages) or nil, rival = T.rival, at = at, title = turns.title, hash = turns.hash,
        -- (started: your first page in it, not the race's start -- a race
        -- restarts after a two-week break, which isn't a quick read)
        author = turns.author, started = turns.rows[1] and turns.rows[1].t or br.start, pages = total }
end

-- Your record against the rival in every finished book (finished:
-- Data.finishedTurns()): wins, losses, and the results newest first.
function Race.tally(T, finished)
    local won, lost, list = 0, 0, {}
    for _, turns in pairs(finished or {}) do
        local r = Race.result(turns, T)
        if r then
            list[#list + 1] = r
            if r.won then won = won + 1 else lost = lost + 1 end
        end
    end
    table.sort(list, function(x, y) return (x.at or 0) > (y.at or 0) end)
    return won, lost, list
end

-- ---------------------------------------------------------------- words
-- "22 pages", or "5%" when the book's length isn't known.
local function gapText(pages, race)
    if race.pages_known then return string.format("%d %s", pages, pages == 1 and "page" or "pages") end
    return string.format("%d%%", math.max(1, math.floor(pages / race.total * 100 + 0.5)))
end

-- What the runners say when you tap them, the labels under the track and
-- the line about today. p: the plugin; race: Race.state().
function Race.lines(p, rec, race, cache)
    local you, rival = p:petName(p:runner()), p:petName(p:rival())
    local t = {}
    -- pages when the book's length is known, else percent
    local function at(pages, pct)
        local percent = string.format("%d%%", math.floor(pct * 100 + 0.5))
        if race.pages_known then return string.format("p. %d · %s", pages, percent) end
        return percent
    end
    if race.pages_known then
        t.you_says = string.format("%s: I'm on page %d of %d.", you, math.max(1, race.you_pages), race.total)
    else
        t.you_says = string.format("%s: I'm %d%% of the way.", you, math.floor(race.you_pct * 100 + 0.5))
    end
    if require("ledger_data").readestAhead(rec) then t.you_says = t.you_says .. " Readest got me here." end
    if race.rival_done then
        t.rival_says = string.format("%s: Finished! Your turn.", rival)
    elseif race.napping then
        t.rival_says = string.format("%s: Zzz... napping today. Sneak past me!", rival)
    elseif race.ahead > 0 then
        t.rival_says = string.format("%s: I'm %s ahead -- catch me!", rival, gapText(race.ahead, race))
        if race.mood == "easing off" then t.rival_says = t.rival_says .. " (I'll take it easy for a bit.)" end
    elseif race.ahead < 0 then
        t.rival_says = string.format("%s: You're %s ahead of me.", rival, gapText(-race.ahead, race))
        if race.mood == "pushing" then t.rival_says = t.rival_says .. " Not for long!" end
    else
        t.rival_says = string.format("%s: Neck and neck!", rival)
    end
    local hc = cache and cache.hardcover
    if hc and hc.goal and hc.goal.goal then
        t.fish_says = string.format("Finish this one and it's fish %d of %d this year.", (hc.goal.progress or 0) + 1, hc.goal.goal)
    else
        t.fish_says = "A fish for every book you finish."
    end
    t.you_label = string.format("%s (you) · %s", you, at(race.you_pages, race.you_pct))
    t.rival_label = race.rival_done and string.format("%s · finished", rival)
        or string.format("%s · %s", rival, at(race.rival_pages, race.rival_pct))
    if race.napping then
        t.today = string.format("%s naps today: every page puts you further ahead.", rival)
    elseif race.today >= race.today_target then
        t.today = string.format("You out-read %s today: %d pages to %d.", rival, race.today, race.today_target)
    else
        t.today = string.format("Today %d of %d pages. %d more to out-read %s.", race.today, race.today_target,
            race.today_target - race.today, rival)
    end
    if (race.today_readest or 0) > 0 then
        t.today = t.today .. string.format(" (%d in Readest.)", race.today_readest)
    end
    return t
end

-- What the rival has learned about you, for Settings.
function Race.summary(p, m, now)
    now = now or os.time()
    local rival_id = p:rival()
    local rival = p:petName(rival_id)
    local lines = {}
    if not m.learned then
        lines[#lines + 1] = string.format("%s hasn't seen enough of your reading yet. Read with KOReader's statistics on for a few days and it'll learn your habits; until then it assumes about %d pages a day.", rival, Race.DEFAULT_PACE)
    else
        lines[#lines + 1] = string.format("You read about %d pages on days you read (%d a day overall).",
            math.floor(m.per_reading_day + 0.5), math.floor(m.overall + 0.5))
        if m.span >= 14 then
            local best, best_w = -1, 1
            for w = 1, 7 do if m.weekday[w] > best then best, best_w = m.weekday[w], w end end
            lines[#lines + 1] = string.format("You read most on %s.", WEEKDAYS[best_w])
        end
        -- your busiest three hours
        local best_h, best_s = 0, -1
        for h = 0, 23 do
            local s3 = (m.hours[h] or 0) + (m.hours[(h + 1) % 24] or 0) + (m.hours[(h + 2) % 24] or 0)
            if s3 > best_s then best_h, best_s = h, s3 end
        end
        local function hh(h)
            h = h % 24
            return string.format("%d %s", (h % 12 == 0) and 12 or h % 12, h < 12 and "am" or "pm")
        end
        lines[#lines + 1] = string.format("You mostly read between %s and %s, so that's when %s reads too.",
            hh(best_h), hh(best_h + 3), rival)
        if m.trend > 1.1 then
            lines[#lines + 1] = "You've been reading more than usual lately; it's keeping up."
        elseif m.trend < 0.9 then
            lines[#lines + 1] = "You've been reading less than usual lately; it's easing off to match."
        end
    end
    local won, of = Race.record(m.timeline, 30, now)
    if of > 0 then
        lines[#lines + 1] = string.format("Last 30 days: on %d of %d days you'd read more than %s over the week before.", won, of, rival)
    end
    local a = Race.animal(rival_id)
    lines[#lines + 1] = string.format("%s is tuned so you're ahead about %d%% of the time, and adjusts a little after every day.",
        rival, math.floor(a.win * 100 + 0.5))
    return table.concat(lines, "\n\n")
end

return Race
