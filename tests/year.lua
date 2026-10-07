--[[
Your year in reading (ledger_year.lua): what a year adds up to, from the
statistics' days and the race results.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/year.lua
--]]
package.path = "./?.lua;" .. package.path
-- (Year.compute is plain arithmetic; the page's modules aren't needed)
for _, m in ipairs({ "device", "ui/widget/container/framecontainer", "ui/geometry", "ui/widget/horizontalgroup",
        "ui/widget/verticalgroup", "ui/uimanager", "ledger_data" }) do
    package.loaded[m] = package.loaded[m] or setmetatable({ screen = {} }, { __index = function() return function() end end })
end
package.loaded["ui/widget/container/inputcontainer"] = { extend = function(_, t) return t end }
package.loaded["ledger_ui"] = { refitOnResize = function() end }
local Year = require("ledger_year")

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function t(d) return os.time{ year = tonumber(d:sub(1, 4)), month = tonumber(d:sub(6, 7)), day = tonumber(d:sub(9, 10)), hour = 20 } end

local habits = { first = "2025-12-28", days = {
    ["2025-12-29"] = 30, ["2025-12-30"] = 40, ["2025-12-31"] = 10,     -- last year
    ["2026-01-01"] = 20, ["2026-01-02"] = 25, ["2026-01-03"] = 15,     -- a 3-day run over the new year
    ["2026-02-10"] = 90,                                               -- the biggest day
    ["2026-03-01"] = 5, ["2026-03-02"] = 5, ["2026-03-03"] = 5, ["2026-03-04"] = 5,  -- the best run in 2026: 4
    ["2026-03-06"] = 0,                                                -- a zero isn't a day read
} }
local results = {
    { title = "A", won = true, by = 12, at = t("2026-01-03"), started = t("2025-12-29") },
    { title = "B", won = false, at = t("2026-03-04"), started = t("2026-03-02") },
    { title = "C", won = true, by = 3, at = t("2025-12-31"), started = t("2025-12-01") },   -- last year's
    { title = "D", at = t("2026-02-20") },   -- finished (KOReader's mark, Hardcover), no race to judge
}
local now = t("2026-03-10")
local y = Year.compute(2026, habits, 33, results, now)
ck(y.pages == 20 + 25 + 15 + 90 + 20 + 33, "pages: this year's days plus today (" .. y.pages .. ")")
ck(y.days == 9, "days read: only days with pages, today included (" .. y.days .. ")")
ck(y.streak == 4, "best streak counts within the year, not across the new year (" .. y.streak .. ")")
ck(y.best_day == 90 and y.best_day_on == "2026-02-10", "biggest day and its date")
ck(y.months[1] == 60 and y.months[2] == 90 and y.months[3] == 20 + 33, "pages by month (today in March)")
ck(#y.books == 3 and y.books[1].title == "B", "books finished this year, newest first; last year's left out")
ck(y.won == 1 and y.lost == 1, "won and lost: only the races judged (a book finished without one isn't a loss)")
ck(y.quickest and y.quickest.title == "B" and y.quickest_days == 2, "quickest book: started to finished (" .. tostring(y.quickest_days) .. " days)")

local y25 = Year.compute(2025, habits, 33, results, now)
ck(y25.pages == 80 and #y25.books == 1, "another year: its own days, no 'today', its own books")
local first, last = Year.span(habits, now)
ck(first == 2025 and last == 2026, "the years the statistics have")
local none = Year.compute(2026, nil, 0, nil, now)
ck(none.pages == 0 and none.days == 0 and none.streak == 0 and #none.books == 0, "no statistics at all: zeros, no errors")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
