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
    { id = "trending", label = "Trending" },   -- not on the device: Open Library's week
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
    UI.addTopMenu(self)
    self:refilter()
    self[1] = self:build()
end

function Library:onClose()
    self.plugin:closeAll()
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

-- Open Library's trending books, as records for the grid. Each knows
-- whether a book of that title is already on the device.
function Library:trendingList()
    local have = {}
    for _, rec in ipairs(self.books or {}) do
        if type(rec.title) == "string" then have[rec.title:lower()] = rec end
    end
    local list = {}
    for _, item in ipairs((self.plugin and self.plugin.cache or {}).trending or {}) do
        list[#list + 1] = {
            title = item.title, author = item.author, year = item.year,
            cover_file = item.cover, trending = true,
            on_device = item.title and have[item.title:lower()] or nil,
        }
    end
    return list
end

function Library:refilter()
    if self.filter == "trending" then
        self.list = self:trendingList()
        return
    end
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
    -- (the trending shelf may just have arrived)
    if self.filter == "trending" then self:refilter() end
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

function Library:setFilter(id)
    self.filter, self.page = id, 1
    -- the trending shelf fetches itself if it's empty or a day old
    if id == "trending" then self.plugin:refreshTrending() end
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
-- Status styles (setting ledger_bar_style while one is chosen):
--   pill    an outlined tag under the cover: tiny pet + number / NEW / DONE
--   edge    the cover's bottom edge is the progress line; number on the title line
--   numeral no bar; pixel-font number right-aligned on the title line, pet before it
--   inline  one row: fixed-width number column, slim bar filling the rest
local BAR_STYLE_DEFAULT = "inline"

-- the chosen style, or the default for anything unknown
local BAR_STYLES = { pill = true, edge = true, numeral = true, inline = true }
local function barStyle()
    local style = G_reader_settings:readSetting("ledger_bar_style")
    return BAR_STYLES[style] and style or BAR_STYLE_DEFAULT
end

local function statusOf(rec)
    if rec.trending then
        if rec.on_device then return "finished", nil, "ON DEVICE" end
        return "unread", nil, rec.year and tostring(rec.year) or nil
    end
    local st = Data.status(rec)
    if st == "reading" then
        local pct = rec.pct or 0
        return st, pct, string.format("%d%%", math.floor(pct * 100 + 0.5))
    elseif st == "finished" then
        -- a race result when there was a race: WON / LOST
        if rec.result then return st, 1, rec.result.won and "WON" or "LOST" end
        return st, 1, "DONE"
    elseif st == "new" then return st, 0, "NEW" end
    return st, nil, nil
end

local PET = { reading = "cat_sit", new = "dog_sit", finished = "fish" }

local function petIcon(st, h)
    local name = PET[st]
    if not name then return nil end
    if name == "fish" then h = math.floor(h * 0.6) end
    return UI.sprite(name, UI.spriteScaleH(name, h))
end

-- A slim progress line: grey track, black fill.
local function slimBar(w, h, pct)
    local Widget = require("ui/widget/widget")
    return Widget:new{
        dimen = Geom:new{ w = w, h = h },
        paintTo = function(_, bb, x, y)
            bb:paintRect(x, y, w, h, UI.INK4)
            local fill = math.floor(w * math.max(0, math.min(1, pct or 0)))
            if fill > 0 then bb:paintRect(x, y, fill, h, UI.BLACK) end
        end,
    }
end

-- The status element and how tall it is, for one style (used to size the grid too).
function Library:statusRow(style, w, st, pct, label)
    local function s(n) return Screen:scaleBySize(n) end
    if style == "pill" then
        if not label then return UI.vspace(s(22)) end
        local inner = HorizontalGroup:new{ align = "center" }
        local icon = petIcon(st, s(12))
        if icon then inner[#inner + 1] = icon; inner[#inner + 1] = UI.hspace(s(4)) end
        inner[#inner + 1] = UI.text(label, "pix", 9)
        return FrameContainer:new{ bordersize = s(2), color = UI.BLACK, background = UI.WHITE, margin = 0,
            padding = s(2), padding_left = s(5), padding_right = s(6), inner }
    elseif style == "inline" then
        local num_w = UI.text("100%", "pix", 9):getSize().w + s(6)
        local h = UI.text("0", "pix", 9):getSize().h
        if not label then return UI.vspace(h) end
        local LeftContainer = require("ui/widget/container/leftcontainer")
        if not pct then
            -- no progress to show (a trending book): just the label
            return LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, UI.text(label, "pix", 9, UI.INK2) }
        end
        return HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = num_w, h = h }, UI.text(label, "pix", 9) },
            slimBar(w - num_w, s(5), pct) }
    end
    return nil -- edge and numeral carry status on the cover / title line
end

function Library:tile(rec, w, h, text_w)
    text_w = text_w or w
    local function s(n) return Screen:scaleBySize(n) end
    local style = barStyle()
    local st, pct, label = statusOf(rec)
    local vg = VerticalGroup:new{ align = "left" }

    local cover = UI.cover(rec, w, h)
    if style == "edge" and pct then
        -- the cover's bottom edge doubles as the progress line
        local OverlapGroup = require("ui/widget/overlapgroup")
        local line = slimBar(w, s(5), pct)
        line.overlap_offset = { 0, h - s(5) }
        cover = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, cover, line }
    end
    vg[#vg + 1] = cover
    vg[#vg + 1] = UI.vspace(s(6))

    local row = self:statusRow(style, w, st, pct, label)
    if row then
        vg[#vg + 1] = row
        vg[#vg + 1] = UI.vspace(s(6))
    end

    -- title line; edge and numeral put the number at its right end
    local title_right
    if (style == "edge" or style == "numeral") and label then
        if style == "numeral" then
            local icon = petIcon(st, s(11))
            title_right = HorizontalGroup:new{ align = "center" }
            if icon then title_right[#title_right + 1] = icon; title_right[#title_right + 1] = UI.hspace(s(4)) end
            title_right[#title_right + 1] = UI.text(label, "pix", 10)
        else
            title_right = UI.text(label, "pix", 9, UI.INK2)
        end
    end
    local right_w = title_right and title_right:getSize().w + s(8) or 0
    local title = UI.text(rec.title or "?", "bold", 10, UI.BLACK, w - right_w)
    vg[#vg + 1] = title_right and UI.spread(w, title, title_right) or title
    vg[#vg + 1] = UI.text(rec.author or "", "body", 9, UI.INK2, w)
    -- every tile takes its column's full width, so the grid stays aligned
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local cell = LeftContainer:new{ dimen = Geom:new{ w = text_w, h = vg:getSize().h }, vg }
    -- tap: open the book; hold: its page (the race, details, Readest)
    if rec.trending then
        return UI.tappable(cell, function() self.plugin:showTrending(rec) end)
    end
    return UI.tappable(cell, function() self.plugin:openBook(rec) end, function() self.plugin:showBook(rec) end)
end

-- Height of everything under a cover, measured from the real widgets.
function Library:captionHeight(w)
    local function s(n) return Screen:scaleBySize(n) end
    local style = barStyle()
    local h = s(6) + UI.text("Ag", "bold", 10):getSize().h + UI.text("Ag", "body", 9):getSize().h
    local row = self:statusRow(style, w, "reading", 0.5, "50%")
    if row then h = h + row:getSize().h + s(6) end
    return h
end

function Library:build()
    local function s(n) return Screen:scaleBySize(n) end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m

    local top = VerticalGroup:new{ align = "left" }
    local total = #(self.books or {})
    local count = self.filter == "all" and string.format("%d BOOKS", total)
        or self.filter == "trending" and "TRENDING THIS WEEK"
        or string.format("%d OF %d", #self.list, total)
    -- KOReader's file browser (folders, file operations): a link up here
    local files = UI.tappable(UI.text("FILES >", "pix", 11), function() self.plugin:openFiles() end)
    top[#top + 1] = UI.header(cw, "LIBRARY · " .. count, files)

    local chips = HorizontalGroup:new{}
    for _, f in ipairs(FILTERS) do
        if #chips > 0 then chips[#chips + 1] = UI.hspace(s(6)) end
        chips[#chips + 1] = UI.button(f.label, function() self:setFilter(f.id) end, f.id ~= self.filter, 10)
    end
    -- (the trending shelf is in Open Library's order: no sorting there)
    local sort_btn = self.filter ~= "trending"
        and UI.button("Sort: " .. SORT_LABEL[self.sort], function() self:nextSort() end, true, 10)
        or UI.hspace(0)
    top[#top + 1] = UI.spread(cw, chips, sort_btn)
    top[#top + 1] = UI.vspace(s(12))

    -- footer first, so the grid knows how much room it has: the tabs, and
    -- the paging row only when there's more than one page
    local tabs = UI.tabBar(cw, "library", function(id) self.plugin:showTab(id) end)
    local nav_h = UI.button("Next >", nil, true, 10):getSize().h + s(12)
    local foot_h = tabs:getSize().h
    local function layout(with_nav)
        -- four across on anything Paperwhite-sized or bigger, three on small screens
        local cols = cw >= s(420) and 4 or 3
        local gap = s(12)
        local tile_w = math.floor((cw - (cols - 1) * gap) / cols)
        local text_h = self:captionHeight(tile_w)
        local grid_h = H - 2 * m - top:getSize().h - foot_h - (with_nav and nav_h or 0)
        -- as many full-width rows as fit; if most of another row is left over,
        -- shrink the covers so it fits too
        -- covers may shrink to two-thirds of the column's natural height to fit a row more
        local min_row = math.floor(tile_w * 1.45 * 0.66) + s(4) + text_h + gap
        local rows = math.max(1, math.floor(grid_h / min_row))
        local cover_h = math.min(math.floor(tile_w * 1.45), math.floor(grid_h / rows) - s(4) - text_h - gap)
        local cover_w = math.min(tile_w, math.floor(cover_h / 1.45))
        -- when the covers shrank, spread the columns out so the last one still
        -- ends at the right margin (the leftover pixels go to the gaps, left first)
        local col_x = {}
        local spare = cw - cols * cover_w
        for c = 0, cols - 1 do
            col_x[c] = c * cover_w + math.floor(spare * c / (cols - 1))
        end
        local per_page = rows * cols
        return cols, gap, text_h, grid_h, rows, cover_h, cover_w, col_x, per_page
    end
    local cols, gap, text_h, grid_h, rows, cover_h, cover_w, col_x, per_page = layout(false)
    if #self.list > per_page then
        cols, gap, text_h, grid_h, rows, cover_h, cover_w, col_x, per_page = layout(true)
    end
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
            if c > 0 then row[#row + 1] = UI.hspace(col_x[c] - col_x[c - 1] - cover_w) end
            row[#row + 1] = self:tile(rec, cover_w, cover_h, cover_w)
        end
        if #row == 0 then break end
        grid[#grid + 1] = row
        grid[#grid + 1] = UI.vspace(gap)
    end
    -- room left under a full page's rows is shared between them, so the
    -- grid reaches down to the footer (the same spacing on every page)
    if grid[1] then
        local full = rows * (grid[1]:getSize().h + gap)
        local extra = math.floor(math.max(0, grid_h - full) / rows)
        for i = 2, #grid, 2 do grid[i].width = grid[i].width + extra end
        grid:resetLayout()
    end
    if #self.list == 0 then
        local empty = { all = "No books here yet. Pip will bring some.", reading = "Nothing in progress.",
            new = "Nothing new yet.", finished = "No finished books yet. Keep racing.",
            trending = "Nothing here yet. Trending books come from Open Library when you're online." }
        grid[#grid + 1] = UI.text(empty[self.filter] or "", "body", 13, UI.INK2, cw)
    end

    -- paging, centred, only when there is more than one page
    local foot = VerticalGroup:new{ align = "left" }
    if self.pages > 1 then
        local CenterContainer = require("ui/widget/container/centercontainer")
        local nav = HorizontalGroup:new{ align = "center",
            UI.button("< Prev", function() self:onPrevPage() end, true, 10),
            UI.hspace(s(14)),
            UI.text(string.format("PAGE %d/%d", self.page, self.pages), "pix", 10),
            UI.hspace(s(14)),
            UI.button("Next >", function() self:onNextPage() end, true, 10),
        }
        foot[#foot + 1] = CenterContainer:new{ dimen = Geom:new{ w = cw, h = nav:getSize().h }, nav }
        foot[#foot + 1] = UI.vspace(s(12))
    end
    foot[#foot + 1] = tabs

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

-- (timing: how long drawing the page takes, with the timing log on)
function Library:paintTo(bb, x, y)
    local t = require("ledger_timing").start()
    InputContainer.paintTo(self, bb, x, y)
    require("ledger_timing").lap(t, "paint.library")
end

return Library
