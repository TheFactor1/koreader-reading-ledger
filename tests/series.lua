--[[
What's next in a series, from Hardcover (Net.hardcoverSeriesNext): the
answer's shape as Hardcover's "Getting All Books in a Series" guide
describes it, with the network stubbed.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/series.lua
--]]
package.path = "./?.lua;" .. package.path
for _, m in ipairs({ "json", "socket.http", "ssl.https", "libs/libkoreader-lfs", "ltn12", "socket", "socketutil" }) do
    package.loaded[m] = package.loaded[m] or {}
end
local Net = require("ledger_net")

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

local function book(id, title, pos) return { position = pos, book = { id = id, title = title, release_year = 1960 + id,
    contributions = { { author = { name = "Frank Herbert" } } } } } end
local SERIES = { books_by_pk = { book_series = { { position = 2, series = { name = "Dune Chronicles", book_series = {
    book(1, "Dune", 1), book(2, "Dune Messiah", 2), book(25, "A Novella", 2.5), book(3, "Children of Dune", 3),
    book(4, "God Emperor of Dune", 4) } } } } } }
local MINE, asked = {}, {}
Net.hardcover = function(_token, query, vars)
    asked[#asked + 1] = { query = query, vars = vars }
    if query:find("LedgerSeriesMine") then return { me = { { user_books = MINE } } } end
    return SERIES
end
Net.fetchFile = function(_, path) return path end

-- 1. finished book 2: book 3 is next (the 2.5 novella is skipped)
local out = Net.hardcoverSeriesNext("tok", 2, nil)
ck(out and out.series == "Dune Chronicles" and out.position == 2, "the series and where the finished book is in it")
ck(out.next and out.next.title == "Children of Dune" and out.next.position == 3 and out.next.author == "Frank Herbert",
    "next: the next whole-numbered book, not the 2.5 novella (" .. tostring(out.next and out.next.title) .. ")")
ck(asked[2] and asked[2].vars.ids and #asked[2].vars.ids == 3, "your status asked for the books after it only")

-- 2. book 3 already read on Hardcover: book 4
asked = {}; MINE = { { book_id = 3, status_id = 3 } }
out = Net.hardcoverSeriesNext("tok", 2, nil)
ck(out.next and out.next.title == "God Emperor of Dune", "a book you've read is skipped")

-- 3. on your Want to Read: still next, and says so
MINE = { { book_id = 3, status_id = 1 } }
out = Net.hardcoverSeriesNext("tok", 2, nil)
ck(out.next and out.next.title == "Children of Dune" and out.next.status_id == 1, "on Want to Read: next, with its status")

-- 4. everything after it read but the novella: the novella
MINE = { { book_id = 3, status_id = 3 }, { book_id = 4, status_id = 3 } }
out = Net.hardcoverSeriesNext("tok", 2, nil)
ck(out.next and out.next.title == "A Novella", "only a novella left: the novella")

-- 5. the last book: a series, nothing next
MINE = {}
SERIES.books_by_pk.book_series[1].position = 4
out = Net.hardcoverSeriesNext("tok", 4, nil)
ck(out.series == "Dune Chronicles" and out.next == nil, "the last one: no next")

-- 6. not in a series / Hardcover unreachable
SERIES = { books_by_pk = { book_series = {} } }
out = Net.hardcoverSeriesNext("tok", 9, nil)
ck(out and out.none, "not in a series: says so (and isn't asked again for a week)")
Net.hardcover = function() return nil, "connection error" end
local o2, err = Net.hardcoverSeriesNext("tok", 9, nil)
ck(o2 == nil and err, "Hardcover unreachable: nothing, and the error (asked again next time)")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
