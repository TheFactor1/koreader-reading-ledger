--[[
The book page: one place for what every source knows about a book.
Cover and details, the race against your rival, the actions, and the
rival in its room with something to say about it.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local UIManager = require("ui/uimanager")
local Chase = require("ledger_chase")
local Data = require("ledger_data")
local Race = require("ledger_race")
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
    UI.addTopMenu(self)
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

-- What the rival has to say about this book.
function Book:rivalLine(rec, lines)
    if not rec.opened then
        return "New arrival! Open it and the race starts."
    end
    if Data.isFinished(rec) then
        local res = Race.result(self.plugin.settings, rec)
        if res and res.won then
            return string.format("You beat me to the flag by %d %s. Good race.", res.by or 0, (res.by or 0) == 1 and "page" or "pages")
        elseif res then
            return "I got to the flag first this time. Rematch?"
        end
        return "You finished this one. Good race."
    end
    return (lines.rival_says:gsub("^[^:]*: ", ""))
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

    add(UI.header(cw, UI.tappable(UI.text("< BACK", "pix", 11), function() self:onClose() end),
        UI.text("BOOK", "pix", 11)))

    -- cover and details
    local cover_w = math.floor(cw * 0.32)
    local cover = UI.cover(rec, cover_w, math.floor(cover_w * 1.5))
    local info_w = cw - cover_w - s(14)
    local title = UI.para(rec.title or "?", "bold", 18, info_w)
    local info = VerticalGroup:new{ align = "left", title }
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
    -- the cover's top edge meets the top of the title's capitals, as on
    -- the Currently reading page
    local cap_top = math.max(0, title:getBaseline() - math.floor(UI.face("bold", 18).size * 0.70 + 0.5))
    add(HorizontalGroup:new{ align = "top",
        VerticalGroup:new{ align = "left", UI.vspace(cap_top), cover }, UI.hspace(s(14)), info })
    add(UI.vspace(s(14)))

    -- the race (a book not opened yet only shows the start line)
    local stats = Data.readingStats(rec.hash)
    local race = Race.state(rec, stats, plugin.settings, plugin:runner(), plugin:rival(), plugin:raceModel(), nil, not rec.opened)
    -- a finished race stays as it ended
    local res = Data.isFinished(rec) and Race.result(plugin.settings, rec)
    if res then
        race.you_pages, race.you_pct = race.total, 1
        race.rival_pages = res.won and math.max(0, race.total - (res.by or 0)) or race.total
        race.rival_pct = race.rival_pages / race.total
        race.ahead = race.rival_pages - race.total
        race.rival_done, race.napping = not res.won, false
    end
    local lines = Race.lines(plugin, rec, race, plugin.cache)
    local chase = Chase:new{
        width = cw, height = math.floor(H * 0.16),
        you = plugin:runner(), rival = plugin:rival(), style = plugin:raceStyle(),
        you_pct = race.you_pct, rival_pct = race.rival_pct, napping = race.napping,
        you_says = lines.you_says, rival_says = lines.rival_says, fish_says = lines.fish_says,
        animate = false, t = 1,
    }
    chase.show_parent = self
    add(chase)
    add(UI.vspace(s(4)))
    add(UI.spread(cw, UI.text(lines.you_label, "body", 10, UI.INK2), UI.text(lines.rival_label, "body", 10, UI.INK2)))
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
        local label = not rec.opened and "Start reading" or Data.isFinished(rec) and "Read again" or "Keep reading"
        btn(label, function() plugin:openBook(rec) end)
    end
    add(buttons)

    -- the rival's room, pinned to the bottom
    local room_h = math.floor(H * 0.13)
    local rival = Race.animal(plugin:rival())
    local room = UI.room(cw, room_h, rival.still, math.min(UI.spriteScale(rival.still, cw * 0.12),
        UI.spriteScaleH(rival.still, room_h * 0.6)), plugin:petName(rival.id), self:rivalLine(rec, lines))
    local used = main:getSize().h + room_h + 2 * m
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0, padding = m,
        VerticalGroup:new{ align = "left", main, UI.vspace(math.max(s(8), H - used)), room },
    }
end

return Book
