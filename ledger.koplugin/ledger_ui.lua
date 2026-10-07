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

-- Everything a size bigger than KOReader's own defaults: the Ledger is read
-- at arm's length on e-ink.
UI.TEXT_SCALE = 1.15

function UI.face(kind, size)
    size = math.floor(size * UI.TEXT_SCALE + 0.5)
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
    -- (in night mode the sprites invert with everything else: kept "original"
    -- their transparent edges would show as white boxes)
    return ImageWidget:new{ image = bb, image_disposable = false, alpha = true, original_in_nightmode = false }
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

-- A pixel-font button: solid (main action) or outlined. With width, the
-- button is exactly that wide and the label centred, so stacked buttons
-- share both edges.
function UI.button(label, callback, outlined, size, width)
    local b = Screen:scaleBySize(2)
    local pad_h, pad_v = Screen:scaleBySize(10), Screen:scaleBySize(6)
    local text = UI.text(label:upper(), "pix", size or 11, outlined and UI.BLACK or UI.WHITE)
    local inner = text
    if width then
        local CenterContainer = require("ui/widget/container/centercontainer")
        inner = CenterContainer:new{ dimen = Geom:new{ w = math.max(text:getSize().w, width - 2 * b - 2 * pad_h),
            h = text:getSize().h }, text }
    end
    local frame = FrameContainer:new{
        bordersize = b,
        color = UI.BLACK,
        background = outlined and UI.WHITE or UI.BLACK,
        padding = 0, padding_left = pad_h, padding_right = pad_h,
        padding_top = pad_v, padding_bottom = pad_v,
        margin = 0,
        inner,
    }
    return UI.tappable(frame, callback)
end

-- How wide a button with this label would be (to give a stack one width).
function UI.buttonWidth(label, size)
    return UI.text(label:upper(), "pix", size or 11):getSize().w + 2 * Screen:scaleBySize(10) + 2 * Screen:scaleBySize(2)
end

-- The line at the top of every page: its name on the left, something on the
-- right, always the same height and the same gap under it, so the three
-- pages start at the same place.
function UI.header(width, left, right)
    local h = UI.text("A", "pix", 13):getSize().h
    if type(left) == "string" then left = UI.text(left, "pix", 11) end
    local line = UI.spread(width, left, right)
    table.insert(line, 1, VerticalSpan:new{ width = h })
    return VerticalGroup:new{ align = "left", line, VerticalSpan:new{ width = Screen:scaleBySize(12) } }
end

-- ---------------------------------------------------------------- KOReader's menu
-- A tap on the top strip of a Ledger page (or a swipe down from it) opens
-- KOReader's own menu, as it does everywhere else in KOReader. Buttons up
-- there still get their taps first: the page only sees taps nothing used.
-- A page made for one screen size asks the Ledger to make it again when the
-- size changes (see Ledger:refit).
function UI.refitOnResize(Page)
    function Page:onSetDimensions() if self.plugin then self.plugin:refitSoon() end end
    function Page:onScreenResize() if self.plugin then self.plugin:refitSoon() end end
end

function UI.addTopMenu(page)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local band = Geom:new{ x = 0, y = 0, w = W, h = math.floor(H / 10) }
    page.ges_events = page.ges_events or {}
    page.ges_events.TopMenuTap = { GestureRange:new{ ges = "tap", range = band } }
    page.ges_events.TopMenuSwipe = { GestureRange:new{ ges = "swipe", range = band } }
    page.onTopMenuTap = function(self)
        self.plugin:showKOMenu()
        return true
    end
    page.onTopMenuSwipe = function(self, _, ges)
        if ges and ges.direction == "south" then
            self.plugin:showKOMenu()
            return true
        end
    end
end

-- ---------------------------------------------------------------- tab bar
-- The three pages: Library, Currently reading (the main one, in the middle), Settings. Equal-width tabs across the
-- bottom; the current one is solid black.
UI.TABS = { { id = "library", label = "Library" }, { id = "reading", label = "Currently reading" }, { id = "settings", label = "Settings" } }

-- a tab's label, a size smaller if it doesn't fit (small screens)
local function tabLabel(label, max_w, on)
    local size = 11
    local t = UI.text(label:upper(), "pix", size, on and UI.WHITE or UI.BLACK)
    while t:getSize().w > max_w and size > 7 do
        t:free()
        size = size - 1
        t = UI.text(label:upper(), "pix", size, on and UI.WHITE or UI.BLACK)
    end
    return t
end

function UI.tabBar(width, active, on_select)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local b = Screen:scaleBySize(2)
    local h = Screen:scaleBySize(40)
    local n = #UI.TABS
    local gap = Screen:scaleBySize(6)
    local tab_w = math.floor((width - (n - 1) * gap) / n)
    local row = HorizontalGroup:new{}
    for i, tab in ipairs(UI.TABS) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        local on = tab.id == active
        local w = i < n and tab_w or width - (n - 1) * (tab_w + gap)
        local frame = FrameContainer:new{
            bordersize = b, color = UI.BLACK, background = on and UI.BLACK or UI.WHITE,
            padding = 0, margin = 0,
            CenterContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b },
                tabLabel(tab.label, w - 2 * b - Screen:scaleBySize(8), on) },
        }
        row[#row + 1] = UI.tappable(frame, function() if not on then on_select(tab.id) end end)
    end
    return row
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

-- ---------------------------------------------------------------- status bar
-- Text drawn hollow: an outline in black with a white fill, so it reads on
-- both the filled (black) and empty (white) part of a bar.
local HollowText = Widget:extend{ text = nil, face = nil }

function HollowText:getSize()
    local probe = TextWidget:new{ text = self.text, face = self.face, bold = true }
    local s = probe:getSize()
    probe:free()
    local o = math.max(1, Screen:scaleBySize(1))
    return Geom:new{ w = s.w + 2 * o, h = s.h + 2 * o }
end

function HollowText:paintTo(bb, x, y)
    local o = math.max(1, Screen:scaleBySize(1))
    local ink = TextWidget:new{ text = self.text, face = self.face, bold = true, fgcolor = UI.BLACK }
    for dx = -o, o do
        for dy = -o, o do
            if dx ~= 0 or dy ~= 0 then ink:paintTo(bb, x + o + dx, y + o + dy) end
        end
    end
    ink:free()
    local fill = TextWidget:new{ text = self.text, face = self.face, bold = true, fgcolor = UI.WHITE }
    fill:paintTo(bb, x + o, y + o)
    fill:free()
end

-- A thick status bar. style: "solid" (one bar) or "blocks" (ten segments);
-- label is drawn hollow, centred; outside_label puts it to the right instead.
local StatusBar = Widget:extend{ width = nil, height = nil, pct = 0, label = nil,
    style = "solid", outside_label = false }

function StatusBar:getSize() return Geom:new{ w = self.width, h = self.height } end

function StatusBar:paintTo(bb, x, y)
    local w, h = self.width, self.height
    local b = math.max(1, Screen:scaleBySize(2))
    local face = UI.face("bold", 9)
    local label_w = 0
    local plain
    if self.label and self.outside_label then
        plain = UI.text(self.label, "bold", 10)
        label_w = plain:getSize().w + Screen:scaleBySize(6)
    end
    local bw = w - label_w
    bb:paintRect(x, y, bw, h, UI.WHITE)
    local pct = math.max(0, math.min(1, self.pct or 0))
    if self.style == "blocks" then
        local n, gap = 10, math.max(1, Screen:scaleBySize(2))
        local cell = math.floor((bw - 2 * b - (n + 1) * gap) / n)
        local filled = math.floor(pct * n + 0.5)
        if pct > 0 and filled == 0 then filled = 1 end
        for i = 0, n - 1 do
            local cx = x + b + gap + i * (cell + gap)
            local color = i < filled and UI.BLACK or UI.INK4
            bb:paintRect(cx, y + b + gap, cell, h - 2 * (b + gap), color)
        end
    else
        local fill = math.floor((bw - 2 * b) * pct)
        if fill > 0 then bb:paintRect(x + b, y + b, fill, h - 2 * b, UI.BLACK) end
    end
    bb:paintBorder(x, y, bw, h, b, UI.BLACK)
    if plain then
        local ps = plain:getSize()
        plain:paintTo(bb, x + bw + Screen:scaleBySize(6), y + math.floor((h - ps.h) / 2))
        plain:free()
    elseif self.label then
        local t = HollowText:new{ text = self.label, face = face }
        local ts = t:getSize()
        t:paintTo(bb, x + math.floor((bw - ts.w) / 2), y + math.floor((h - ts.h) / 2))
    end
end

-- The pets on a bar. "rider": the pet stands on the bar's top edge at your
-- place (the dog at the start of a new book, the cat at the end of a finished
-- one). "lane": a slim race lane with a chequered end, the pet inside it and
-- the number beside it.
local PetBar = Widget:extend{ width = nil, bar_h = nil, pet_h = nil, pct = 0, label = nil,
    status = nil, mode = "rider" }

function PetBar:getSize()
    if self.mode == "lane" then return Geom:new{ w = self.width, h = self.pet_h + Screen:scaleBySize(6) } end
    return Geom:new{ w = self.width, h = self.pet_h + self.bar_h }
end

local function petFor(status)
    if status == "new" then return "dog_sit" end
    if status == "finished" then return "cat_sit" end
    return "cat_run2"
end

function PetBar:paintTo(bb, x, y)
    local function s(n) return Screen:scaleBySize(n) end
    local pct = math.max(0, math.min(1, self.pct or 0))
    local name = petFor(self.status)
    local pet = UI.sprite(name, UI.spriteScaleH(name, self.pet_h))
    local ps = pet:getSize()
    if self.mode == "lane" then
        local h = self.pet_h + s(6)
        local plain = UI.text(self.label, "bold", 10)
        local lw = plain:getSize().w + s(6)
        local lane_w = self.width - lw
        local b = math.max(1, s(2))
        local flag_w = math.max(4, math.floor(h / 2))
        local cell = math.max(2, math.floor(flag_w / 2))
        bb:paintRect(x, y, lane_w, h, UI.WHITE)
        -- finished track behind the runner
        local track_w = lane_w - flag_w
        local dash = s(4)
        for dx = 0, track_w, dash * 2 do
            bb:paintRect(x + dx, y + h - b - s(2), math.min(dash, track_w - dx), math.max(1, s(1)), UI.INK3)
        end
        for fy = 0, h - 1, cell do
            for fx = 0, flag_w - 1, cell do
                local black = (math.floor(fy / cell) + math.floor(fx / cell)) % 2 == 0
                bb:paintRect(x + track_w + fx, y + fy, math.min(cell, flag_w - fx), math.min(cell, h - fy),
                    black and UI.BLACK or UI.WHITE)
            end
        end
        bb:paintBorder(x, y, lane_w, h, b, UI.BLACK)
        local px = x + b + math.floor((track_w - ps.w - 2 * b) * pct)
        pet:paintTo(bb, px, y + h - b - ps.h - s(1))
        local pls = plain:getSize()
        plain:paintTo(bb, x + lane_w + s(6), y + math.floor((h - pls.h) / 2))
        plain:free()
        return
    end
    -- rider: the bar, then the pet standing on its top edge
    local bar = StatusBar:new{ width = self.width, height = self.bar_h, pct = pct, label = self.label }
    bar:paintTo(bb, x, y + self.pet_h)
    local px
    if self.status == "new" then px = x
    elseif self.status == "finished" then px = x + self.width - ps.w
    else px = x + math.floor(self.width * pct) - math.floor(ps.w * 0.8) end
    px = math.max(x, math.min(x + self.width - ps.w, px))
    pet:paintTo(bb, px, y + self.pet_h - ps.h + s(1))
end

function UI.petBar(width, bar_h, pet_h, pct, label, status, mode)
    return PetBar:new{ width = width, bar_h = bar_h, pet_h = pet_h, pct = pct, label = label,
        status = status, mode = mode or "rider" }
end

function UI.statusBar(width, height, pct, label, style, outside_label)
    return StatusBar:new{ width = width, height = height, pct = pct, label = label,
        style = style or "solid", outside_label = outside_label }
end

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
-- Covers, shrunk once to the size they're shown at and kept: KOReader's
-- cover cache holds them at up to screen size, and shrinking a full-size
-- cover on every draw is most of what makes a page slow to appear on a
-- Kindle. The last 40 (a few MB) are kept, oldest out first.
local cover_cache, cover_order = {}, {}
local COVER_CACHE_MAX = 40

local function cachedCover(key)
    return cover_cache[key]
end

local function keepCover(key, bb)
    if cover_cache[key] then cover_cache[key]:free() end
    cover_cache[key] = bb
    cover_order[#cover_order + 1] = key
    while #cover_order > COVER_CACHE_MAX do
        local old = table.remove(cover_order, 1)
        if cover_cache[old] and old ~= key then cover_cache[old]:free(); cover_cache[old] = nil end
    end
end

-- The cover's size inside a w x h frame: filling it when the shapes are
-- within 10% (invisible on a book cover), letterboxed otherwise.
local function fitSize(sw, sh, w, h)
    local sx, sy = w / sw, h / sh
    if math.abs(sx / sy - 1) <= 0.10 then return w, h end
    local k = math.min(sx, sy)
    return math.max(1, math.floor(sw * k + 0.5)), math.max(1, math.floor(sh * k + 0.5))
end

local function coverFrame(img, w, h)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local b = Screen:scaleBySize(2)
    return FrameContainer:new{ bordersize = b, padding = 0, margin = 0, background = UI.WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, img } }
end

function UI.cover(rec, w, h)
    local b = Screen:scaleBySize(2)
    local key = (rec.cover_file or rec.file or "") .. "@" .. w .. "x" .. h
    local hit = cachedCover(key)
    if hit then
        return coverFrame(ImageWidget:new{ image = hit, image_disposable = false }, w, h), true
    end
    -- a cover image file (trending books, which aren't on the device)
    if rec.cover_file and lfs.attributes(rec.cover_file, "mode") == "file" then
        local b = Screen:scaleBySize(2)
        local CenterContainer = require("ui/widget/container/centercontainer")
        local img = ImageWidget:new{ file = rec.cover_file, width = w - 2 * b, height = h - 2 * b,
            stretch_limit_percentage = 10 }
        return FrameContainer:new{ bordersize = b, padding = 0, margin = 0, background = UI.WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, img } }, true
    end
    local bim_ok, BIM = pcall(require, "bookinfomanager")
    if bim_ok and BIM and rec.file then
        local ok, info = pcall(BIM.getBookInfo, BIM, rec.file, true)
        if ok and info and info.cover_bb and info.has_cover then
            -- fill the frame (book covers are all roughly 2:3, so a stretch
            -- of up to 10% is invisible); letterbox anything stranger
            -- shrink once, keep it; the frame is always exactly w x h, even
            -- when an oddly shaped cover is letterboxed inside it
            local src = info.cover_bb
            local tw, th = fitSize(src:getWidth(), src:getHeight(), w - 2 * b, h - 2 * b)
            local scaled = RenderImage:scaleBlitBuffer(src, tw, th, true)
            keepCover(key, scaled)
            return coverFrame(ImageWidget:new{ image = scaled, image_disposable = false }, w, h), true
        end
    end
    -- (FrameContainer's width/height don't take part in layout, so the
    -- placeholder's size comes from a CenterContainer of exactly w x h)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local b = Screen:scaleBySize(2)
    -- the title in the biggest size (up to 12) where no word has to break
    local inner_w = w - Screen:scaleBySize(20)
    local size = 12
    while size > 7 do
        local widest = 0
        for word in (rec.title or "?"):gmatch("%S+") do
            local t = UI.text(word, "bold", size)
            widest = math.max(widest, t:getSize().w)
            t:free()
        end
        if widest <= inner_w then break end
        size = size - 1
    end
    local title = UI.para(rec.title or "?", "bold", size, inner_w)
    return FrameContainer:new{
        bordersize = b, color = UI.BLACK, background = UI.WHITE, padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, title },
    }, false
end

return UI
