--[[
The first time the Ledger opens: four short steps, any of them skippable.

  1. Your runner     -- pick an animal (and its name stays editable later)
  2. Your rival      -- pick one, each with how hard it is
  3. Your setup      -- what's on and what isn't: reading statistics (the
                        rival learns from them), Readest, Bookbridge,
                        Hardcover; with a button where something can be
                        fixed from here
  4. Home screen     -- open the Ledger when KOReader starts and when you
                        close a book?

Finishing (or skipping) marks the Ledger as set up; Settings has every one
of these again.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local UIManager = require("ui/uimanager")
local Race = require("ledger_race")
local UI = require("ledger_ui")

local Screen = Device.screen

local Onboard = InputContainer:extend{
    name = "ledger_onboard",
    covers_fullscreen = true,
    plugin = nil,
    step = 1,
}

local STEPS = 4

function Onboard:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self[1] = self:build()
end

function Onboard:onClose()
    self:finish()
    return true
end

function Onboard:update()
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

function Onboard:go(step)
    if step > STEPS then return self:finish() end
    self.step = math.max(1, step)
    self:update()
end

function Onboard:finish()
    local p = self.plugin
    p.settings:saveSetting("onboarded", true)
    p.settings:flush()
    UIManager:close(self)
    p:show()
end

-- One animal to pick: its sprite, name and a line; a thick frame when chosen.
local function animalTile(a, name, line, w, chosen, on_tap, body_h)
    local function s(n) return Screen:scaleBySize(n) end
    local CenterContainer = require("ui/widget/container/centercontainer")
    local pet_h = s(34)
    local pet = UI.sprite(a.still, math.min(UI.spriteScaleH(a.still, pet_h), UI.spriteScale(a.still, w * 0.6)))
    -- the chosen one has a thicker frame and that much less padding, so
    -- every tile is the same size
    local border, pad = s(chosen and 4 or 2), s(8) + s(chosen and 0 or 2)
    local inner_w = w - 2 * border - 2 * pad
    local body = VerticalGroup:new{ align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = pet_h + s(6) }, pet },
        UI.vspace(s(6)),
        UI.text(a.label:upper(), "pix", 10),
        UI.vspace(s(2)),
        UI.text(name, "bold", 11, UI.BLACK, inner_w),
    }
    if line then
        body[#body + 1] = UI.vspace(s(4))
        body[#body + 1] = UI.para(line, "body", 9, inner_w, UI.INK2)
    end
    local frame = FrameContainer:new{
        bordersize = border, color = UI.BLACK, background = UI.WHITE,
        margin = 0, padding = pad,
        -- (body_h: the tallest tile's body, so a row's tiles match)
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = math.max(body_h or 0, body:getSize().h) }, body },
    }
    return UI.tappable(frame, on_tap)
end

-- A row of the setup checklist: what, its state, and maybe a button.
local function checkRow(cw, label, state, hint, button)
    local function s(n) return Screen:scaleBySize(n) end
    local text_w = math.floor(cw * 0.62)
    local left = VerticalGroup:new{ align = "left",
        UI.text(label, "bold", 13, UI.BLACK, text_w),
        UI.para(hint, "body", 10, text_w, UI.INK2),
    }
    local right = VerticalGroup:new{ align = "right", UI.text(state, "pix", 10) }
    if button then
        right[#right + 1] = UI.vspace(s(6))
        right[#right + 1] = button
    end
    return VerticalGroup:new{ align = "left",
        UI.vspace(s(10)), UI.spread(cw, left, right), UI.vspace(s(10)), UI.rule(cw, s(1), UI.INK3) }
end

function Onboard:build()
    local function s(n) return Screen:scaleBySize(n) end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m
    local p = self.plugin
    local main = VerticalGroup:new{ align = "left" }
    local function add(w) main[#main + 1] = w end

    add(UI.header(cw, "READING LEDGER", UI.text(string.format("SET UP · %d/%d", self.step, STEPS), "pix", 11, UI.INK2)))
    add(UI.rule(cw, s(1), UI.INK3))
    add(UI.vspace(s(18)))

    local function title(t, sub)
        add(UI.para(t, "bold", 20, cw))
        if sub then
            add(UI.vspace(s(6)))
            add(UI.para(sub, "body", 12, cw, UI.INK2))
        end
        add(UI.vspace(s(18)))
    end

    -- the four animals, two by two
    local function grid(chosen_id, on_pick, with_hints, exclude)
        local gap = s(12)
        local tw = math.floor((cw - gap) / 2)
        -- every tile as tall as the tallest: measure the bodies first
        local body_h = 0
        for _, a in ipairs(Race.ANIMALS) do
            local line = with_hints and a.hint or nil
            if exclude == a.id then line = "That's you" end
            local t = animalTile(a, p:petName(a.id), line, tw, false, nil)
            body_h = math.max(body_h, t[1][1]:getSize().h)
        end
        local row
        for i, a in ipairs(Race.ANIMALS) do
            if i % 2 == 1 then row = HorizontalGroup:new{ align = "top" } end
            if #row > 0 then row[#row + 1] = UI.hspace(gap) end
            local line = with_hints and a.hint or nil
            if exclude == a.id then line = "That's you" end
            row[#row + 1] = animalTile(a, p:petName(a.id), line, tw, a.id == chosen_id, function()
                if exclude ~= a.id then on_pick(a.id) end
            end, body_h)
            if i % 2 == 0 or i == #Race.ANIMALS then
                add(row)
                add(UI.vspace(gap))
            end
        end
    end

    if self.step == 1 then
        title("Every book is a race.",
            "Pick your runner. It stands on your place in the book: the furthest of this device and Readest.")
        grid(p:runner(), function(id)
            p.settings:saveSetting("runner", id)
            if p:rival() == id then p.settings:saveSetting("rival", id == "dog" and "cat" or "dog") end
            p.settings:flush()
            self:update()
        end, false)
    elseif self.step == 2 then
        title("Now pick your rival.",
            "It learns how much and when you read, and tunes itself so the race stays close. Change it any time in Settings.")
        grid(p:rival(), function(id)
            p.settings:saveSetting("rival", id)
            p.settings:flush()
            self:update()
        end, true, p:runner())
    elseif self.step == 3 then
        title("What the Ledger can see.", "None of these is required; each one adds something.")
        add(UI.rule(cw, s(1), UI.INK3))
        local st = p:sourceStatus()
        local stats_on = p:statisticsOn()
        add(checkRow(cw, "Reading statistics", stats_on and "ON" or "OFF",
            stats_on and "Your rival learns your habits from them."
                or "Your rival learns your habits from these. Turn them on, then restart KOReader.",
            not stats_on and UI.button("Turn on", function() p:enableStatistics(); self:update() end, true, 10) or nil))
        add(checkRow(cw, "Readest", st.readest,
            st.readest == "SIGNED IN" and "Reading there counts in the race."
                or "Sign in from Readest's own menu and reading there counts too.", nil))
        add(checkRow(cw, "Bookbridge", st.bookbridge,
            st.bookbridge == "NOT SET UP" and "Finds books for you: the Z-Library plugin, an Anna's Archive key, or (optional) a book server of your own."
                or "Search and request books, new arrivals. It lives in the Ledger: Settings > Bookbridge.",
            p:bookbridge() and UI.button(st.bookbridge == "CONNECTED" and "Open" or "Connect",
                function() p:openBookbridge() end, true, 10) or nil))
        add(checkRow(cw, "Hardcover", st.hardcover, "Your yearly goal, paid in fish. Uses your own API key.",
            UI.button(st.hardcover == "ADD KEY" and "Add key" or "Change", function() p:editHardcoverKey() end, true, 10)))
    else
        title("Make it your home screen?",
            "The Ledger opens when KOReader starts and when you close a book. Files stays one tap away, and Settings can turn this off.")
        local on = p:homeOn()
        add(HorizontalGroup:new{ align = "center",
            UI.button("Yes, open on start", function() p:setHome(true); self:update() end, not on),
            UI.hspace(s(10)),
            UI.button("Not now", function() p:setHome(false); self:update() end, on),
        })
    end

    -- footer: back / skip / next
    local next_label = self.step == STEPS and "Done" or "Next"
    local left = self.step > 1 and UI.button("< Back", function() self:go(self.step - 1) end, true)
        or UI.tappable(UI.text("SKIP SETUP", "pix", 10, UI.INK2), function() self:finish() end)
    local foot = UI.spread(cw, left, UI.button(next_label .. (self.step == STEPS and "" or " >"), function() self:go(self.step + 1) end))
    local used = main:getSize().h + foot:getSize().h + 2 * m
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0, padding = m,
        VerticalGroup:new{ align = "left", main, UI.vspace(math.max(0, H - used)), foot },
    }
end

return Onboard
