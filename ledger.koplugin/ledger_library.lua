--[[
The library: every book on the device as a grid of covers, paged (no
scrolling on e-ink). Each cover wears a badge in the Ledger's style --
the cat and your percentage if you're reading it, the dog and NEW if it
just arrived, a fish if it's finished. Filters, sort, and a way out to
KOReader's own file browser for folders.
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

local FILTERS = {
    { id = "all", label = "All" },
    { id = "reading", label = "Reading" },
    { id = "new", label = "New" },
    { id = "finished", label = "Finished" },
}
local SORTS = { "recent", "title", "author", "series" }
local SORT_LABEL = { recent = "Recent", title = "Title", author = "Author", series = "Series" }

local Library = InputContainer:extend{
    name = "ledger_library",
    covers_fullscreen = true,
    plugin = nil,
    books = nil,     -- all records (Data.library)
    filter = "all",
    sort = "recent",
    page = 1,
}

function Library:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    self.ges_events = {
        Swipe = { require("ui/gesturerange"):new{ ges = "swipe", range = self.dimen } },
    }
    self:refilter()
    self[1] = self:build()
end

function Library:onClose()
    UIManager:close(self, "flashui")
    return true
end

function Library:onSwipe(_, ges)
    local dir = ges and ges.direction
    if dir == "west" then return self:onNextPage() end
    if dir == "east" then return self:onPrevPage() end
end

function Library:onNextPage()
    if self.page < self.pages then self.page = self.page + 1; self:redraw() end
    return true
end

function Library:onPrevPage()
    if self.page > 1 then self.page = self.page - 1; self:redraw() end
    return true
end

local function lower(s) return type(s) == "string" and s:lower() or "\255" end

function Library:refilter()
    local list = {}
    for _, rec in ipairs(self.books or {}) do
        local st = Data.status(rec)
        if self.filter == "all" or self.filter == st then list[#list + 1] = rec end
    end
    local sort = self.sort
    table.sort(list, function(a, b)
        if sort == "title" then return lower(a.title) < lower(b.title) end
        if sort == "author" then
            if lower(a.author) ~= lower(b.author) then return lower(a.author) < lower(b.author) end
            return lower(a.title) < lower(b.title)
        end
        if sort == "series" then
            if lower(a.series) ~= lower(b.series) then return lower(a.series) < lower(b.series) end
            if (a.series_index or 0) ~= (b.series_index or 0) then return (a.series_index or 0) < (b.series_index or 0) end
            return lower(a.title) < lower(b.title)
        end
        -- recent: last opened, then newest file
        local ta = math.max(a.last_open or 0, a.added or 0)
        local tb = math.max(b.last_open or 0, b.added or 0)
        if ta ~= tb then return ta > tb end
        return lower(a.title) < lower(b.title)
    end)
    self.list = list
end

function Library:redraw()
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
    if self.plugin then self.plugin:fetchCoversFor(self:visible(), function() self:refreshCovers() end) end
end

-- covers arrived from the extractor: rebuild without re-fetching
function Library:refreshCovers()
    if not UIManager:isWidgetShown(self) then return end
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

function Library:setFilter(id)
    self.filter, self.page = id, 1
    self:refilter()
    self:redraw()
end

function Library:nextSort()
    for i, s in ipairs(SORTS) do
        if s == self.sort then self.sort = SORTS[i % #SORTS + 1] break end
    end
    self.page = 1
    self:refilter()
    self:redraw()
end

-- A cover, untouched; the status lives underneath it: a thin progress line
-- while you're reading, and a small grey note at the end of the author line.
function Library:tile(rec, w, h, text_w)
    text_w = text_w or w
    local function s(n) return Screen:scaleBySize(n) end
    local cover = UI.cover(rec, w, h)
    local st = Data.status(rec)
    local vg = VerticalGroup:new{ align = "left", cover, UI.vspace(s(3)) }
    if st == "reading" then
        vg[#vg + 1] = UI.miniTrack(w, rec.pct or 0)
    else
        vg[#vg + 1] = UI.vspace(s(4))
    end
    vg[#vg + 1] = UI.vspace(s(4))
    vg[#vg + 1] = UI.text(rec.title or "?", "bold", 10, UI.BLACK, text_w)

    local note
    local icon_h = s(11)
    if st == "reading" then
        note = UI.text(string.format("%d%%", math.floor((rec.pct or 0) * 100 + 0.5)), "body", 9, UI.INK2)
    elseif st == "new" then
        note = HorizontalGroup:new{ align = "center",
            UI.sprite("dog_sit", UI.spriteScaleH("dog_sit", icon_h)), UI.hspace(s(3)), UI.text("new", "body", 9, UI.INK2) }
    elseif st == "finished" then
        note = HorizontalGroup:new{ align = "center",
            UI.sprite("fish", UI.spriteScaleH("fish", math.floor(icon_h * 0.7))), UI.hspace(s(3)), UI.text("done", "body", 9, UI.INK2) }
    end
    local note_w = note and note:getSize().w + s(6) or 0
    -- the note lines up with the cover's right edge, not the column's
    local author = UI.text(rec.author or "", "body", 9, UI.INK2, math.max(s(20), w - note_w))
    vg[#vg + 1] = note and UI.spread(w, author, note) or author
    -- every tile takes its column's full width, so the grid stays aligned
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local cell = LeftContainer:new{ dimen = Geom:new{ w = text_w, h = vg:getSize().h }, vg }
    return UI.tappable(cell, function() self.plugin:showBook(rec) end)
end

function Library:build()
    local function s(n) return Screen:scaleBySize(n) end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m

    local top = VerticalGroup:new{ align = "left" }
    top[#top + 1] = UI.spread(cw,
        UI.tappable(UI.text("< BACK", "pix", 11), function() self:onClose() end),
        UI.text(string.format("LIBRARY · %d BOOKS", #(self.books or {})), "pix", 11))
    top[#top + 1] = UI.vspace(s(10))

    local chips = HorizontalGroup:new{}
    for _, f in ipairs(FILTERS) do
        if #chips > 0 then chips[#chips + 1] = UI.hspace(s(6)) end
        chips[#chips + 1] = UI.button(f.label, function() self:setFilter(f.id) end, f.id ~= self.filter, 10)
    end
    local sort_btn = UI.button("Sort: " .. SORT_LABEL[self.sort], function() self:nextSort() end, true, 10)
    top[#top + 1] = UI.spread(cw, chips, sort_btn)
    top[#top + 1] = UI.vspace(s(12))

    -- footer first, so the grid knows how much room it has
    local foot_h = s(44)
    -- four across on anything Paperwhite-sized or bigger, three on small screens
    local cols = cw >= s(420) and 4 or 3
    local gap = s(12)
    local tile_w = math.floor((cw - (cols - 1) * gap) / cols)
    local text_h = s(50)
    local grid_h = H - 2 * m - top:getSize().h - foot_h
    -- as many full-width rows as fit; if two-thirds of another row is left
    -- over, shrink the covers a little so it fits too
    -- covers may shrink to 70% of the column's natural height to fit a row more
    local min_row = math.floor(tile_w * 1.45 * 0.7) + s(4) + text_h + gap
    local rows = math.max(1, math.floor(grid_h / min_row))
    local cover_h = math.min(math.floor(tile_w * 1.45), math.floor(grid_h / rows) - s(4) - text_h - gap)
    local cover_w = math.min(tile_w, math.floor(cover_h / 1.45))
    local per_page = rows * cols
    self.per_page = per_page
    self.pages = math.max(1, math.ceil(#self.list / per_page))
    if self.page > self.pages then self.page = self.pages end

    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * per_page + 1
    for r = 0, rows - 1 do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 0, cols - 1 do
            local rec = self.list[first + r * cols + c]
            if not rec then break end
            if c > 0 then row[#row + 1] = UI.hspace(gap) end
            row[#row + 1] = self:tile(rec, cover_w, cover_h, tile_w)
        end
        if #row == 0 then break end
        grid[#grid + 1] = row
        grid[#grid + 1] = UI.vspace(gap)
    end
    if #self.list == 0 then
        local empty = { all = "No books here yet. Pip will bring some.", reading = "Nothing in progress.",
            new = "Nothing new. Pip is out looking.", finished = "No finished books yet. Keep racing." }
        grid[#grid + 1] = UI.text(empty[self.filter] or "", "body", 13, UI.INK2, cw)
    end

    local nav = HorizontalGroup:new{ align = "center",
        UI.button("< Prev", function() self:onPrevPage() end, true, 10),
        UI.hspace(s(10)),
        UI.text(string.format("PAGE %d/%d", self.page, self.pages), "pix", 10),
        UI.hspace(s(10)),
        UI.button("Next >", function() self:onNextPage() end, true, 10),
    }
    local files = UI.button("Files", function() self.plugin:openFiles() end, true, 10)
    local foot = UI.spread(cw, nav, files)

    local used = top:getSize().h + grid:getSize().h + foot:getSize().h + 2 * m
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0, padding = m,
        VerticalGroup:new{ align = "left", top, grid, UI.vspace(math.max(0, H - used)), foot },
    }
end

-- The covers on the current page, for the cover extractor.
function Library:visible()
    local out = {}
    local per_page = self.per_page or 12
    local first = (self.page - 1) * per_page + 1
    for i = first, math.min(#self.list, first + per_page - 1) do out[#out + 1] = self.list[i] end
    return out
end

return Library
