--[[
Run network work in a forked child without blocking or trapping the UI.

Trapper:dismissableRunInSubprocess() is modal (a tap cancels it), which suits
a "Loading..." dialog but not a front page refreshing behind the reader's
back. This keeps the same fork / pipe / string.buffer protocol, polls from the
UIManager loop, and never shows anything.

Bg.run(task, on_done, timeout): task() runs in the child and may return plain
Lua values (tables of strings/numbers/booleans). on_done(true, ...) receives
them in the parent; on_done(false) means it failed, timed out or returned
nothing usable. The child is always reaped.
--]]

local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local buffer = require("string.buffer")
local logger = require("logger")

local Bg = {}

local function collectLater(pid, fd)
    local function collect()
        if fd and ffiutil.getNonBlockingReadSize(fd) ~= 0 then
            -- unblock a child stuck writing to a full pipe
            ffiutil.readAllFromFD(fd)
            fd = nil
        end
        if ffiutil.isSubProcessDone(pid) then
            if fd then ffiutil.readAllFromFD(fd) end
            return
        end
        UIManager:scheduleIn(1, collect)
    end
    UIManager:scheduleIn(1, collect)
end

function Bg.run(task, on_done, timeout)
    timeout = timeout or 45
    local pid, fd = ffiutil.runInSubProcess(function(_pid, child_fd)
        local str = ""
        local ok, packed = pcall(function() return table.pack(task()) end)
        if ok then
            local enc_ok, s = pcall(buffer.encode, packed)
            if enc_ok then str = s end
        else
            logger.warn("ledger bg task failed:", packed)
        end
        ffiutil.writeToFD(child_fd, str, true)
    end, true)

    local function finish(vals)
        if not on_done then return end
        local ok, err
        if vals then
            ok, err = pcall(on_done, true, table.unpack(vals, 1, vals.n or #vals))
        else
            ok, err = pcall(on_done, false)
        end
        if not ok then logger.warn("ledger bg callback failed:", err) end
    end

    if not pid then
        finish(nil)
        return
    end

    local started = os.time()
    local poll
    poll = function()
        local readable = fd and ffiutil.getNonBlockingReadSize(fd) ~= 0
        local done = not readable and ffiutil.isSubProcessDone(pid)
        if readable then
            local s = ffiutil.readAllFromFD(fd)
            fd = nil
            collectLater(pid, nil)
            local dec_ok, t = pcall(buffer.decode, s or "")
            finish((dec_ok and type(t) == "table") and t or nil)
            return
        end
        if done then
            -- it may have written and exited between the two checks
            local s = fd and ffiutil.readAllFromFD(fd)
            fd = nil
            local dec_ok, t = pcall(buffer.decode, s or "")
            finish((s and s ~= "" and dec_ok and type(t) == "table") and t or nil)
            return
        end
        if os.time() - started > timeout then
            logger.warn("ledger bg task timed out after", timeout, "s")
            ffiutil.terminateSubProcess(pid)
            collectLater(pid, fd)
            finish(nil)
            return
        end
        UIManager:scheduleIn(0.3, poll)
    end
    UIManager:scheduleIn(0.3, poll)
end

return Bg
