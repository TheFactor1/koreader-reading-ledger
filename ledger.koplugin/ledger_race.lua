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

Everything learned is kept in the Ledger's settings ("rival_form": the
tuning per animal and recent days' results; "races": each book's race).
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
local function dateOf(t) return os.date("%Y-%m-%d", t) end
local function timeOf(date)
    local y, m, d = date:match("^(%d+)-(%d+)-(%d+)$")
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
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
    if habits and habits.first then
        -- every calendar day from the first one seen (at most 8 weeks) to yesterday
        local t = math.max(timeOf(habits.first), noon(now) - 56 * 86400)
        while dateOf(t) < today do
            local d = dateOf(t)
            local pages = habits.days[d] or 0
            local w = os.date("*t", t).wday
            wd_sum[w], wd_n[w] = wd_sum[w] + pages, wd_n[w] + 1
            total, n = total + pages, n + 1
            if pages > 0 then reading_days = reading_days + 1 end
            if t >= noon(now) - 14 * 86400 then recent, recent_n = recent + pages, recent_n + 1 end
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
    local hours = habits and habits.hours
    if not hours then
        hours = {}
        for h = 0, 23 do hours[h] = h >= 7 and 1 / 17 or 0 end
    end
    m.hours = hours
    function m.expected(date)
        local w = os.date("*t", timeOf(date)).wday
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

-- ---------------------------------------------------------------- tuning
local function form(store)
    local f = store and store:readSetting("rival_form") or {}
    f.factor = f.factor or {}
    f.results = f.results or {}
    return f
end

local function factorOf(f, rival) return f.factor[rival] or 1 end

-- The rival's share for a day: your expected day, its animal, its tuning.
-- 0 on a nap day.
local function dayTarget(m, a, factor, date)
    if a.nap and a.nap(dayNumber(date)) then return 0 end
    return m.expected(date) * a.mult * factor
end

-- Settle the days since the last visit: had you out-read the rival over the
-- week up to that day? Tune it so how often you're ahead heads for its
-- animal's target.
function Race.settle(store, m, rival, now)
    if not store then return end
    now = now or os.time()
    local f = form(store)
    local today = dateOf(now)
    -- first run: learn from here on
    if not f.settled then f.settled = dateOf(now - 86400) end
    local a = Race.animal(rival)
    local d = nextDate(f.settled)
    local changed = not store:readSetting("rival_form")
    local function pages(date) return m.habits and m.habits.days[date] or 0 end
    while d < today do
        local target = dayTarget(m, a, factorOf(f, rival), d)
        if target > 0 then
            local you = pages(d)
            -- you and it over the animal's window (a week; six days, two
            -- naps, for the rabbit)
            local you_sum, its_sum, t = 0, 0, timeOf(d)
            for back = 0, (a.window or 7) - 1 do
                local dd = dateOf(t - back * 86400)
                you_sum = you_sum + pages(dd)
                its_sum = its_sum + dayTarget(m, a, factorOf(f, rival), dd)
            end
            local won = you_sum >= its_sum
            f.results[d] = { rival = rival, you = you, target = math.floor(target + 0.5), won = won }
            -- a small step each day: your wins make it harder, its wins easier
            local step = math.exp(0.08 * ((won and 1 or 0) - a.win))
            f.factor[rival] = math.max(0.4, math.min(1.7, factorOf(f, rival) * step))
        end
        f.settled = d
        changed = true
        d = nextDate(d)
    end
    if changed then
        local keep = dateOf(now - 60 * 86400)
        for k in pairs(f.results) do if k < keep then f.results[k] = nil end end
        store:saveSetting("rival_form", f)
        store:flush()
    end
end

-- Days you've beaten this rival lately: won, out of.
function Race.record(store, rival, days, now)
    local f = form(store)
    local since = dateOf((now or os.time()) - (days or 30) * 86400)
    local won, of = 0, 0
    for d, r in pairs(f.results) do
        if d >= since and r.rival == rival then
            of = of + 1
            if r.won then won = won + 1 end
        end
    end
    return won, of
end

-- ---------------------------------------------------------------- one book
-- In a book, keep it close: how hard the rival goes given the gap in days
-- of your reading (positive: the rival is ahead).
local function band(gap_days)
    if gap_days > 3 then return 0.6, "easing off" end
    if gap_days > 1.5 then return 0.85, "easing off" end
    if gap_days < -3 then return 1.2, "pushing" end
    if gap_days < -1.5 then return 1.1, "pushing" end
    return 1, nil
end

-- The race for one book.
--   rec    the book (pct, pages, hash, readest)
--   stats  Data.readingStats(rec.hash): book_start, book_start_pct, today
--   store  the Ledger's settings (LuaSettings)
--   you, rival  animal ids
--   m      Race.model()
--   peek   look without starting a race (a book not opened yet): the rival
--          waits level with you
-- Returns: total, you_pages, you_pct, rival_pages, rival_pct, rate (the
-- rival's pages a day at the moment), napping, rival_done, ahead (rival
-- pages minus yours), today_target, today, mood ("easing off", "pushing")
function Race.state(rec, stats, store, you, rival, m, now, peek)
    now = now or os.time()
    stats = stats or {}
    m = m or Race.model(nil, now)
    local today = dateOf(now)
    local total = (rec.pages and rec.pages > 0) and rec.pages or Race.DEFAULT_PAGES
    local you_pct = math.max(rec.pct or 0, rec.readest and rec.readest.pct or 0)
    local you_pages = math.floor(you_pct * total + 0.5)
    local a = Race.animal(rival)
    local factor = factorOf(form(store), rival)

    local races = store and store:readSetting("races") or {}
    local key = rec.hash or rec.file
    local r = key and races[key]
    if r and not r.through then r = nil end   -- a race from before the rival learned: start afresh
    if not r then
        -- a new race: from the first page of this book in the statistics
        -- (the rival starts where you were then), or from here, level with you
        r = {}
        if stats.book_start then
            r.start = stats.book_start
            r.rival = math.floor((stats.book_start_pct or 0) * total + 0.5)
        else
            r.start, r.rival = now, you_pages
        end
        r.through = dateOf(r.start - 86400)
    end

    -- settle whole days since the last visit
    local start_date = dateOf(r.start)
    local changed = false
    local d = nextDate(r.through)
    while d < today do
        local mult = band((r.rival - you_pages) / math.max(1, m.overall))
        local part = d == start_date and (1 - m.share(r.start)) or 1
        r.rival = math.min(total, r.rival + dayTarget(m, a, factor, d) * mult * part)
        r.through = d
        changed = true
        d = nextDate(d)
    end
    if key and store and not peek and (changed or not races[key]) then
        races[key] = r
        store:saveSetting("races", races)
        store:flush()
    end

    -- today so far: its share of today's target, at the hours you read
    local today_target = dayTarget(m, a, factor, today)
    local mult, mood = band((r.rival - you_pages) / math.max(1, m.overall))
    local from = start_date == today and m.share(r.start) or 0
    local rival_pages = math.min(total,
        math.floor(r.rival + today_target * mult * math.max(0, m.share(now) - from) + 0.5))
    return {
        total = total,
        you_pages = you_pages, you_pct = you_pct,
        rival_pages = rival_pages, rival_pct = rival_pages / total,
        rate = math.floor(m.overall * a.mult * factor * (a.nap and 2 / 3 or 1) + 0.5),
        napping = today_target == 0,
        -- a dead heat goes to you: you turned the last page
        rival_done = rival_pages >= total and you_pages < total,
        ahead = rival_pages - you_pages,
        today_target = math.floor(today_target + 0.5),
        today = stats.today or 0,
        mood = mood,
    }
end

-- ---------------------------------------------------------------- words
-- What the runners say when you tap them, the labels under the track and
-- the line about today. p: the plugin; race: Race.state().
function Race.lines(p, rec, race, cache)
    local you, rival = p:petName(p:runner()), p:petName(p:rival())
    local t = {}
    t.you_says = string.format("%s: I'm on page %d of %d.", you, math.max(1, race.you_pages), race.total)
    if require("ledger_data").readestAhead(rec) then t.you_says = t.you_says .. " Readest got me here." end
    if race.rival_done then
        t.rival_says = string.format("%s: Finished! Your turn.", rival)
    elseif race.napping then
        t.rival_says = string.format("%s: Zzz... napping today. Sneak past me!", rival)
    elseif race.ahead > 0 then
        t.rival_says = string.format("%s: I'm %d pages ahead -- catch me!", rival, race.ahead)
        if race.mood == "easing off" then t.rival_says = t.rival_says .. " (I'll take it easy for a bit.)" end
    elseif race.ahead < 0 then
        t.rival_says = string.format("%s: You're %d pages ahead of me.", rival, -race.ahead)
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
    t.you_label = string.format("%s (you) · p. %d", you, race.you_pages)
    t.rival_label = race.rival_done and string.format("%s · finished", rival)
        or string.format("%s · p. %d", rival, race.rival_pages)
    if race.napping then
        t.today = string.format("%s naps today: every page puts you further ahead.", rival)
    elseif race.today >= race.today_target then
        t.today = string.format("You out-read %s today: %d pages to %d.", rival, race.today, race.today_target)
    else
        t.today = string.format("Today %d of %d pages. %d more to out-read %s.", race.today, race.today_target,
            race.today_target - race.today, rival)
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
    local won, of = Race.record(p.settings, rival_id, 30, now)
    if of > 0 then
        lines[#lines + 1] = string.format("Last 30 days: on %d of %d days you'd read more than %s over the week before.", won, of, rival)
    end
    local a = Race.animal(rival_id)
    lines[#lines + 1] = string.format("%s is tuned so you're ahead about %d%% of the time, and adjusts a little after every day.",
        rival, math.floor(a.win * 100 + 0.5))
    return table.concat(lines, "\n\n")
end

return Race
