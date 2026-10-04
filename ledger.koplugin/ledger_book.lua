--[[
The book page: one place for what every source knows about a book.
Cover and details, the cat-and-dog race with the gap in pages, the actions,
and Pip the dog in his room with something to say about it.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local UIManager = require("ui/uimanager")
local Data = require("ledger_data")
local UI = require("ledger_ui")

local Screen = Device.screen

local HC_STATUS = { [1] = "Want to read", [2] = "Reading", [3] = "Read", [4] = "Paused", [5] = "Did not finish" }

local Book = InputContainer:extend{
    name = "ledger_book",
    covers_fullscreen = true,
    plugin = nil,
    rec = nil,      -- a Data record
    hc = nil,       -- Hardcover details once fetched: status_id, rating, avg_rating, series...
}

function Book:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self[1] = self:build()
end

function Book:onClose()
    UIManager:close(self, "flashui")
    return true
end

function Book:update(hc)
    self.hc = hc
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

-- What Pip has to say about this book.
function Book:dogLine(rec)
    if not rec.opened then
        return "New arrival! Open it and the race starts."
    end
    if Data.isFinished(rec) then
        return "You finished this one. Good race."
    end
    local r = rec.readest
    if not (r and r.pct) then
        return "I'm not racing this one. Put it in your Readest library and I'll join in."
    end
    local diff = r.pct - (rec.pct or 0)
    if diff >= 0.01 then
        if rec.pages and rec.pages > 0 then
            return string.format("Readest has you %d pages further on.", math.floor(diff * rec.pages + 0.5))
        end
        return string.format("Readest has you %d%% further on.", math.floor(diff * 100 + 0.5))
    elseif diff <= -0.01 then
        return "You're ahead of me. I'll catch up next time Readest syncs."
    end
    return "We're neck and neck."
end

function Book:build()
    local function s(n) return Screen:scaleBySize(n) end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m
    local rec = self.rec
    local plugin = self.plugin
    local hc = self.hc or {}

    local main = VerticalGroup:new{ align = "left" }
    local function add(w) main[#main + 1] = w end

    add(UI.spread(cw,
        UI.tappable(UI.text("< BACK", "pix", 11), function() self:onClose() end),
        UI.text("BOOK", "pix", 11)))
    add(UI.vspace(s(10)))

    -- cover and details
    local cover_w = math.floor(cw * 0.32)
    local cover = UI.cover(rec, cover_w, math.floor(cover_w * 1.5))
    local info_w = cw - cover_w - s(14)
    local info = VerticalGroup:new{ align = "left", UI.para(rec.title or "?", "bold", 18, info_w) }
    if rec.author then info[#info + 1] = UI.text(rec.author, "body", 12, UI.INK2, info_w) end
    info[#info + 1] = UI.vspace(s(6))
    local series = hc.series or rec.series
    local pos = hc.series_position or rec.series_index
    if series then
        info[#info + 1] = UI.para(series .. (pos and (" " .. pos) or ""), "body", 11, info_w, UI.INK2)
    end
    local facts = {}
    if rec.pages then facts[#facts + 1] = rec.pages .. " pages" end
    if hc.avg_rating then facts[#facts + 1] = string.format("%.2f on Hardcover", hc.avg_rating) end
    if #facts > 0 then info[#info + 1] = UI.para(table.concat(facts, " · "), "body", 11, info_w, UI.INK2) end
    if hc.status_id then
        info[#info + 1] = UI.vspace(s(6))
        info[#info + 1] = UI.text("Your shelf: " .. (HC_STATUS[hc.status_id] or "?"), "body", 11, UI.BLACK, info_w)
    end
    add(HorizontalGroup:new{ align = "top", cover, UI.hspace(s(14)), info })
    add(UI.vspace(s(14)))

    -- the race
    local dog_pct = rec.readest and rec.readest.pct or nil
    add(UI.race(cw, rec.pct or 0, dog_pct, 3))
    add(UI.vspace(s(4)))
    local left = rec.opened and string.format("Cat: here, %d%%", math.floor((rec.pct or 0) * 100 + 0.5)) or "Cat: not started"
    local right = dog_pct and ("Dog: Readest, " .. (Data.ago(rec.readest.updated_at) or "synced")) or "Dog: not racing"
    add(UI.spread(cw, UI.text(left, "body", 10, UI.INK2), UI.text(right, "body", 10, UI.INK2)))
    add(UI.vspace(s(10)))

    -- actions
    local buttons = HorizontalGroup:new{}
    local function btn(label, cb, outlined)
        if #buttons > 0 then buttons[#buttons + 1] = UI.hspace(s(8)) end
        buttons[#buttons + 1] = UI.button(label, cb, outlined)
    end
    if Data.readestAhead(rec) then
        local ahead, here = Data.jumpLabels(rec)
        btn(ahead, function() plugin:continueFromReadest(rec) end)
        btn(here, function() plugin:openBook(rec) end, true)
    else
        btn(rec.opened and "Keep reading" or "Start reading", function() plugin:openBook(rec) end)
    end
    add(buttons)

    -- Pip's room, pinned to the bottom
    local room_h = math.floor(H * 0.13)
    local room = UI.room(cw, room_h, "dog_sit", UI.spriteScale("dog_sit", cw * 0.12), "Pip", self:dogLine(rec))
    local used = main:getSize().h + room_h + 2 * m
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0, padding = m,
        VerticalGroup:new{ align = "left", main, UI.vspace(math.max(s(8), H - used)), room },
    }
end

return Book
