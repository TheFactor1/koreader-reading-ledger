--[[
Page turns that aren't the book (Data.cleanTurns), from cases on Matt's
Kindle: a one-page "Dune" stub, a README, a 404 page saved under "The Dark
Forest"'s checksum. None of them may count as a finished book.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/turns.lua
--]]
package.path = "./?.lua;" .. package.path
package.loaded["datastorage"] = { getSettingsDir = function() return "/x" end, getDataDir = function() return "/x" end }
for _, m in ipairs({ "docsettings", "json", "libs/libkoreader-lfs", "logger" }) do package.loaded[m] = {} end
local Data = require("ledger_data")

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end
local function row(page, tot) return { t = page, page = page, tot = tot, frac = page / tot } end

ck(Data.cleanTurns({ rows = { row(1, 1) } }) == nil, "a one-page document isn't a book")
ck(Data.cleanTurns({ rows = { row(5, 8), row(8, 8) } }) == nil, "an 8-page guide isn't a book (under 20 pages)")
local df = Data.cleanTurns({ rows = { row(1, 2), row(2, 2), row(1, 919), row(2, 919), row(3, 919) } })
ck(df and #df.rows == 3 and df.total == 919, "an error page's rows under the book's checksum are dropped")
local last = 0
for _, r in ipairs(df.rows) do if r.frac > last then last = r.frac end end
ck(last < 0.01, "...so it no longer reads as finished")
local two = Data.cleanTurns({ rows = { row(100, 300), row(300, 320) } })
ck(two and #two.rows == 2, "another device's edition (300 vs 320 pages) stays")
ck(Data.cleanTurns(nil) == nil and Data.cleanTurns({ rows = {} }) == nil, "nothing in, nothing out")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
