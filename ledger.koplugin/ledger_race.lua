--[[
The race: you against a rival, over the whole book and day by day.

You pick your runner (cat, dog, rabbit or tortoise) and a rival. The rival
starts the book when you do and reads at a steady rate based on your own
usual pace (pages per reading day, from KOReader's statistics): the
tortoise reads what you usually read, the cat about 15% more, the dog about
30% more, and the rabbit twice as much -- but every third day it naps.
Pass it before the flag and you win; out-read today's share and you win the
day.

Your place is the furthest of this device and Readest.

Each book's race is fixed when it's first seen (start time, your pace then,
where you were), kept in the Ledger's settings, so the rival doesn't jump
about as your pace changes. Changing the rival changes its speed, not its
start.
--]]

local Race = {}

-- In difficulty order. day(k): how many of your usual days the rival reads
-- on day k of the race (k = 0 is the first day).
Race.ANIMALS = {
    { id = "tortoise", label = "Tortoise", name = "Shelly", hint = "Reads what you usually read",
      run = { "turtle_walk0", "turtle_walk1", "turtle_walk2", "turtle_walk3" }, still = "turtle_walk0",
      scale = 0.75, day = function() return 1 end },
    { id = "cat", label = "Cat", name = "Biscuit", hint = "Reads about 15% more than you",
      run = { "cat_run0", "cat_run1", "cat_run2", "cat_run3", "cat_run4", "cat_run5" }, still = "cat_run2",
      scale = 1, day = function() return 1.15 end },
    { id = "dog", label = "Dog", name = "Pip", hint = "Reads about 30% more than you",
      run = { "dog_run0", "dog_run1", "dog_run2", "dog_run3" }, still = "dog_run1",
      scale = 0.85, day = function() return 1.3 end },
    { id = "rabbit", label = "Rabbit", name = "Clover", hint = "Twice as fast, but naps every third day",
      run = { "rabbit_run0", "rabbit_run1", "rabbit_run2", "rabbit_run3", "rabbit_run4", "rabbit_run5" },
      still = "rabbit_run0", nap = "rabbit_idle5",
      scale = 1, day = function(k) return k % 3 == 2 and 0 or 2 end },
}

local BY_ID = {}
for _, a in ipairs(Race.ANIMALS) do BY_ID[a.id] = a end

function Race.animal(id) return BY_ID[id] or BY_ID.cat end

-- Your usual pages per reading day when there are no statistics yet.
Race.DEFAULT_PACE = 20
-- Book length to race over when the book's page count isn't known.
Race.DEFAULT_PAGES = 300

-- Pages the rival has read after `days` (fractional) of racing.
local function rivalPages(animal, usual, days)
    local whole = math.floor(days)
    local n = 0
    for k = 0, whole - 1 do n = n + usual * animal.day(k) end
    return n + usual * animal.day(whole) * (days - whole)
end

-- The race for one book.
--   rec    the book (pct, pages, hash, readest)
--   stats  Data.readingStats(rec.hash): per_day, book_start, book_start_pct, today
--   store  the Ledger's settings (LuaSettings), where races are kept
--   you, rival  animal ids
--   peek   look without starting a race (a book not opened yet): the rival
--          waits level with you
-- Returns a table:
--   total, you_pages, you_pct, rival_pages, rival_pct, rate (rival pages a
--   day, on average), napping, rival_done, ahead (rival pages minus yours),
--   today_target (rival's pages today), today (your pages today)
function Race.state(rec, stats, store, you, rival, now, peek)
    now = now or os.time()
    stats = stats or {}
    local total = (rec.pages and rec.pages > 0) and rec.pages or Race.DEFAULT_PAGES
    local you_pct = math.max(rec.pct or 0, rec.readest and rec.readest.pct or 0)
    local you_pages = math.floor(you_pct * total + 0.5)

    local races = store and store:readSetting("races") or {}
    local key = rec.hash or rec.file
    local r = key and races[key]
    if not r then
        -- a new race: from the first page of this book in the statistics
        -- (the rival starts where you were then), or, with none, from here
        -- (level with you)
        r = { usual = math.max(5, stats.per_day or Race.DEFAULT_PACE) }
        if stats.book_start then
            r.start, r.base = stats.book_start, math.floor((stats.book_start_pct or 0) * total + 0.5)
        else
            r.start, r.base = now, you_pages
        end
        if key and store and not peek then
            races[key] = r
            store:saveSetting("races", races)
            store:flush()
        end
    end

    local a = Race.animal(rival)
    local days = math.max(0, (now - r.start) / 86400)
    local rival_pages = math.min(total, math.floor(r.base + rivalPages(a, r.usual, days) + 0.5))
    local k = math.floor(days)
    local per_day = 0
    for d = 0, 2 do per_day = per_day + a.day(d) end
    return {
        total = total,
        you_pages = you_pages, you_pct = you_pct,
        rival_pages = rival_pages, rival_pct = rival_pages / total,
        rate = math.floor(r.usual * per_day / 3 + 0.5),
        napping = a.day(k) == 0,
        rival_done = rival_pages >= total,
        ahead = rival_pages - you_pages,
        today_target = math.floor(r.usual * a.day(k) + 0.5),
        today = stats.today or 0,
    }
end

-- What the runners say when you tap them, the labels under the track and
-- the line about today. race: Race.state().
function Race.lines(p, rec, race, cache)
    local you, rival = p:petName(p:runner()), p:petName(p:rival())
    local t = {}
    t.you_says = string.format("%s: I'm on page %d of %d.", you, math.max(1, race.you_pages), race.total)
    if require("ledger_data").readestAhead(rec) then t.you_says = t.you_says .. " Readest got me here." end
    if race.rival_done then
        t.rival_says = string.format("%s: Finished! I read about %d pages a day. Your turn.", rival, race.rate)
    elseif race.napping then
        t.rival_says = string.format("%s: Zzz... napping today. Sneak past me!", rival)
    elseif race.ahead > 0 then
        t.rival_says = string.format("%s: I read about %d pages a day. I'm %d pages ahead -- catch me!", rival, race.rate, race.ahead)
    elseif race.ahead < 0 then
        t.rival_says = string.format("%s: You're %d pages ahead of me. I read about %d a day...", rival, -race.ahead, race.rate)
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
    -- today
    if race.napping then
        t.today = string.format("%s naps today: every page puts you further ahead.", rival)
    elseif race.today >= race.today_target then
        t.today = string.format("You out-read %s today: %d pages to %d.", rival, race.today, race.today_target)
    else
        t.today = string.format("Today %d pages. %d more to out-read %s.", race.today,
            race.today_target - race.today, rival)
    end
    return t
end

return Race
