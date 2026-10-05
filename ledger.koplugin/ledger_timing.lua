--[[
Timing log, for finding what makes the Ledger slow on a device. Off unless
a file named "timing" exists in the plugin folder; then each step logs
"LEDGERTIME <step> <ms>" to KOReader's log (crash.log on a Kindle).
--]]
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")

local T = { on = false }

function T.init(plugin_dir)
    T.on = lfs.attributes(plugin_dir .. "/timing", "mode") == "file"
end

-- local t = T.start(); ...; T.lap(t, "step") -> logs ms since start/last lap
function T.start() return { t0 = time.now(), last = time.now() } end

function T.lap(t, label)
    if not T.on or not t then return end
    local now = time.now()
    logger.info("LEDGERTIME", label, time.to_ms(now - t.last), "total", time.to_ms(now - t.t0))
    t.last = now
end

return T
