--[[
The Library's Series shelf (Library.seriesGroups / seriesCells): your books
in a series, by series, each in its own order, every series starting its
own row with a card naming it. Matt's Thrawn Trilogy (Calibre-Web says #1
and #2) among other books.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/series_shelf.lua
--]]
package.path = "./?.lua;" .. package.path
-- (the page's widgets aren't needed: anything this file requires is a stub)
local stub = setmetatable({}, { __index = function() return function() end end })
local real_require = require
require = function(name)
    if name:match("^ledger_") and name ~= "ledger_ui" and name ~= "ledger_data" and name ~= "ledger_race" then return real_require(name) end
    if package.loaded[name] then return package.loaded[name] end
    local m = setmetatable({ extend = function(_, t) return t end, screen = stub, scaleBySize = function(_, n) return n end },
        { __index = function() return function() return stub end end })
    package.loaded[name] = m
    return m
end
local Library = real_require("ledger_library")
require = real_require

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

local books = {
    { title = "Dark Force Rising", author = "Timothy Zahn", series = "Star Wars: The Thrawn Trilogy", series_index = 2, file = "/b/dfr.epub" },
    { title = "Red Rising", author = "Pierce Brown", series = "Red Rising", series_index = 1, file = "/b/rr.epub" },
    { title = "Heir to the Empire", author = "Timothy Zahn", series = "Star Wars: The Thrawn Trilogy", series_index = 1, file = "/b/heir.epub" },
    { title = "Verity", author = "Colleen Hoover", file = "/b/verity.epub" },                    -- in no series
    { title = "Morning Star", author = "Pierce Brown", series = "red rising", series_index = 3, file = "/b/ms.epub" },   -- (other case)
    { title = "Golden Son", author = "Pierce Brown", series = "Red Rising", series_index = 2, file = "/b/gs.epub" },
    { title = "Novella", author = "X", series = "Red Rising", file = "/b/n.epub" },                -- no number: last
}
local g = Library.seriesGroups(books)
ck(#g == 2 and g[1].name == "Red Rising" and g[2].name == "Star Wars: The Thrawn Trilogy", "two series, by name; a book in no series isn't on the shelf")
ck(#g[1].books == 4 and g[1].books[1].title == "Red Rising" and g[1].books[2].title == "Golden Son"
    and g[1].books[3].title == "Morning Star" and g[1].books[4].title == "Novella", "in series order (case doesn't split a series; unnumbered last)")
ck(g[2].books[1].title == "Heir to the Empire" and g[2].books[2].title == "Dark Force Rising", "Thrawn: #1 then #2")

local cells = Library.seriesCells(g, 4)
ck(#cells % 4 == 0, "every row full (blanks fill out a series' last row)")
ck(cells[1].series_header and cells[1].title == "Red Rising" and cells[1].count == 4 and cells[1].range == "#1-3", "a row starts with the series' card: name, count, numbers")
ck(cells[2].title == "Red Rising" and cells[2].author == "#1 · Pierce Brown" and cells[2].orig == books[2], "each book captioned with its number (and is still the book underneath)")
-- Red Rising: card + 4 books = 5 cells -> 8 with blanks; Thrawn starts the third row
ck(cells[4].title == "Morning Star" and cells[5].title == "Novella" and cells[6].blank and cells[7].blank and cells[8].blank,
    "a long series runs on to the next row, then blanks")
ck(cells[9].series_header and cells[9].title == "Star Wars: The Thrawn Trilogy" and cells[9].range == "#1-2", "the next series starts its own row")
ck(cells[10].author == "#1 · Timothy Zahn" and cells[11].author == "#2 · Timothy Zahn" and cells[12].blank, "Thrawn #1, #2, then a blank")
local three = Library.seriesCells(g, 3)
ck(#three == 9 and three[1].series_header and three[6].blank and three[7].series_header, "three across (small screens): the same rule")
ck(#Library.seriesCells(Library.seriesGroups({ books[4] }), 4) == 0, "no books in a series: an empty shelf")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
