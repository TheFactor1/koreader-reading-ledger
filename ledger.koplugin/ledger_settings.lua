--[[
The Settings page: one list, each row a setting and its current value.
Tap a row to change it (names and keys open an input box, switches flip).
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local UIManager = require("ui/uimanager")
local UI = require("ledger_ui")

local Screen = Device.screen

local Settings = InputContainer:extend{
    name = "ledger_settings",
    covers_fullscreen = true,
    plugin = nil,
}

function Settings:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self[1] = self:build()
end

function Settings:onClose()
    self.plugin:closeAll()
    return true
end

function Settings:update()
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

-- One row: an optional pet icon, the name and a hint, the value on the right.
local function row(cw, icon, label, hint, value, callback)
    local function s(n) return Screen:scaleBySize(n) end
    local left = HorizontalGroup:new{ align = "center" }
    local icon_w = s(30)
    if icon then
        -- icons sit on the left margin, like everything else on the page
        local LeftContainer = require("ui/widget/container/leftcontainer")
        left[#left + 1] = LeftContainer:new{ dimen = Geom:new{ w = icon_w, h = s(26) },
            UI.sprite(icon, math.min(UI.spriteScaleH(icon, icon == "fish" and s(11) or s(20)), UI.spriteScale(icon, icon_w))) }
    else
        left[#left + 1] = UI.hspace(icon_w)
    end
    left[#left + 1] = UI.hspace(s(10))
    local text_w = math.floor(cw * 0.6)
    local labels = VerticalGroup:new{ align = "left", UI.text(label, "bold", 13, UI.BLACK, text_w) }
    if hint then labels[#labels + 1] = UI.text(hint, "body", 10, UI.INK2, text_w) end
    left[#left + 1] = labels
    -- values in the pixel font; a plain arrow for rows that open something
    local val = value == "›" and UI.text("›", "bold", 16)
        or UI.text(value or "", "pix", 10, UI.BLACK, cw - left:getSize().w - s(20))
    local line = VerticalGroup:new{ align = "left",
        UI.vspace(s(10)), UI.spread(cw, left, val), UI.vspace(s(10)), UI.rule(cw, s(1), UI.INK3) }
    return callback and UI.tappable(line, callback) or line
end

function Settings:build()
    local function s(n) return Screen:scaleBySize(n) end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m
    local p = self.plugin
    local st = p:sourceStatus()

    local main = VerticalGroup:new{ align = "left" }
    local function add(w) main[#main + 1] = w end
    add(UI.header(cw, "SETTINGS", UI.text("READING LEDGER", "pix", 11, UI.INK2)))
    add(UI.rule(cw, s(1), UI.INK3))

    local Race = require("ledger_race")
    local you, rival = Race.animal(p:runner()), Race.animal(p:rival())
    add(row(cw, you.still, "You run as", "Tap to pick an animal or rename it",
        (you.label .. " · " .. p:petName(you.id)):upper(), function() p:chooseAnimal("runner") end))
    add(row(cw, rival.still, "Your rival", rival.hint,
        (rival.label .. " · " .. p:petName(rival.id)):upper(), function() p:chooseAnimal("rival") end))
    add(row(cw, nil, string.format("What %s has learned", p:petName(rival.id)), "Your reading habits, and how it's tuned",
        "›", function() p:showHabits() end))
    add(row(cw, "fish", "Hardcover", st.hardcover_hint, st.hardcover, function() p:editHardcoverKey() end))
    add(row(cw, nil, "Readest", "Your place there counts too", st.readest))
    add(row(cw, nil, "Bookbridge", "Requests, new arrivals, search", st.bookbridge))
    add(row(cw, nil, "Animations", "The runners sprint in when the page opens",
        p:animationsOn() and "ON" or "OFF", function() p:toggleAnimations() end))
    add(row(cw, nil, "Refresh now", "Hardcover, trending and requests", "›", function() p:refreshRemote(true) end))
    add(row(cw, nil, "About and credits", "Sprites, fonts, who made this", "›", function() p:showAbout() end))

    local foot = UI.tabBar(cw, "settings", function(id) p:showTab(id) end)
    local used = main:getSize().h + foot:getSize().h + 2 * m
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0, padding = m,
        VerticalGroup:new{ align = "left", main, UI.vspace(math.max(0, H - used)), foot },
    }
end

return Settings
