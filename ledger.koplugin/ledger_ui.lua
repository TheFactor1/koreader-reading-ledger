--[[
Drawing pieces for the Reading Ledger: fonts, pixel sprites, and the custom
widgets the screens are built from (the pet's room, the cat-and-dog race,
the fish goal row, tappable rows and buttons).

Everything is drawn for e-ink: pure black, white and a few greys, no
anti-aliased scaling of the pixel art (nearest-neighbour only), and nothing
that animates.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FontList = require("fontlist")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Screen = Device.screen

local UI = {}

UI.BLACK = Blitbuffer.COLOR_BLACK
UI.WHITE = Blitbuffer.COLOR_WHITE
UI.INK2 = Blitbuffer.gray(0.70)  -- secondary text
UI.INK3 = Blitbuffer.gray(0.45)  -- rules, floor
UI.INK4 = Blitbuffer.gray(0.18)  -- faint stripes

-- ---------------------------------------------------------------- fonts
local plugin_dir

function UI.setPluginDir(dir)
    if dir:sub(1, 1) ~= "/" then dir = lfs.currentdir() .. "/" .. dir end
    plugin_dir = dir
end

-- Font:getFace() looks in KOReader's own fonts folder first. A path that
-- climbs out of it with "../" resolves to the plugin's bundled file, wherever
-- KOReader and the plugin live (Kindle, desktop, a KO_HOME sandbox).
local FACES = {
    pix = { "Silkscreen-Regular.ttf", "DroidSansMono.ttf" },
    body = { "AtkinsonHyperlegible-Regular.ttf", "NotoSans-Regular.ttf" },
    bold = { "AtkinsonHyperlegible-Bold.ttf", "NotoSans-Bold.ttf" },
}
local face_cache = {}

function UI.face(kind, size)
    local key = kind .. size
    if face_cache[key] then return face_cache[key] end
    local spec = FACES[kind] or FACES.body
    local face
    if plugin_dir then
        local climb = string.rep("../", 12)
        local rel = climb .. (plugin_dir .. "/fonts/" .. spec[1]):gsub("^/", "")
        if lfs.attributes(plugin_dir .. "/fonts/" .. spec[1], "mode") == "file" then
            face = Font:getFace(rel, size)
        end
        if not face then
            logger.warn("ledger: bundled font", spec[1], "not loaded from", FontList.fontdir)
        end
    end
    face = face or Font:getFace(spec[2], size)
    face_cache[key] = face
    return face
end

-- ---------------------------------------------------------------- sprites
local sprite_cache = {}

-- A sprite scaled by a whole number (k) so every pixel stays a crisp square.
function UI.sprite(name, k)
    k = math.max(1, math.floor(k or 1))
    local key = name .. "@" .. k
    local bb = sprite_cache[key]
    if not bb then
        local path = plugin_dir .. "/sprites/" .. name .. ".png"
        local src = RenderImage:renderImageFile(path, false)
        if not src then
            logger.warn("ledger: missing sprite", path)
            return nil
        end
        bb = k > 1 and src:scale(src:getWidth() * k, src:getHeight() * k) or src
        if k > 1 then src:free() end
        sprite_cache[key] = bb
    end
    return ImageWidget:new{ image = bb, image_disposable = false, alpha = true }
end

-- The whole-number scale that makes a sprite about `target_w` pixels wide.
function UI.spriteScale(name, target_w)
    local probe = UI.sprite(name, 1)
    if not probe then return 1 end
    local w = probe:getSize().w
    probe:free()
    return math.max(1, math.floor(target_w / w))
end

-- The whole-number scale that makes a sprite about `target_h` pixels tall.
function UI.spriteScaleH(name, target_h)
    local probe = UI.sprite(name, 1)
    if not probe then return 1 end
    local h = probe:getSize().h
    probe:free()
    return math.max(1, math.floor(target_h / h))
end

function UI.freeSprites()
    for _, bb in pairs(sprite_cache) do bb:free() end
    sprite_cache = {}
end

-- ---------------------------------------------------------------- text
function UI.text(str, kind, size, color, max_width)
    return TextWidget:new{
        text = str, face = UI.face(kind or "body", size or 14),
        fgcolor = color or UI.BLACK, max_width = max_width,
    }
end

function UI.para(str, kind, size, width, color)
    return TextBoxWidget:new{
        text = str, face = UI.face(kind or "body", size or 14),
        width = width, fgcolor = color or UI.BLACK,
    }
end

function UI.rule(width, thick, color)
    return Widget:new{
        dimen = Geom:new{ w = width, h = thick or Screen:scaleBySize(2) },
        paintTo = function(self, bb, x, y)
            bb:paintRect(x, y, self.dimen.w, self.dimen.h, color or UI.BLACK)
        end,
    }
end

function UI.vspace(h) return VerticalSpan:new{ width = h } end
function UI.hspace(w) return HorizontalSpan:new{ width = w } end

-- Left and right items on one line, pushed apart.
function UI.spread(width, left, right)
    local lw, rw = left:getSize().w, right and right:getSize().w or 0
    return HorizontalGroup:new{
        align = "center",
        left,
        HorizontalSpan:new{ width = math.max(0, width - lw - rw) },
        right,
    }
end

-- ---------------------------------------------------------------- tapping
local Tappable = InputContainer:extend{ callback = nil, hold_callback = nil }

function Tappable:init()
    self.dimen = Geom:new{ w = self[1]:getSize().w, h = self[1]:getSize().h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        Hold = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Tappable:onTap()
    if self.callback then self.callback() end
    return true
end

function Tappable:onHold()
    if self.hold_callback then self.hold_callback() return true end
    if self.callback then self.callback() end
    return true
end

function UI.tappable(widget, callback, hold_callback)
    return Tappable:new{ widget, callback = callback, hold_callback = hold_callback }
end

-- A pixel-font button: solid (main action) or outlined.
function UI.button(label, callback, outlined, size)
    local pad_h, pad_v = Screen:scaleBySize(10), Screen:scaleBySize(6)
    local frame = FrameContainer:new{
        bordersize = Screen:scaleBySize(2),
        color = UI.BLACK,
        background = outlined and UI.WHITE or UI.BLACK,
        padding = 0, padding_left = pad_h, padding_right = pad_h,
        padding_top = pad_v, padding_bottom = pad_v,
        margin = 0,
        UI.text(label:upper(), "pix", size or 11, outlined and UI.BLACK or UI.WHITE),
    }
    return UI.tappable(frame, callback)
end

-- ---------------------------------------------------------------- the room
-- A striped wall, a floor, a pet sprite and its speech bubble.
local Room = Widget:extend{ width = nil, height = nil, sprite = nil, bubble = nil }

function Room:getSize() return Geom:new{ w = self.width, h = self.height } end

function Room:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local w, h = self.width, self.height
    local border = Screen:scaleBySize(2)
    local floor_h = math.floor(h * 0.12)
    local stripe = math.max(4, math.floor(w / 18))
    bb:paintRect(x, y, w, h, UI.WHITE)
    for sx = 0, w, stripe * 2 do
        bb:paintRect(x + sx + stripe, y, math.min(stripe, w - sx - stripe), h - floor_h, UI.INK4)
    end
    bb:paintRect(x, y + h - floor_h, w, floor_h, UI.INK3)
    bb:paintBorder(x, y, w, h, border, UI.BLACK)
    local pad = Screen:scaleBySize(10)
    if self.sprite then
        local s = self.sprite:getSize()
        self.sprite:paintTo(bb, x + pad, y + h - floor_h - s.h)
    end
    if self.bubble then
        local s = self.bubble:getSize()
        local bx = x + w - pad - s.w
        local by = y + math.max(pad, math.floor((h - floor_h - s.h) / 2) - math.floor(pad / 2))
        self.bubble:paintTo(bb, bx, by)
    end
end

function UI.room(width, height, sprite_name, sprite_k, name, message)
    local sprite = sprite_name and UI.sprite(sprite_name, sprite_k)
    local sw = sprite and sprite:getSize().w or 0
    local inner = math.max(Screen:scaleBySize(80), width - sw - Screen:scaleBySize(40))
    local text_w = inner - Screen:scaleBySize(20)
    local bubble = FrameContainer:new{
        bordersize = Screen:scaleBySize(2), color = UI.BLACK, background = UI.WHITE,
        padding = Screen:scaleBySize(8), margin = 0,
        VerticalGroup:new{
            align = "left",
            UI.text(name:upper(), "pix", 10),
            UI.vspace(Screen:scaleBySize(2)),
            UI.para(message, "body", 12, text_w),
        },
    }
    return Room:new{ width = width, height = height, sprite = sprite, bubble = bubble }
end

-- ---------------------------------------------------------------- the race
-- Two lanes: the cat (this Kindle) and the dog (Readest), a flag at the end.
local Race = Widget:extend{ width = nil, lane_h = nil, cat = nil, dog = nil,
    cat_pct = nil, dog_pct = nil }

function Race:getSize() return Geom:new{ w = self.width, h = self.lane_h * 2 } end

local function pctLabel(p) return tostring(math.floor(p * 100 + 0.5)) .. "%" end

function Race:paintTo(bb, x, y)
    local w, h = self.width, self.lane_h * 2
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    local border = Screen:scaleBySize(2)
    local flag_w = math.max(6, math.floor(w * 0.035))
    local cell = math.max(3, math.floor(flag_w / 2))
    local track_w = w - flag_w
    bb:paintRect(x, y, w, h, UI.WHITE)
    -- quarter marks
    for q = 1, 3 do
        bb:paintRect(x + math.floor(track_w * q / 4), y, math.floor(border / 2) + 1, h, UI.INK3)
    end
    -- dashed lane divider
    local dash = Screen:scaleBySize(6)
    for dx = 0, track_w, dash * 2 do
        bb:paintRect(x + dx, y + self.lane_h, math.min(dash, track_w - dx), math.max(1, math.floor(border / 2)), UI.INK3)
    end
    -- chequered flag
    for fy = 0, h - 1, cell do
        for fx = 0, flag_w - 1, cell do
            local black = (math.floor(fy / cell) + math.floor(fx / cell)) % 2 == 0
            bb:paintRect(x + track_w + fx, y + fy, math.min(cell, flag_w - fx), math.min(cell, h - fy),
                black and UI.BLACK or UI.WHITE)
        end
    end
    bb:paintBorder(x, y, w, h, border, UI.BLACK)

    local function runner(img, pct, lane, no_label)
        if not img then return end
        local s = img:getSize()
        local px = x + math.floor(track_w * math.max(0, math.min(1, pct or 0)))
        -- the runner's nose sits on its position; never off the track's start
        local rx = math.max(x + border, px - math.floor(s.w * 0.85))
        local ry = y + lane * self.lane_h + self.lane_h - s.h - Screen:scaleBySize(3)
        img:paintTo(bb, rx, ry)
        if pct and not no_label then
            local label = UI.text(pctLabel(pct), "pix", 10)
            local ls = label:getSize()
            local lx = math.min(rx + s.w + Screen:scaleBySize(3), x + track_w - ls.w - Screen:scaleBySize(2))
            local ly = y + lane * self.lane_h + Screen:scaleBySize(3)
            bb:paintRect(lx - 2, ly, ls.w + 4, ls.h, UI.WHITE)
            label:paintTo(bb, lx, ly)
            label:free()
        end
    end
    runner(self.cat, self.cat_pct or 0, 0)
    -- a dog that isn't racing sits at the start line, unlabelled
    runner(self.dog, self.dog_pct or 0, 1, self.dog_sitting)
end

-- frame picks a different running pose so the two books on screen differ
function UI.race(width, cat_pct, dog_pct, frame)
    local target = math.floor(width * 0.13)
    local cat_name = "cat_run" .. ((frame or 2) % 6)
    local dog_name = dog_pct and ("dog_run" .. ((frame or 2) % 6)) or nil
    local k = UI.spriteScale("cat_run2", target)
    local cat = UI.sprite(cat_name, k)
    local dog = dog_name and UI.sprite(dog_name, UI.spriteScale("dog_run2", math.floor(target * 0.82)))
    local lane_h = (cat and cat:getSize().h or Screen:scaleBySize(30)) + Screen:scaleBySize(10)
    if not dog_pct then
        -- Readest absent: the dog sits at the start line, not racing
        dog = UI.sprite("dog_sit", UI.spriteScale("dog_sit", math.floor(target * 0.6)))
    end
    return Race:new{ width = width, lane_h = lane_h, cat = cat, dog = dog,
        cat_pct = cat_pct, dog_pct = dog_pct, dog_sitting = not dog_pct }
end

-- ---------------------------------------------------------------- mini track
-- A thin line under a cover: grey track, black up to how far you've read.
local MiniTrack = Widget:extend{ width = nil, pct = 0 }

function MiniTrack:getSize() return Geom:new{ w = self.width, h = Screen:scaleBySize(4) } end

function MiniTrack:paintTo(bb, x, y)
    local h = Screen:scaleBySize(4)
    local line = math.max(1, Screen:scaleBySize(1))
    bb:paintRect(x, y + math.floor((h - line) / 2), self.width, line, UI.INK3)
    local fill = math.floor(self.width * math.max(0, math.min(1, self.pct or 0)))
    if fill > 0 then bb:paintRect(x, y, fill, h, UI.BLACK) end
end

function UI.miniTrack(width, pct) return MiniTrack:new{ width = width, pct = pct } end

-- ---------------------------------------------------------------- goal fish
local FishRow = Widget:extend{ fish = nil, total = 12, done = 0, gap = 0 }

function FishRow:getSize()
    local s = self.fish:getSize()
    return Geom:new{ w = self.total * s.w + (self.total - 1) * self.gap, h = s.h }
end

function FishRow:paintTo(bb, x, y)
    local s = self.fish:getSize()
    for i = 1, self.total do
        local fx = x + (i - 1) * (s.w + self.gap)
        self.fish:paintTo(bb, fx, y)
        if i > self.done then
            -- unearned fish: knocked back to a faint grey
            bb:lightenRect(fx, y, s.w, s.h, 0.7)
        end
    end
end

function UI.fishRow(total, done, fish_w)
    local fish = UI.sprite("fish", UI.spriteScale("fish", fish_w))
    return FishRow:new{ fish = fish, total = total, done = math.min(done, total),
        gap = math.floor(fish:getSize().w * 0.25) }
end

-- ---------------------------------------------------------------- covers
-- A book cover from KOReader's cover cache, fitted to w x h; or a drawn
-- stand-in with the title when there is none (yet).
function UI.cover(rec, w, h)
    local bim_ok, BIM = pcall(require, "bookinfomanager")
    if bim_ok and BIM and rec.file then
        local ok, info = pcall(BIM.getBookInfo, BIM, rec.file, true)
        if ok and info and info.cover_bb and info.has_cover then
            -- fill the frame (book covers are all roughly 2:3, so a stretch
            -- of up to 10% is invisible); letterbox anything stranger
            local img = ImageWidget:new{ image = info.cover_bb, image_disposable = true,
                width = w - 2 * Screen:scaleBySize(2), height = h - 2 * Screen:scaleBySize(2),
                stretch_limit_percentage = 10 }
            return FrameContainer:new{ bordersize = Screen:scaleBySize(2), padding = 0, margin = 0, img }, true
        end
    end
    -- (FrameContainer's width/height don't take part in layout, so the
    -- placeholder's size comes from a CenterContainer of exactly w x h)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local b = Screen:scaleBySize(2)
    local title = UI.para(rec.title or "?", "bold", 12, w - Screen:scaleBySize(20))
    return FrameContainer:new{
        bordersize = b, color = UI.BLACK, background = UI.WHITE, padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, title },
    }, false
end

return UI
