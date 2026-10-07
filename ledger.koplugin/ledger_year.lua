--[[
Your year in reading: one page, from the statistics -- which Readest keeps
in step between your devices, so every device shows the same year.

  pages, books finished, days you read, hours
  your best streak, your biggest day, the race against your rival, the
  quickest book
  pages month by month
  the books you finished, newest first

Opened from the counts on the front page (Today / This week / Streak);
< and > step through the years the statistics have.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local UIManager = require("ui/uimanager")
local Data = require("ledger_data")
local UI = require("ledger_ui")

local Screen = Device.screen

local MONTHS = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" }

local Year = InputContainer:extend{
    name = "ledger_year",
    covers_fullscreen = true,
    plugin = nil,
    year = nil,     -- the year shown (a number); this year when nil
}
UI.refitOnResize(Year)

-- What a year adds up to. habits: Data.allHabits() (days up to yesterday);
-- today: pages today (counted apart: the replay never reads today);
-- results: the finished books (Ledger:finishedBooks(): won/by where the
-- race could judge it).
function Year.compute(year, habits, today, results, now)
    now = now or os.time()
    local days = {}
    for d, n in pairs(habits and habits.days or {}) do
        if tonumber(d:sub(1, 4)) == year then days[d] = n end
    end
    local today_date = os.date("%Y-%m-%d", now)
    if (today or 0) > 0 and tonumber(today_date:sub(1, 4)) == year then days[today_date] = today end
    local y = { year = year, pages = 0, days = 0, months = {}, best_day = 0, streak = 0,
        books = {}, won = 0, lost = 0 }
    for m = 1, 12 do y.months[m] = 0 end
    local dates = {}
    for d, n in pairs(days) do
        if n > 0 then
            dates[#dates + 1] = d
            y.pages = y.pages + n
            y.days = y.days + 1
            local m = tonumber(d:sub(6, 7))
            y.months[m] = y.months[m] + n
            if n > y.best_day then y.best_day, y.best_day_on = n, d end
        end
    end
    -- the longest run of days in a row, within the year
    table.sort(dates)
    local run, prev = 0, nil
    for _, d in ipairs(dates) do
        local t = os.time{ year = tonumber(d:sub(1, 4)), month = tonumber(d:sub(6, 7)), day = tonumber(d:sub(9, 10)), hour = 12 }
        if prev and math.abs(t - prev - 86400) < 7200 then run = run + 1 else run = 1 end
        if run > y.streak then y.streak = run end
        prev = t
    end
    -- the books finished in it (the race decided each one at its last page)
    for _, r in ipairs(results or {}) do
        if r.at and tonumber(os.date("%Y", r.at)) == year then
            y.books[#y.books + 1] = r
            if r.won == true then y.won = y.won + 1 elseif r.won == false then y.lost = y.lost + 1 end
            if r.started and r.at > r.started then
                local took = math.max(1, math.ceil((r.at - r.started) / 86400))
                if not y.quickest or took < y.quickest_days then y.quickest, y.quickest_days = r, took end
            end
        end
    end
    table.sort(y.books, function(a, b) return a.at > b.at end)
    return y
end

-- The years the statistics have, oldest first (always this year).
function Year.span(habits, now)
    local this = tonumber(os.date("%Y", now or os.time()))
    local first = habits and habits.first and tonumber(habits.first:sub(1, 4)) or this
    return math.min(first, this), this
end

function Year:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    UI.addTopMenu(self)
    self[1] = self:build()
end

function Year:onClose()
    UIManager:close(self, "flashui")
    return true
end

function Year:go(year)
    local first, last = Year.span(Data.allHabits())
    if year < first or year > last then return end
    self.year = year
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

-- A number and what it is, centred in its column.
local function block(value, label, w)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local vg = VerticalGroup:new{ align = "center",
        UI.text(value, "bold", 16, UI.BLACK, w), UI.text(label:upper(), "pix", 8, UI.INK2, w - Screen:scaleBySize(4)) }
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = vg:getSize().h }, vg }
end

local function shortDate(d)
    if not d then return "" end
    local t = os.time{ year = tonumber(d:sub(1, 4)), month = tonumber(d:sub(6, 7)), day = tonumber(d:sub(9, 10)), hour = 12 }
    return os.date("%d %b", t)
end

local function thousands(n)
    local s = tostring(math.floor(n + 0.5))
    while true do
        local k
        s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if k == 0 then return s end
    end
end

function Year:build()
    local function s(n) return Screen:scaleBySize(n) end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m
    local p = self.plugin
    local habits = Data.allHabits()
    local first, last = Year.span(habits)
    local year = self.year or last
    local today = (year == last) and (p:readingCounts()) or 0
    local y = Year.compute(year, habits, today, p:finishedBooks())
    local t0 = os.time{ year = year, month = 1, day = 1, hour = 0 }
    local t1 = os.time{ year = year + 1, month = 1, day = 1, hour = 0 }
    local hours = Data.readingSeconds(t0, t1) / 3600

    local main = VerticalGroup:new{ align = "left" }
    local function add(w) main[#main + 1] = w end

    -- header: back, and the year with arrows where there's more
    local nav = HorizontalGroup:new{ align = "center" }
    nav[#nav + 1] = UI.link(year > first and "<" or " ", function() self:go(year - 1) end)
    nav[#nav + 1] = UI.hspace(s(10))
    nav[#nav + 1] = UI.text(string.format("YOUR %d", year), "pix", 11)
    nav[#nav + 1] = UI.hspace(s(10))
    nav[#nav + 1] = UI.link(year < last and ">" or " ", function() self:go(year + 1) end)
    add(UI.header(cw, UI.link("< BACK", function() self:onClose() end), nav))
    add(UI.vspace(s(14)))

    if y.pages == 0 and #y.books == 0 then
        add(UI.para(year == last
            and "Nothing read this year yet -- or KOReader's reading statistics are off. Every page you turn counts from here."
            or "No reading in the statistics for this year.", "body", 13, cw, UI.INK2))
    else
        local bw = math.floor(cw / 4)
        local rival = p:petName(p:rival())
        local function row(...)
            local hg = HorizontalGroup:new{ align = "center" }
            for _, b in ipairs({ ... }) do hg[#hg + 1] = b end
            return hg
        end
        add(UI.rule(cw, s(2)))
        add(UI.vspace(s(8)))
        add(row(block(thousands(y.pages), "pages", bw), block(tostring(#y.books), #y.books == 1 and "book" or "books", bw),
            block(tostring(y.days), y.days == 1 and "day read" or "days read", bw),
            block(hours >= 10 and tostring(math.floor(hours + 0.5)) or string.format("%.1f", hours), "hours", cw - 3 * bw)))
        add(UI.vspace(s(10)))
        add(row(block(y.streak .. (y.streak == 1 and " day" or " days"), "best streak", bw),
            block(thousands(y.best_day) .. " p", "biggest day" .. (y.best_day_on and (" · " .. shortDate(y.best_day_on)) or ""), bw),
            UI.tappable(block(string.format("%d-%d", y.won, y.lost), "vs " .. rival, bw), function() p:showResults() end),
            block(y.quickest and (y.quickest_days .. (y.quickest_days == 1 and " day" or " days")) or "--", "quickest book", cw - 3 * bw)))
        add(UI.vspace(s(8)))
        add(UI.rule(cw, s(2)))
        add(UI.vspace(s(16)))

        -- pages month by month
        add(UI.text("PAGES BY MONTH", "pix", 9, UI.INK2))
        add(UI.vspace(s(8)))
        local most = 0
        for i = 1, 12 do if y.months[i] > most then most = y.months[i] end end
        local chart_h = math.floor(math.min(H * 0.14, s(110)))
        local gap = s(6)
        local col_w = math.floor((cw - 11 * gap) / 12)
        local this_month = (year == last) and tonumber(os.date("%m")) or 12
        local chart = HorizontalGroup:new{ align = "bottom" }
        for i = 1, 12 do
            local n = y.months[i]
            local bar_h = most > 0 and math.floor(chart_h * n / most + 0.5) or 0
            if n > 0 then bar_h = math.max(bar_h, s(2)) end
            local col = VerticalGroup:new{ align = "center",
                UI.vspace(chart_h - bar_h),
                UI.rule(col_w, math.max(bar_h, 1), n > 0 and UI.BLACK or UI.INK4),
                UI.vspace(s(4)),
                UI.text(MONTHS[i], "pix", 8, i <= this_month and UI.BLACK or UI.INK2),
            }
            if i > 1 then chart[#chart + 1] = UI.hspace(gap) end
            chart[#chart + 1] = col
        end
        add(chart)
        add(UI.vspace(s(4)))
        add(UI.text(string.format("Most in a month: %s pages", thousands(most)), "body", 10, UI.INK2, cw))
        add(UI.vspace(s(16)))

        -- the books finished, newest first, as many as fit
        add(UI.text(#y.books > 0 and "FINISHED" or "FINISHED -- NONE YET THIS YEAR", "pix", 9, UI.INK2))
        add(UI.vspace(s(4)))
        add(UI.rule(cw, s(1), UI.INK3))
        local used = main:getSize().h + 2 * m
        local shown = 0
        for _, r in ipairs(y.books) do
            local left = VerticalGroup:new{ align = "left",
                UI.text(r.title or "?", "bold", 12, UI.BLACK, math.floor(cw * 0.66)),
            }
            if r.author then left[#left + 1] = UI.text(r.author, "body", 10, UI.INK2, math.floor(cw * 0.66)) end
            local verdict = r.won == true and string.format("WON BY %d", r.by or 0) or r.won == false and "LOST" or "FINISHED"
            local right = VerticalGroup:new{ align = "right",
                UI.text(verdict, "pix", 9), UI.text(os.date("%d %b", r.at), "body", 10, UI.INK2) }
            local line = VerticalGroup:new{ align = "left",
                UI.vspace(s(6)), UI.spread(cw, left, right), UI.vspace(s(6)), UI.rule(cw, s(1), UI.INK3) }
            local h = line:getSize().h
            -- (room for one more line, and for the "and N more" under it)
            if used + h + s(30) > H and shown < #y.books then
                add(UI.vspace(s(6)))
                add(UI.tappable(UI.text(string.format("and %d more ›", #y.books - shown), "body", 11, UI.BLACK),
                    function() p:showFinished(year) end))
                break
            end
            add(line)
            used = used + h
            shown = shown + 1
        end
    end

    -- (measured while it was built: lay it out again with everything in)
    main:resetLayout()
    -- (the whole screen, white: a short year mustn't show what's below)
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0, padding = m,
        VerticalGroup:new{ align = "left", main, UI.vspace(math.max(0, H - 2 * m - main:getSize().h)) },
    }
end

return Year
