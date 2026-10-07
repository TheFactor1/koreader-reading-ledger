--[[
The front page's counts (today, this week, streak): KOReader's statistics
when there are any -- synced from every device -- and this device's own
position moves only without them. A move isn't reading: jumping to the end
or the notes, or to where another device got to, once counted as pages.

Run from ledger.koplugin with KOReader's luajit:
  cd ledger.koplugin && <koreader>/luajit ../tests/habits.lua
--]]
package.path = "./?.lua;" .. package.path
-- (just enough KOReader for ledger_readest to load)
package.loaded["datastorage"] = { getSettingsDir = function() return "/nonexistent" end }
package.loaded["ui/network/manager"] = { isOnline = function() return false end }
package.loaded["ui/uimanager"] = { scheduleIn = function() end, nextTick = function() end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
local R = require("ledger_readest")

local pass, fail = 0, 0
local function ck(c, m) if c then pass = pass + 1; print("PASS  " .. m) else fail = fail + 1; print("FAIL  " .. m) end end

local function store(t)
    local s = { data = t or {} }
    function s:readSetting(k) return self.data[k] end
    function s:saveSetting(k, v) self.data[k] = v end
    function s:flush() end
    return s
end

local D = "2026-10-07"
-- a jump to the end today: 177 pages "moved" on this device
local function moved() return store({ readest_read = { dev_days = { [D] = 177 }, log = {}, gains = {}, dev = {} } }) end

-- 1. statistics on: they count, the move doesn't
R.forget()
local h = R.mergeHabits({ days = { [D] = 28, ["2026-10-06"] = 30 }, hours = { [21] = 1 } }, moved())
ck(h.days[D] == 28, "statistics on: today is the statistics' 28 pages, not the 177-page jump (" .. tostring(h.days[D]) .. ")")
ck(h.days["2026-10-06"] == 30, "...and the other days stay as the statistics have them")

-- 2. no statistics at all: the position is the best there is
R.forget()
h = R.mergeHabits(nil, moved())
ck(h and h.days[D] == 177, "no statistics: this device's moves stand in (" .. tostring(h and h.days[D]) .. ")")

-- 3. statistics on but nothing moved: unchanged
R.forget()
h = R.mergeHabits({ days = { [D] = 12 }, hours = { [8] = 1 } }, store({}))
ck(h.days[D] == 12, "nothing in the device log: the statistics as they are")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
