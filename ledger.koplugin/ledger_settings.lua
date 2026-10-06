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
    UI.addTopMenu(self)
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
local function row(cw, icon, label, hint, value, callback, pad)
    local function s(n) return Screen:scaleBySize(n) end
    pad = pad or s(10)
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
        UI.vspace(pad), UI.spread(cw, left, val), UI.vspace(pad), UI.rule(cw, s(1), UI.INK3) }
    return callback and UI.tappable(line, callback) or line
end

-- The first that fits wins, labels kept as long as possible (the groups
-- are the point): 1 roomy with group labels; 2 rows closer; 3 rows
-- packed; 4 packed, a slim header and labels with no space around them;
-- 5 no labels (a very small screen).
function Settings:build(level)
    level = level or 1
    local labels = level <= 4
    local function s(n) return Screen:scaleBySize(n) end
    -- (rows are spaced out, or packed closer when they wouldn't all fit)
    local pad = (level >= 3 and s(3)) or (level == 2 and s(5)) or s(10)
    local row = function(...)
        local args = { ... }
        args[7] = pad
        return row(unpack(args, 1, 7))
    end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m
    local p = self.plugin
    local st = p:sourceStatus()

    local main = VerticalGroup:new{ align = "left" }
    local function add(w) main[#main + 1] = w end
    if level >= 4 then
        -- (a slim header: the title line without the band above and below it)
        add(UI.spread(cw, UI.text("SETTINGS", "pix", 11), UI.text("READING LEDGER", "pix", 11, UI.INK2)))
        add(UI.vspace(s(4)))
    else
        add(UI.header(cw, "SETTINGS", UI.text("READING LEDGER", "pix", 11, UI.INK2)))
    end
    if not labels then add(UI.rule(cw, s(1), UI.INK3)) end

    -- three groups, each under a small label: the race (yours to shape),
    -- your accounts and where books come from, and the Ledger itself.
    -- (the labels go when the page has no room for them)
    local function group(label)
        if not labels then return end
        local above = (level == 1 and s(14)) or (level == 2 and s(6)) or (level == 3 and s(2)) or 0
        local below = (level == 1 and s(4)) or (level == 2 and s(2)) or 0
        add(UI.vspace(above))
        add(UI.text(label, "pix", 9, UI.INK2))
        if below > 0 then add(UI.vspace(below)) end
        add(UI.rule(cw, s(1), UI.INK3))
    end

    group("THE RACE")
    local Race = require("ledger_race")
    local you, rival = Race.animal(p:runner()), Race.animal(p:rival())
    add(row(cw, you.still, "You run as", "Tap to pick an animal or rename it",
        (you.label .. " · " .. p:petName(you.id)):upper(), function() p:chooseAnimal("runner") end))
    add(row(cw, rival.still, "Your rival", rival.hint,
        (rival.label .. " · " .. p:petName(rival.id)):upper(), function() p:chooseAnimal("rival") end))
    add(row(cw, nil, string.format("What %s has learned", p:petName(rival.id)), "Your reading habits, and how it's tuned",
        "›", function() p:showHabits() end))
    local Chase = require("ledger_chase")
    local look = "FIELD"
    for _, sty in ipairs(Chase.STYLES) do if sty.id == p:raceStyle() then look = sty.label:upper() end end
    add(row(cw, nil, "Race look", "Field, running track, trail, bookshelves, scoreboard", look,
        function() p:chooseRaceStyle() end))
    add(row(cw, nil, "Animations", "The runners sprint in when the page opens",
        p:animationsOn() and "ON" or "OFF", function() p:toggleAnimations() end))

    group("ACCOUNTS AND BOOKS")
    add(row(cw, nil, "Readest", st.readest_hint, st.readest, function()
        local bb = p:bookbridge()
        if bb and bb.readestNext then bb:readestNext() end
    end))
    add(row(cw, "fish", "Hardcover", st.hardcover_hint, st.hardcover, function() p:editHardcoverKey() end))
    -- where books come from: one row, one dialog with Z-Library, Anna's
    -- Archive and Bookbridge itself (the page has no room for three)
    do
        local parts = {}
        if st.zlibrary then parts[#parts + 1] = "Z-Library " .. st.zlibrary:lower() end
        if st.annas then parts[#parts + 1] = "Anna's " .. st.annas:lower() end
        local bb = p:bookbridge()
        if bb and bb.server_url and bb.server_url ~= "" then parts[#parts + 1] = "server connected"
        elseif st.bookbridge == "NOT SET UP" then parts[#parts + 1] = "tap to set up"
        elseif st.bookbridge == "NOT INSTALLED" then parts = { "needs the Bookbridge plugin" } end
        local ready = 0
        if st.zlibrary == "SIGNED IN" then ready = ready + 1 end
        if st.annas and st.annas ~= "NO KEY" and st.annas ~= "KEY REFUSED" then ready = ready + 1 end
        local value = st.bookbridge == "NOT INSTALLED" and "NOT INSTALLED"
            or (ready > 0 and string.format("%d SOURCE%s", ready, ready == 1 and "" or "S") or st.bookbridge)
        add(row(cw, nil, "Books", table.concat(parts, " · "), value, function() p:showBooksSetup() end))
    end

    group("THE LEDGER")
    add(row(cw, nil, "Open on start", "When KOReader starts and when you close a book",
        p:homeOn() and "ON" or "OFF", function() p:toggleHome() end))
    -- (refreshing is automatic; the button for doing it now is in here)
    add(row(cw, nil, "About and updates", "Version, check for updates, refresh, credits", "›", function() p:showAbout() end))

    local foot = UI.tabBar(cw, "settings", function(id) p:showTab(id) end)
    local used = main:getSize().h + foot:getSize().h + 2 * m
    -- (kept for a look from the inspector: what each level needed)
    self.fit = self.fit or {}; self.fit[level] = used; self.fit.H = H
    if used > H and level < 5 then return self:build(level + 1) end
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0, padding = m,
        VerticalGroup:new{ align = "left", main, UI.vspace(math.max(0, H - used)), foot },
    }
end

return Settings
