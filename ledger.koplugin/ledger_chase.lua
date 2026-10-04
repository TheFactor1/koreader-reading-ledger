--[[
The chase: the Reading page's race scene.

A field with distance marks and a chequered flag at the finish, where a fish
waits as the prize. The cat runs for this device, the dog for Readest. When
the page opens they sprint in from the start line to where you are, cycling
through their running frames (only this region redraws, in e-ink's fast
mode, then one clean refresh). Tap a pet and it tells you where it is.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local UI = require("ledger_ui")

local Screen = Device.screen

local Chase = InputContainer:extend{
    width = nil,
    height = nil,
    cat_pct = 0,
    dog_pct = nil,      -- nil: the dog isn't racing (sits at the start)
    cat_says = nil,     -- what each pet says when tapped
    dog_says = nil,
    fish_says = nil,
    animate = true,
    t = 1,              -- animation progress 0..1
    frame = 0,          -- running-pose frame
    say = nil,          -- { who = "cat"|"dog"|"fish", text = ... }
}

function Chase:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    self.pet_h = math.floor(self.height * 0.34)
    self.rects = {}
end

function Chase:getSize() return Geom:new{ w = self.width, h = self.height } end

local function ease(t) return 1 - (1 - t) ^ 3 end

function Chase:paintTo(bb, x, y)
    local function s(n) return Screen:scaleBySize(n) end
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.width, self.height
    local ground_h = math.max(s(6), math.floor(h * 0.08))
    local ground_y = y + h - ground_h
    local flag_w = math.max(s(10), math.floor(w * 0.03))
    local track_w = w - flag_w - s(4)
    bb:paintRect(x, y, w, h, UI.WHITE)

    -- ground and distance marks
    bb:paintRect(x, ground_y, w, ground_h, UI.INK3)
    for q = 0, 4 do
        local mx = x + math.floor(track_w * q / 4)
        bb:paintRect(mx, ground_y - s(8), math.max(1, s(2)), s(8), UI.INK3)
        if q > 0 and q < 4 then
            local lbl = UI.text(tostring(q * 25), "pix", 8, UI.INK3)
            local ls = lbl:getSize()
            lbl:paintTo(bb, mx - math.floor(ls.w / 2), ground_y - s(10) - ls.h)
            lbl:free()
        end
    end

    -- finish: a pole with a chequered flag, the fish on the ground beneath it
    local pole_x = x + track_w
    local pole_top = y + s(4)
    bb:paintRect(pole_x, pole_top, math.max(2, s(3)), ground_y - pole_top, UI.BLACK)
    local cell = math.max(3, math.floor(flag_w / 3))
    for fy = 0, cell * 3 - 1, cell do
        for fx = 0, flag_w - 1, cell do
            local black = (math.floor(fy / cell) + math.floor(fx / cell)) % 2 == 0
            bb:paintRect(pole_x + s(3) + fx, pole_top + fy, math.min(cell, flag_w - fx), cell,
                black and UI.BLACK or UI.WHITE)
        end
    end
    bb:paintBorder(pole_x + s(3), pole_top, flag_w, cell * 3, 1, UI.BLACK)
    local fish = UI.sprite("fish", UI.spriteScaleH("fish", math.floor(self.pet_h * 0.4)))
    local fs = fish:getSize()
    local fish_x = pole_x - fs.w - s(4)
    fish:paintTo(bb, fish_x, ground_y - fs.h)
    self.rects.fish = Geom:new{ x = fish_x, y = ground_y - fs.h, w = fs.w, h = fs.h }

    -- the runners: the dog a lane behind (higher up), the cat in front
    local t = ease(self.t or 1)
    local running = (self.t or 1) < 1
    -- one whole-number scale per animal, so frames of different heights
    -- don't make the pet pulse in size while it runs
    self.k = self.k or {
        cat = UI.spriteScaleH("cat_run2", self.pet_h),
        dog = UI.spriteScaleH("dog_run1", math.floor(self.pet_h * 0.85)),
    }
    local function place(name, pct, lane_y, key)
        local img = UI.sprite(name, self.k[key])
        local is = img:getSize()
        local px = x + math.floor(track_w * pct * t) - math.floor(is.w * 0.85)
        px = math.max(x, math.min(pole_x - is.w, px))
        img:paintTo(bb, px, lane_y - is.h)
        self.rects[key] = Geom:new{ x = px, y = lane_y - is.h, w = is.w, h = is.h }
        return px, is
    end
    -- two lanes: the dog runs on a dashed track in the upper half, the cat
    -- on the ground; neither ever covers the other
    local dog_lane = y + math.floor((ground_y - y) * 0.5)
    local cat_lane = ground_y
    local dash = s(6)
    for dx = 0, track_w, dash * 2 do
        bb:paintRect(x + dx, dog_lane + s(1), math.min(dash, track_w - dx), math.max(1, s(2)), UI.INK3)
    end
    if self.dog_pct then
        local dog_name = running and ("dog_run" .. (self.frame % 4)) or "dog_run1"
        place(dog_name, self.dog_pct, dog_lane, "dog")
    else
        place("dog_sit", 0, dog_lane, "dog")
    end
    local cat_name = running and ("cat_run" .. (self.frame % 6)) or "cat_run2"
    place(cat_name, self.cat_pct or 0, cat_lane, "cat")

    -- speech bubble for whoever was tapped
    if self.say and self.say.text and self.rects[self.say.who] then
        local r = self.rects[self.say.who]
        -- as wide as the words, up to a limit
        local max_w = math.min(math.floor(w * 0.55), s(260))
        local one_line = UI.text(self.say.text, "body", 10)
        local text_w = math.min(max_w, one_line:getSize().w + 1)
        one_line:free()
        local bubble = FrameContainer:new{
            bordersize = s(2), color = UI.BLACK, background = UI.WHITE, padding = s(5), margin = 0,
            UI.para(self.say.text, "body", 10, text_w),
        }
        local bs = bubble:getSize()
        -- kept left of the finish pole, so the flag always shows
        local bx = math.max(x, math.min(pole_x - s(6) - bs.w, r.x + math.floor(r.w / 2) - math.floor(bs.w / 2)))
        local by = math.max(y, r.y - bs.h - s(4))
        bubble:paintTo(bb, bx, by)
    end
end

function Chase:onTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    for _, who in ipairs({ "cat", "dog", "fish" }) do
        local r = self.rects[who]
        if r and p.x >= r.x - 10 and p.x <= r.x + r.w + 10 and p.y >= r.y - 10 and p.y <= r.y + r.h + 10 then
            local text = self[who .. "_says"]
            if self.say and self.say.who == who then self.say = nil else self.say = { who = who, text = text } end
            UIManager:setDirty(self.show_parent or self, "ui", self.dimen)
            return true
        end
    end
    if self.say then
        self.say = nil
        UIManager:setDirty(self.show_parent or self, "ui", self.dimen)
    end
    return true
end

-- Run the pets in from the start line.
function Chase:runIn()
    if not self.animate then self.t = 1 return end
    local frames = 10
    self.t, self.frame = 0, 0
    local i = 0
    local function step()
        i = i + 1
        self.t = i / frames
        self.frame = i
        local last = i >= frames
        UIManager:setDirty(self.show_parent or self, last and "ui" or "fast", self.dimen)
        if not last then UIManager:scheduleIn(0.08, step) end
    end
    UIManager:scheduleIn(0.25, step)
end

return Chase
