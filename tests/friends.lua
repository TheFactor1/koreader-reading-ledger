--[[
Racing friends from Hardcover (Net.hardcoverFriend): a friend's books in
progress and pages since Monday, parsed from the answer's real shape
(checked live 2026-10-07), with the network stubbed.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/friends.lua
--]]
package.path = "./?.lua;" .. package.path
for _, m in ipairs({ "json", "socket.http", "ssl.https", "libs/libkoreader-lfs", "ltn12", "socket", "socketutil" }) do
    package.loaded[m] = package.loaded[m] or {}
end
local Net = require("ledger_net")

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

local ANSWER = {
    users = { { username = "alex", user_books = {
        { book_id = 427473, book = { title = "Red Rising", pages = 382 },
          user_book_reads = { { progress = 30.42, progress_pages = 122, edition = { pages = 401 } } } },
        -- no percent, but pages and the book's length: worked out
        { book_id = 432760, book = { title = "Verity", pages = 336 },
          user_book_reads = { { progress = nil, progress_pages = 168, edition = { pages = nil } } } },
        -- nothing to place them by: left out
        { book_id = 459744, book = { title = "Unknown" }, user_book_reads = { { progress = nil, progress_pages = nil } } },
    } } },
    reading_journals = {
        { metadata = { pages_delta = 17 } }, { metadata = { pages_delta = 0 } },
        { metadata = { pages_delta = -40 } },   -- (moved back: not pages read)
        { metadata = { pages_delta = 25 } }, { metadata = {} },
    },
}
local asked
Net.hardcover = function(_t, query, vars) asked = vars; return ANSWER end

local r = Net.hardcoverFriend("tok", 42, os.time{ year = 2026, month = 10, day = 5, hour = 0 })
ck(r and r.username == "alex", "the friend's username")
ck(asked and asked.id == 42 and asked.since:match("^2026%-10%-0[45]T%d%d:%d%d:%d%dZ$"), "asked from Monday, in UTC (" .. tostring(asked and asked.since) .. ")")
local rr = r.reading["427473"]
ck(rr and math.abs(rr.pct - 0.3042) < 0.001 and rr.total == 401, "a book with Hardcover's percent: their place (" .. tostring(rr and rr.pct) .. ")")
local v = r.reading["432760"]
ck(v and math.abs(v.pct - 0.5) < 0.001, "no percent, pages and the book's length: 168/336 = half")
ck(r.reading["459744"] == nil, "nothing to place them by: not raced")
ck(r.pages == 42, "pages this week: the forward deltas only (" .. r.pages .. ")")

Net.hardcover = function() return nil, "rejected" end
local none, err = Net.hardcoverFriend("tok", 42, os.time())
ck(none == nil and err == "rejected", "a refused key: nothing, and why")
Net.hardcover = function() return { users = {}, reading_journals = {} } end
none = Net.hardcoverFriend("tok", 42, os.time())
ck(none == nil, "a user who's gone (or hidden): nothing")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
