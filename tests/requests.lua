--[[
The Requested shelf (Data.requestState): Shelfmark's requests as Matt's
account had them on 2026-10-07 -- 4 rejected, 11 delivered in September,
and "Heir to the Empire", requested, approved and delivered to Calibre-Web
within a minute, which then vanished from Requested while still only on the
server. Times are Shelfmark's own (UTC).

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/requests.lua
--]]
package.path = "./?.lua;" .. package.path
package.loaded["datastorage"] = { getSettingsDir = function() return "/x" end, getDataDir = function() return "/x" end }
for _, m in ipairs({ "docsettings", "json", "libs/libkoreader-lfs", "logger" }) do package.loaded[m] = {} end
local Data = require("ledger_data")

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

local function req(id, status, ds, created, reviewed, delivered, title, author)
    return { id = id, status = status, delivery_state = ds, created_at = created, reviewed_at = reviewed ~= "" and reviewed or nil,
        delivery_updated_at = delivered ~= "" and delivered or nil, book_data = { title = title, author = author } }
end
local ROWS = {
    req(1, "rejected", "none", "2026-09-02 06:49:28", "2026-09-02T07:00:49+00:00", "", "The Andromeda Strain", "Michael Crichton"),
    req(2, "fulfilled", "complete", "2026-09-02 07:08:14", "2026-09-02T15:24:51+00:00", "2026-09-02T15:24:56+00:00", "11/22/63", "Stephen King"),
    req(6, "rejected", "none", "2026-09-02 17:52:21", "2026-09-02T17:52:37+00:00", "", "The Stand", "Stephen King"),
    req(8, "rejected", "none", "2026-09-02 18:35:20", "2026-09-02T18:35:58+00:00", "", "Summer Frost", "Blake Crouch"),
    req(13, "fulfilled", "complete", "2026-09-03 03:53:44", "2026-09-03T03:53:59+00:00", "2026-09-03T03:54:06+00:00", "Dune", "Frank Herbert"),
    req(21, "rejected", "none", "2026-09-03 18:21:57", "2026-09-03T18:53:00+00:00", "", "Shining Rock", "Blake Crouch"),
    req(22, "fulfilled", "complete", "2026-10-07 19:49:23", "2026-10-07T19:50:29+00:00", "2026-10-07T19:50:35+00:00", "Heir to the Empire", "Timothy Zahn"),
}
-- 20:00 UTC that evening, worked out the way the Ledger reads Shelfmark's times
local now = Data.utcTime("2026-10-07T20:00:00+00:00")
local on = {}
local function onDevice(title) return on[title] == true end
local function shelf()
    local out = {}
    for _, r in ipairs(ROWS) do
        local state, title = Data.requestState(r, now, onDevice)
        if state then out[#out + 1] = { title = title, state = state } end
    end
    return out
end

ck(Data.utcTime("2026-10-07T19:50:35+00:00") - now == -565 and Data.utcTime("2026-10-07 19:49:23") - now == -637,
    "Shelfmark's two time formats read as UTC, whatever this device's zone")
local s = shelf()
ck(#s == 1 and s[1].title == "Heir to the Empire" and s[1].state == "ready",
    "just delivered to the server, not on the Kindle: on the shelf, ready to get")
local rejected_listed = false
for _, r in ipairs(s) do if r.title == "Shining Rock" or r.title == "The Andromeda Strain" then rejected_listed = true end end
ck(not rejected_listed, "the 4 rejected requests aren't 'waiting' (they made the screen say 'waiting for 4')")
ck(Data.requestState(ROWS[2], now, onDevice) == nil, "delivered a month ago: off the shelf (two weeks at most)")
on["Heir to the Empire"] = true
ck(#shelf() == 0, "on the Kindle: off the shelf")
on["Heir to the Empire"] = nil

-- the states before delivery
ck(Data.requestState({ status = "pending", delivery_state = "none", book_data = { title = "X" } }, now, onDevice) == "pending",
    "not approved yet: waiting for approval")
ck(Data.requestState({ status = "approved", delivery_state = "queued", book_data = { title = "X" } }, now, onDevice) == "coming",
    "approved, being fetched: coming")
ck(Data.requestState({ status = "approved", delivery_state = "error", book_data = { title = "X" } }, now, onDevice) == nil,
    "a delivery that failed isn't waiting (Bookbridge says so, once)")
ck(Data.requestState({ status = "cancelled", delivery_state = "none", book_data = { title = "X" } }, now, onDevice) == nil,
    "cancelled: not waiting")
ck(Data.requestState({ status = "fulfilled", delivery_state = "complete", book_data = { title = "X" } }, now, onDevice) == nil,
    "delivered with no time at all: not listed (can't tell how old)")
ck(Data.requestState({ status = "pending", delivery_state = "none", title = "Top", book_data = {} }, now, onDevice) == "pending",
    "a title on the request itself is used when book_data has none")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
