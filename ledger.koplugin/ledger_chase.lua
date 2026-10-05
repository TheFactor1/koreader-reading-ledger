--[[
The chase: the Currently reading page's race scene.

A field with distance marks and a chequered flag at the finish, where a fish
waits as the prize. Your runner is on the ground, your rival on the dashed
lane above (see ledger_race.lua). When the page opens they sprint in from
the start line to where they are, cycling through their running frames
(only this region redraws, in e-ink's fast mode, then one clean refresh).
A napping rabbit lies still with a Z over it. Tap a runner and it tells you
where it is.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Race = require("ledger_race")
local UI = require("ledger_ui")

local Screen = Device.screen

local Chase = InputContainer:extend{
    width = nil,
    height = nil,
    style = "field",    -- the look (Chase.STYLES)
    you = "cat",        -- animal ids (ledger_race.lua)
    rival = "dog",
    you_pct = 0,
    rival_pct = 0,
    napping = false,    -- the rabbit, on its day off
    you_says = nil,     -- what each says when tapped
    rival_says = nil,
    fish_says = nil,
    animate = true,
    t = 1,              -- animation progress 0..1
    frame = 0,          -- running-pose frame
    say = nil,          -- { who = "you"|"rival"|"fish", text = ... }
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

-- ---------------------------------------------------------------- scenes
-- Each style paints its backdrop and says where the track runs and where
-- each runner stands: { x0, track_w, pole_x, rival_lane, you_lane } (the
-- lanes are the y the runners' feet touch). The runners, the run-in and
-- the speech bubbles are the same for every style.
local Scenes = {}

local function cheq(bb, x, y, w, h, cell)
    for fy = 0, h - 1, cell do
        for fx = 0, w - 1, cell do
            local black = (math.floor(fy / cell) + math.floor(fx / cell)) % 2 == 0
            bb:paintRect(x + fx, y + fy, math.min(cell, w - fx), math.min(cell, h - fy), black and UI.BLACK or UI.WHITE)
        end
    end
end

local function label(bb, str, size, color, cx, y_bottom)
    local t = UI.text(str, "pix", size, color)
    local ts = t:getSize()
    t:paintTo(bb, cx - math.floor(ts.w / 2), y_bottom - ts.h)
    t:free()
    return ts
end

local function fishAt(self, bb, x, y_bottom, h)
    local fish = UI.sprite("fish", UI.spriteScaleH("fish", h))
    local fs = fish:getSize()
    fish:paintTo(bb, x, y_bottom - fs.h)
    self.rects.fish = Geom:new{ x = x, y = y_bottom - fs.h, w = fs.w, h = fs.h }
    return fs
end

-- The field: a grey ground, distance marks, the rival on a dashed lane
-- above, a chequered flag on a pole and the fish under it.
function Scenes.field(self, bb, x, y, w, h, s)
    local ground_h = math.max(s(6), math.floor(h * 0.08))
    local ground_y = y + h - ground_h
    local flag_w = math.max(s(10), math.floor(w * 0.03))
    local track_w = w - flag_w - s(4)
    bb:paintRect(x, ground_y, w, ground_h, UI.INK3)
    for q = 0, 4 do
        local mx = x + math.floor(track_w * q / 4)
        bb:paintRect(mx, ground_y - s(8), math.max(1, s(2)), s(8), UI.INK3)
        if q > 0 and q < 4 then label(bb, tostring(q * 25), 8, UI.INK3, mx, ground_y - s(10)) end
    end
    local pole_x = x + track_w
    local pole_top = y + s(4)
    bb:paintRect(pole_x, pole_top, math.max(2, s(3)), ground_y - pole_top, UI.BLACK)
    local cell = math.max(3, math.floor(flag_w / 3))
    cheq(bb, pole_x + s(3), pole_top, flag_w, cell * 3, cell)
    bb:paintBorder(pole_x + s(3), pole_top, flag_w, cell * 3, 1, UI.BLACK)
    local fh = math.floor(self.pet_h * 0.4)
    local fish = UI.sprite("fish", UI.spriteScaleH("fish", fh))
    fishAt(self, bb, pole_x - fish:getSize().w - s(4), ground_y, fh)
    local rival_lane = y + math.floor((ground_y - y) * 0.5)
    local dash = s(6)
    for dx = 0, track_w, dash * 2 do
        bb:paintRect(x + dx, rival_lane + s(1), math.min(dash, track_w - dx), math.max(1, s(2)), UI.INK3)
    end
    return { x0 = x, track_w = track_w, pole_x = pole_x, rival_lane = rival_lane, you_lane = ground_y }
end

-- An athletics track: two grey lanes with white lines, lane numbers, a
-- start line and a chequered finish across both lanes; the fish waits on
-- top of the finish.
function Scenes.track(self, bb, x, y, w, h, s)
    local fh = math.floor(self.pet_h * 0.4)
    local top = y + fh + s(6)
    local bottom = y + h - s(16)
    local lane_h = math.floor((bottom - top) / 2)
    local line = math.max(2, s(3))
    local finish_w = math.max(s(14), math.floor(w * 0.035))
    local x0 = x + s(22)
    local pole_x = x + w - finish_w - s(2)
    local track_w = pole_x - x0
    bb:paintRect(x, top, w, lane_h * 2, UI.INK4)
    for i = 0, 2 do bb:paintRect(x, top + i * lane_h - math.floor(line / 2), w, line, i == 1 and UI.WHITE or UI.INK3) end
    bb:paintRect(x0, top, line, lane_h * 2, UI.WHITE)                 -- start line
    cheq(bb, pole_x, top, finish_w, lane_h * 2, math.max(3, math.floor(finish_w / 2)))
    label(bb, "1", 9, UI.INK3, x + s(10), top + lane_h - s(8))
    label(bb, "2", 9, UI.INK3, x + s(10), top + 2 * lane_h - s(8))
    for q = 1, 3 do   -- distance marks under the track
        label(bb, tostring(q * 25), 8, UI.INK3, x0 + math.floor(track_w * q / 4), y + h)
    end
    local fish = UI.sprite("fish", UI.spriteScaleH("fish", fh))
    fishAt(self, bb, pole_x + math.floor(finish_w / 2) - math.floor(fish:getSize().w / 2), top - s(3), fh)
    return { x0 = x0, track_w = track_w, pole_x = pole_x,
        rival_lane = top + lane_h - s(4), you_lane = top + 2 * lane_h - s(4) }
end

-- A trail: clouds and hills behind, grass tufts on the path, a signpost at
-- each quarter, the rival on a dotted path above, the flag and the fish.
function Scenes.trail(self, bb, x, y, w, h, s)
    local ground_h = math.max(s(6), math.floor(h * 0.07))
    local ground_y = y + h - ground_h
    local flag_w = math.max(s(10), math.floor(w * 0.03))
    local track_w = w - flag_w - s(4)
    -- hills: stepped, like the sprites
    local step = s(6)
    for _, hill in ipairs({ { 0.18, 0.22 }, { 0.55, 0.30 }, { 0.82, 0.18 } }) do
        local cx, hh = x + math.floor(w * hill[1]), math.floor(h * hill[2])
        for k = 0, hh, step do
            local half = math.floor((hh - k) * 1.6)
            bb:paintRect(cx - half, ground_y - k - step, half * 2, step, UI.INK4)
        end
    end
    -- clouds
    for _, c in ipairs({ { 0.12, 0.10 }, { 0.47, 0.04 }, { 0.70, 0.14 } }) do
        local cx, cy = x + math.floor(w * c[1]), y + math.floor(h * c[2])
        bb:paintRect(cx, cy + s(4), s(46), s(8), UI.INK4)
        bb:paintRect(cx + s(8), cy, s(24), s(6), UI.INK4)
    end
    bb:paintRect(x, ground_y, w, ground_h, UI.INK3)
    -- grass tufts
    for gx = x + s(9), x + track_w, s(37) do
        bb:paintRect(gx, ground_y - s(4), s(2), s(4), UI.INK3)
        bb:paintRect(gx + s(3), ground_y - s(6), s(2), s(6), UI.INK3)
        bb:paintRect(gx + s(6), ground_y - s(3), s(2), s(3), UI.INK3)
    end
    -- signposts
    for q = 1, 3 do
        local mx = x + math.floor(track_w * q / 4)
        bb:paintRect(mx, ground_y - s(22), math.max(2, s(3)), s(22), UI.INK3)
        local ts = UI.text(tostring(q * 25), "pix", 8, UI.BLACK)
        local tw, th = ts:getSize().w + s(8), ts:getSize().h + s(4)
        bb:paintRect(mx - math.floor(tw / 2) + 1, ground_y - s(22) - th, tw, th, UI.WHITE)
        bb:paintBorder(mx - math.floor(tw / 2) + 1, ground_y - s(22) - th, tw, th, math.max(1, s(2)), UI.INK3)
        ts:paintTo(bb, mx - math.floor(ts:getSize().w / 2) + 1, ground_y - s(22) - th + s(2))
        ts:free()
    end
    local pole_x = x + track_w
    local pole_top = y + s(4)
    bb:paintRect(pole_x, pole_top, math.max(2, s(3)), ground_y - pole_top, UI.BLACK)
    local cell = math.max(3, math.floor(flag_w / 3))
    cheq(bb, pole_x + s(3), pole_top, flag_w, cell * 3, cell)
    local fh = math.floor(self.pet_h * 0.4)
    local fish = UI.sprite("fish", UI.spriteScaleH("fish", fh))
    fishAt(self, bb, pole_x - fish:getSize().w - s(4), ground_y, fh)
    local rival_lane = y + math.floor((ground_y - y) * 0.5)
    for dx = 0, track_w, s(10) do bb:paintRect(x + dx, rival_lane + s(1), s(3), s(3), UI.INK3) end
    return { x0 = x, track_w = track_w, pole_x = pole_x, rival_lane = rival_lane, you_lane = ground_y }
end

-- Bookshelves: each runner walks along its own shelf of spines -- dark up
-- to where it's got to (read), outlined after (still to read) -- to a
-- bookend with the fish on it.
function Scenes.shelf(self, bb, x, y, w, h, s)
    local plank = math.max(s(5), math.floor(h * 0.05))
    local end_w = math.max(s(12), math.floor(w * 0.03))
    local pole_x = x + w - end_w
    local track_w = pole_x - x - s(4)
    local you_lane = y + h - plank
    local rival_lane = y + math.floor((h - plank) * 0.5)
    local function shelf(lane_y, pct, seed)
        bb:paintRect(x, lane_y, w, plank, UI.BLACK)
        local sx, i = x + s(2), seed
        local reached = x + math.floor(track_w * pct)
        local max_h = math.floor((lane_y - (lane_y == you_lane and rival_lane or y)) * 0.55)
        while sx < pole_x - s(4) do
            i = (i * 1103515245 + 12345) % 2147483648
            local sw = s(7) + (i % 7) * s(1)
            local sh = math.floor(max_h * (0.55 + (i % 9) / 20))
            sw = math.min(sw, pole_x - s(4) - sx)
            if sx + sw <= reached then
                bb:paintRect(sx, lane_y - sh, sw, sh, (i % 3 == 0) and UI.INK3 or UI.INK2)
            else
                bb:paintBorder(sx, lane_y - sh, sw, sh, math.max(1, s(1)), UI.INK3)
            end
            sx = sx + sw + s(1)
        end
        -- the bookend
        bb:paintRect(pole_x, lane_y - math.floor(max_h * 1.1), math.max(2, s(4)), math.floor(max_h * 1.1), UI.BLACK)
        bb:paintRect(pole_x, lane_y - s(4), end_w, s(4), UI.BLACK)
    end
    local grow = ease(self.t or 1)
    shelf(rival_lane, (self.rival_pct or 0) * grow, 7)
    shelf(you_lane, (self.you_pct or 0) * grow, 3)
    local fh = math.floor(self.pet_h * 0.4)
    local fish = UI.sprite("fish", UI.spriteScaleH("fish", fh))
    fishAt(self, bb, x + w - fish:getSize().w, you_lane - math.floor((you_lane - rival_lane) * 0.6), fh)
    return { x0 = x, track_w = track_w, pole_x = pole_x, rival_lane = rival_lane, you_lane = you_lane }
end

-- A scoreboard: two thick outlined bars, filled to where each runner is,
-- the percent inside the bar, the runner riding the end of its bar.
function Scenes.scoreboard(self, bb, x, y, w, h, s)
    local bar_h = math.max(s(16), math.floor(h * 0.13))
    local border = math.max(2, s(3))
    local flag_w = math.max(s(10), math.floor(w * 0.03))
    local pole_x = x + w - flag_w
    local track_w = pole_x - x - s(4)
    local you_lane = y + h - bar_h
    local rival_lane = y + math.floor((h - bar_h) * 0.5) - bar_h
    local function bar(lane_y, pct, who)
        local fill = math.floor((track_w - 2 * border) * math.max(0, math.min(1, pct)))
        bb:paintRect(x, lane_y, track_w, bar_h, UI.WHITE)
        bb:paintRect(x + border, lane_y + border, fill, bar_h - 2 * border, who == "you" and UI.BLACK or UI.INK2)
        bb:paintBorder(x, lane_y, track_w, bar_h, border, UI.BLACK)
        local pct_txt = string.format("%d%%", math.floor(pct * 100 + 0.5))
        local t = UI.text(pct_txt, "pix", 10, UI.BLACK)
        local ts = t:getSize()
        local inside = fill > ts.w + s(12)
        if inside then t:free(); t = UI.text(pct_txt, "pix", 10, UI.WHITE) end
        local tx = inside and (x + border + fill - ts.w - s(6)) or (x + border + fill + s(6))
        t:paintTo(bb, tx, lane_y + math.floor((bar_h - ts.h) / 2))
        t:free()
    end
    local grow = ease(self.t or 1)   -- (the bars run in with the runners)
    bar(rival_lane, (self.rival_pct or 0) * grow, "rival")
    bar(you_lane, (self.you_pct or 0) * grow, "you")
    cheq(bb, pole_x + s(2), rival_lane, flag_w - s(2), you_lane + bar_h - rival_lane, math.max(3, math.floor(flag_w / 3)))
    local fh = math.floor(self.pet_h * 0.4)
    local fish = UI.sprite("fish", UI.spriteScaleH("fish", fh))
    fishAt(self, bb, pole_x + math.floor(flag_w / 2) - math.floor(fish:getSize().w / 2), rival_lane - s(3), fh)
    -- (runners stand on top of their bars)
    return { x0 = x, track_w = track_w, pole_x = pole_x, rival_lane = rival_lane - s(1), you_lane = you_lane - s(1) }
end

Chase.STYLES = {
    { id = "field", label = "Field" },
    { id = "track", label = "Running track" },
    { id = "trail", label = "Trail" },
    { id = "shelf", label = "Bookshelves" },
    { id = "scoreboard", label = "Scoreboard" },
}

function Chase:paintTo(bb, x, y)
    local function s(n) return Screen:scaleBySize(n) end
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.width, self.height
    bb:paintRect(x, y, w, h, UI.WHITE)
    local scene = (Scenes[self.style or "field"] or Scenes.field)(self, bb, x, y, w, h, s)
    local pole_x, track_w, x0 = scene.pole_x, scene.track_w, scene.x0

    -- the runners: the rival a lane behind (higher up), you in front
    local t = ease(self.t or 1)
    local running = (self.t or 1) < 1
    -- one whole-number scale per animal, so frames of different heights
    -- don't make the pet pulse in size while it runs
    local you_a, rival_a = Race.animal(self.you), Race.animal(self.rival)
    self.k = self.k or {
        you = UI.spriteScaleH(you_a.still, math.floor(self.pet_h * you_a.scale)),
        rival = UI.spriteScaleH(rival_a.still, math.floor(self.pet_h * rival_a.scale * 0.9)),
    }
    local function place(name, pct, lane_y, key)
        local img = UI.sprite(name, self.k[key])
        local is = img:getSize()
        local px = x0 + math.floor(track_w * pct * t) - math.floor(is.w * 0.85)
        px = math.max(x, math.min(pole_x - is.w, px))
        img:paintTo(bb, px, lane_y - is.h)
        self.rects[key] = Geom:new{ x = px, y = lane_y - is.h, w = is.w, h = is.h }
        return px, is
    end
    local rival_lane, you_lane = scene.rival_lane, scene.you_lane
    local function pose(a)
        if running then return a.run[self.frame % #a.run + 1] end
        return a.still
    end
    local napping = self.napping and rival_a.nap_sprite
    place(napping and not running and rival_a.nap_sprite or pose(rival_a), self.rival_pct or 0, rival_lane, "rival")
    if napping and not running then
        local z = UI.text("z Z", "pix", 9)
        local r = self.rects.rival
        z:paintTo(bb, r.x + r.w - math.floor(z:getSize().w / 2), r.y - z:getSize().h)
        z:free()
    end
    place(pose(you_a), self.you_pct or 0, you_lane, "you")

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
    for _, who in ipairs({ "you", "rival", "fish" }) do
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
-- (A handful of fast e-ink frames; each costs a screen update, so the page
-- only runs it when a runner moved since it was last on screen.)
function Chase:runIn()
    if not self.animate then self.t = 1 return end
    local frames = 6
    self.t, self.frame = 0, 0
    local i = 0
    local function step()
        i = i + 1
        self.t = i / frames
        self.frame = i
        local last = i >= frames
        UIManager:setDirty(self.show_parent or self, last and "ui" or "fast", self.dimen)
        if not last then UIManager:scheduleIn(0.1, step) end
    end
    UIManager:scheduleIn(0.1, step)
end

return Chase
