--[[
Hardcover vibes as Library shelves (Net.hardcoverVibes, Net.hardcoverVibeBooks):
the answers' shapes as seen live on Matt's account 2026-10-07, network stubbed.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/vibes.lua
--]]
package.path = "./?.lua;" .. package.path
for _, m in ipairs({ "json", "socket.http", "ssl.https", "libs/libkoreader-lfs", "ltn12", "socket", "socketutil" }) do
    package.loaded[m] = package.loaded[m] or {}
end
local Net = require("ledger_net")

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

local function author(name) return { { contribution = "Author", author = { name = name } } } end
local ANSWERS = {
    LedgerMe = { me = { { id = 155829 } } },
    LedgerVibes = {
        vibes = { { id = 7309, title = "Top Picks", vibe_type = 3 }, { id = 7310, title = "Recommendations", vibe_type = 1 },
                  { id = 9001, title = "My cozy one", vibe_type = 0 } },
        likes = { { vibe = { id = 3, title = "Time Travel", user = { username = "adam" } } },
                  { vibe = { id = 33, title = "AI Science Fiction", user = { username = "adam" } } } },
    },
    LedgerVibe = { vibes_by_pk = { cached_book_ids = { 427570, 376832, 99422, 5, 6 } } },
    LedgerVibeBooks = {
        books = { { id = 99422, title = "Artemis", release_year = 2017, cached_contributors = author("Andy Weir") },
                  { id = 427570, title = "Dust", release_year = 2013, cached_contributors = author("Hugh Howey") },
                  { id = 376832, title = "The Institute", release_year = 2019, cached_contributors = author("Stephen King") },
                  { id = 5, title = "Read Already", cached_contributors = author("X") },
                  { id = 6, title = "Wanted", cached_contributors = { { contribution = "Illustrator", author = { name = "Not Them" } }, { author = { name = "Y" } } } } },
        me = { { user_books = { { book_id = 5, status_id = 3 }, { book_id = 6, status_id = 1 } } } },
    },
}
local asked = {}
Net.hardcover = function(_t, query, vars)
    local name = query:match("query%s+(%w+)")
    asked[#asked + 1] = { name = name, vars = vars }
    return ANSWERS[name]
end

local v = Net.hardcoverVibes("tok")
ck(v and #v == 5, "your three vibes and the two you liked (" .. tostring(v and #v) .. ")")
ck(v[1].title == "Recommendations" and v[2].title == "Top Picks" and v[1].kind == "discover", "Discover's first: Recommendations, then Top Picks")
ck(v[3].kind == "mine" and v[3].title == "My cozy one", "then your own")
ck(v[4].kind == "liked" and v[4].by == "adam" and v[4].title == "Time Travel", "then the ones you liked, with who made them")

local b = Net.hardcoverVibeBooks("tok", 7310, 24, nil)
ck(b and b[1].title == "Dust" and b[2].title == "The Institute" and b[3].title == "Artemis", "in the vibe's own order")
ck(b[1].author == "Hugh Howey" and b[3].year == 2017, "with author and year")
local titles = {}
for _, x in ipairs(b) do titles[x.title] = x end
ck(titles["Read Already"] == nil, "a book you've read isn't a discovery")
ck(titles["Wanted"] and titles["Wanted"].status_id == 1 and titles["Wanted"].author == "Y", "on your Want to Read: kept, and says so; an illustrator isn't the author")
local lim = Net.hardcoverVibeBooks("tok", 7310, 2, nil)
ck(#lim == 2, "a shelf of the size asked for")

ANSWERS.LedgerMe = nil
local none, err = Net.hardcoverVibes("tok")
ck(none == nil and err, "no answer (a key without read:vibes): nothing, and why")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
