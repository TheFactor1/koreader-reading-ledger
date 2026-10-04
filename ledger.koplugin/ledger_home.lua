--[[
The Reading Ledger's front page.

  READING LEDGER                                   SUN 04 OCT
  [ room: Biscuit the cat + what she has to say           ]
  Golden Son                         (tap: the book page)
  Pierce Brown · Red Rising 2
  [ race: cat = this Kindle, dog = Readest, flag = end    ]
  [CATCH UP WITH THE DOG]
  PIP FETCHED            | WAITING FOR
  ...                    | ...
  fish goal / trending
  [LIBRARY] [SEARCH] [MENU]
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

local Home = InputContainer:extend{
    name = "ledger_home",
    covers_fullscreen = true,
    plugin = nil, -- the Ledger plugin instance (actions)
    data = nil,   -- Data.collect() + pages_today
    cache = nil,  -- remote data (hardcover, trending, requests)
}

function Home:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self[1] = self:build()
end

function Home:onClose()
    UIManager:close(self, "flashui")
    return true
end

function Home:update(data, cache)
    if data then self.data = data end
    if cache then self.cache = cache end
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

-- What Biscuit says, and which pose she's in.
function Home:petLine(d)
    local lead = d.lead
    local days = Data.daysSinceReading(d.history)
    if days and days >= 3 then
        return "cat_lie", string.format("Biscuit dozed off. It's been %d days since you read.", days)
    end
    local parts = {}
    local pages = d.pages_today or 0
    if pages > 0 then
        parts[#parts + 1] = string.format("You read %d page%s today.", pages, pages == 1 and "" or "s")
    end
    if lead then
        if lead.readest and lead.readest.pct then
            local diff = math.floor((lead.readest.pct - (lead.pct or 0)) * 100 + 0.5)
            if diff >= 1 then
                parts[#parts + 1] = string.format("The dog is %d%% ahead.", diff)
            elseif diff <= -1 then
                parts[#parts + 1] = "You're ahead of the dog."
            else
                parts[#parts + 1] = "Neck and neck with the dog."
            end
        elseif d.readest_signed_in then
            parts[#parts + 1] = "The dog hasn't started this one."
        else
            parts[#parts + 1] = "The dog sits this one out."
        end
    else
        parts[#parts + 1] = "Pick a book and the race begins."
    end
    return "cat_sit", table.concat(parts, " ")
end

local function bookItem(rec, width, callback)
    local function s(n) return Screen:scaleBySize(n) end
    local vg = VerticalGroup:new{
        align = "left",
        UI.text(rec.title or "?", "bold", 12, UI.BLACK, width),
    }
    if rec.sub then vg[#vg + 1] = UI.text(rec.sub, "body", 10, UI.INK2, width) end
    vg[#vg + 1] = UI.vspace(s(5))
    return callback and UI.tappable(vg, callback) or vg
end

local function column(width, icon_name, icon_h, label, items, empty_text)
    local function s(n) return Screen:scaleBySize(n) end
    local icon = UI.sprite(icon_name, UI.spriteScaleH(icon_name, icon_h))
    local head = HorizontalGroup:new{ align = "bottom", icon, UI.hspace(s(6)), UI.text(label:upper(), "pix", 10) }
    local vg = VerticalGroup:new{ align = "left", head, UI.vspace(s(3)), UI.rule(width, s(2)), UI.vspace(s(5)) }
    if #items == 0 then
        vg[#vg + 1] = UI.text(empty_text, "body", 11, UI.INK2, width)
    else
        for _, it in ipairs(items) do vg[#vg + 1] = it end
    end
    return vg
end

function Home:build()
    local function s(n) return Screen:scaleBySize(n) end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m
    local d = self.data or {}
    local c = self.cache or {}
    local plugin = self.plugin

    local main = VerticalGroup:new{ align = "left" }
    local function add(w) main[#main + 1] = w end

    add(UI.spread(cw, UI.text("READING LEDGER", "pix", 11), UI.text(os.date("%a %d %b"):upper(), "pix", 11)))
    add(UI.vspace(s(8)))

    -- the room
    local pose, line = self:petLine(d)
    add(UI.room(cw, math.floor(H * 0.13), pose, UI.spriteScale(pose, cw * 0.15), "Biscuit", line))
    add(UI.vspace(s(10)))

    -- the book you're on, and its race
    local lead = d.lead
    if lead then
        local sub = lead.author
        if lead.series then
            sub = (sub and sub .. " · " or "") .. lead.series .. (lead.series_index and (" " .. lead.series_index) or "")
        end
        local head = VerticalGroup:new{ align = "left", UI.text(lead.title, "bold", 20, UI.BLACK, cw) }
        if sub then head[#head + 1] = UI.text(sub, "body", 12, UI.INK2, cw) end
        add(UI.tappable(head, function() plugin:showBook(lead) end))
        add(UI.vspace(s(6)))
        local dog_pct = lead.readest and lead.readest.pct or nil
        add(UI.race(cw, lead.pct or 0, dog_pct, 2))
        add(UI.vspace(s(4)))
        local right = dog_pct and ("Dog: Readest, " .. (Data.ago(lead.readest.updated_at) or "synced"))
            or (d.readest_signed_in and "Dog: not in Readest" or "Dog: no Readest")
        add(UI.spread(cw, UI.text("Cat: this Kindle", "body", 10, UI.INK2), UI.text(right, "body", 10, UI.INK2)))
        add(UI.vspace(s(8)))
        if Data.readestAhead(lead) then
            add(UI.button("Catch up with the dog", function() plugin:continueFromReadest(lead) end))
        else
            add(UI.button("Keep reading", function() plugin:openBook(lead) end))
        end
    else
        add(UI.para("Nothing on the go. Open a book from Pip's fetches below or from your library, and the race begins.", "body", 13, cw))
    end
    add(UI.vspace(s(14)))

    -- other books in progress
    local others = {}
    for _, rec in ipairs(d.reading or {}) do
        if #others >= 2 then break end
        others[#others + 1] = rec
    end
    if #others > 0 then
        add(UI.text("ON THE GO", "pix", 10))
        add(UI.vspace(s(3)))
        add(UI.rule(cw, s(2)))
        add(UI.vspace(s(5)))
        for _, rec in ipairs(others) do
            local here = math.floor((rec.pct or 0) * 100 + 0.5)
            local where = string.format("here %d%%", here)
            if rec.readest and rec.readest.pct then
                where = where .. string.format(" · Readest %d%%", math.floor(rec.readest.pct * 100 + 0.5))
            end
            local right = UI.text(where, "body", 10, UI.INK2)
            local left = UI.text(rec.title, "bold", 12, UI.BLACK, cw - right:getSize().w - s(12))
            add(UI.tappable(UI.spread(cw, left, right), function() plugin:showBook(rec) end))
            add(UI.vspace(s(6)))
        end
        add(UI.vspace(s(8)))
    end

    -- what's new, what's awaited
    local col_w = math.floor((cw - s(14)) / 2)
    local icon_h = math.floor(W * 0.05)
    local fetched = {}
    for i, rec in ipairs(d.just_in or {}) do
        if i > 3 then break end
        rec.sub = rec.author
        fetched[#fetched + 1] = bookItem(rec, col_w, function() plugin:showBook(rec) end)
    end
    local waiting = {}
    for i, r in ipairs(c.requests or {}) do
        if i > 3 then break end
        waiting[#waiting + 1] = bookItem({ title = r.title, sub = r.note or r.author }, col_w,
            function() plugin:showRequest(r) end)
    end
    add(HorizontalGroup:new{
        align = "top",
        column(col_w, "dog_sit", icon_h, "Pip fetched", fetched, "Nothing new yet."),
        UI.hspace(s(14)),
        column(col_w, "cat_sit_side", icon_h, "Waiting for", waiting, "Nothing on order."),
    })

    -- trending (no Hardcover key) fills the middle
    if not c.hardcover and c.trending and #c.trending > 0 and (self._trend_n or 3) > 0 then
        add(UI.vspace(s(12)))
        add(UI.text("TRENDING ON OPEN LIBRARY", "pix", 10))
        add(UI.vspace(s(3)))
        add(UI.rule(cw, s(2)))
        add(UI.vspace(s(5)))
        for i, t in ipairs(c.trending) do
            if i > (self._trend_n or 3) then break end
            add(bookItem({ title = t.title, sub = t.author }, cw, function() plugin:requestBook(t.title, t.author) end))
        end
    end

    -- footer: goal and buttons, pinned to the bottom
    local foot = VerticalGroup:new{ align = "left" }
    local hc = c.hardcover
    if hc and hc.goal and hc.goal.goal then
        local fish = UI.fishRow(math.min(hc.goal.goal, 24), hc.goal.progress or 0, cw / 22)
        foot[#foot + 1] = UI.rule(cw, s(2))
        foot[#foot + 1] = UI.vspace(s(6))
        foot[#foot + 1] = UI.spread(cw, fish, UI.text(string.format("%d/%d", hc.goal.progress or 0, hc.goal.goal), "pix", 11))
        foot[#foot + 1] = UI.vspace(s(3))
        foot[#foot + 1] = UI.text(string.format("Hardcover: reading %d · read %d · want %d", hc.reading or 0, hc.read or 0, hc.want or 0),
            "body", 10, UI.INK2, cw)
    elseif not hc then
        foot[#foot + 1] = UI.tappable(UI.text("Add your Hardcover key for your shelves and goal ›", "body", 11, UI.INK2, cw),
            function() plugin:editHardcoverKey() end)
    end
    foot[#foot + 1] = UI.vspace(s(10))
    foot[#foot + 1] = HorizontalGroup:new{
        UI.button("Library", function() plugin:openLibrary() end, true),
        UI.hspace(s(8)),
        UI.button("Search", function() plugin:search() end, true),
        UI.hspace(s(8)),
        UI.button("Menu", function() plugin:showMenu() end, true),
    }

    local used = main:getSize().h + foot:getSize().h + 2 * m
    -- too tall for this screen: show fewer trending books (the only part
    -- that is extra) and lay out again
    if used > H and not c.hardcover and (self._trend_n or 3) > 0 then
        self._trend_n = (self._trend_n or 3) - 1
        local again = self:build()
        self._trend_n = nil
        return again
    end
    local filler = math.max(s(6), H - used)
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0,
        padding = m, padding_bottom = math.max(0, m - math.max(0, used - H)),
        width = W, height = H,
        VerticalGroup:new{ align = "left", main, UI.vspace(filler), foot },
    }
end

return Home
