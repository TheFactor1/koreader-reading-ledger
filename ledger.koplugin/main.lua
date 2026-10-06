--[[
The Reading Ledger: a front page for KOReader with pixel pets.

Every book is a race: you pick your runner (cat, dog, rabbit or tortoise)
and a rival that reads a little more than you usually do (ledger_race.lua).
Your place is the furthest of this device and Readest. Your yearly
Hardcover goal is paid in fish.

Sources, all optional: this device, the Readest plugin, Bookbridge (requests,
Hardcover matches) and Hardcover with your own key. Without a key, trending
books come from Open Library, straight from the device.

Written by Claude (Anthropic) for Matt. Sprites: see sprites/CREDITS.txt.
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Bg = require("ledger_bg")
local Book = require("ledger_book")
local Data = require("ledger_data")
local Library = require("ledger_library")
local Reading = require("ledger_reading")
local Settings = require("ledger_settings")
local Net = require("ledger_net")
local Race = require("ledger_race")
local Readest = require("ledger_readest")
local Timing = require("ledger_timing")
local UI = require("ledger_ui")

local REFRESH_EVERY = 2 * 3600  -- Hardcover and requests older than this are refreshed on show
local TRENDING_EVERY = 86400     -- Open Library's weekly list, once a day

-- Where the runners stood when last on screen, per book: the run-in
-- animation only plays when one of them moved.
local shown_positions = {}

-- Set by "Continue from p. N" (Readest's place): the file whose Readest position to jump to
-- once it's open (the reader's own plugin instance does the jump).
local pending_readest_jump = nil

-- One settings object for every Ledger instance: the file browser and an
-- open book each load the plugin, and two copies of ledger.lua in memory
-- would overwrite each other's races, tuning and choices on flush.
local shared_settings = nil

-- Home screen: the Ledger opens over the file browser when KOReader starts
-- and each time a book is closed -- but not when the file browser is merely
-- rebuilt (a setting changed, Files chosen from the Ledger).
local first_start = true
local first_start_show = true   -- (the first home show of the session is a cold start)
local exit_timer = nil    -- (timing: from closing a book to the Ledger drawn)
local registerStartWith   -- (below, with the home screen)
local back_from_book = false

local Ledger = WidgetContainer:extend{
    name = "ledger",
    is_doc_only = false,
}

function Ledger:init()
    UI.setPluginDir(self.path)
    Timing.init(self.path)
    if not shared_settings then
        shared_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/ledger.lua")
        -- Writes are gathered: a visit to the Ledger can change several
        -- things (races, what Readest read, the rival's tuning), and each
        -- flush rewrites the whole file on the Kindle's flash. One write a
        -- couple of seconds later; at once on sleep, exit and closing.
        local real_flush = shared_settings.flush
        local pending = nil
        shared_settings.flushNow = function(st)
            if pending then UIManager:unschedule(pending); pending = nil end
            return real_flush(st)
        end
        shared_settings.flush = function(st)
            if pending then return end
            pending = function() pending = nil; real_flush(st) end
            UIManager:scheduleIn(3, pending)
        end
    end
    self.settings = shared_settings
    Dispatcher:registerAction("ledger_show", {
        category = "none", event = "ShowLedger", title = _("Reading Ledger"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    registerStartWith()
    -- (Bookbridge may start after the Ledger: tuck it away once all are up,
    -- which is still before KOReader first builds its menu)
    self:tuckBookbridge()
    UIManager:nextTick(function() self:tuckBookbridge() end)
    -- (the old "home" switch becomes start_with = "ledger")
    if self.settings:readSetting("home") == true and not self:homeOn() then self:setHome(true) end
    if not self.ui.document then
        -- the file browser: show the Ledger on top when it's the home screen
        local show_now = (first_start or back_from_book) and self:homeOn()
        first_start, back_from_book = false, false
        if show_now then
            -- KOReader tells the file browser's plugins it's being shown
            -- before drawing it: open then, so it never flashes up first
            -- (onShow below). A tick later as a fallback.
            self._home_pending = true
            UIManager:nextTick(function()
                if self._home_pending then
                    self._home_pending = false
                    if not (self.page and UIManager:isWidgetShown(self.page)) then self:show() end
                end
            end)
        end
    end
end

-- KOReader's own menu (the file browser's, or the reader's over a book).
function Ledger:showKOMenu()
    local menu = self.ui and self.ui.menu
    if menu and menu.onShowMenu then menu:onShowMenu() end
end

-- KOReader's statistics keep the pages of the book that's open in memory
-- until it's closed, the device sleeps or 50 pages go by; write them out
-- now so today counts what you just read.
function Ledger:flushStats()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok and ReaderUI and ReaderUI.instance
    local stats = reader and reader.statistics
    if stats and stats.insertDB and stats.settings and stats.settings.is_enabled then
        local fok, err = pcall(stats.insertDB, stats)
        if not fok then logger.warn("ledger: statistics flush failed:", err) end
    end
end

-- Write any gathered settings now: the device is going to sleep or
-- KOReader is closing.
function Ledger:onSuspend() self.settings:flushNow() end
function Ledger:onFlushSettings() self.settings:flushNow() end

function Ledger:onShow()
    if self._home_pending then
        self._home_pending = false
        self._from_book = not first_start_show
        first_start_show = false
        self:show()
    end
end

-- A book closing: the file browser that comes back opens the Ledger.
function Ledger:onCloseDocument()
    back_from_book = true
    exit_timer = Timing.start()
end

-- The Ledger is home when KOReader's "Start with" is "ledger" (like
-- Bookshelf's "bookshelf"): KOReader itself then starts in the file browser,
-- which the Ledger covers. What it was before is kept for turning it off.
function Ledger:homeOn()
    return G_reader_settings:readSetting("start_with") == "ledger"
end

function Ledger:setHome(on)
    local start_with = G_reader_settings:readSetting("start_with")
    if on and start_with ~= "ledger" then
        self.settings:saveSetting("start_with_before", start_with or "filemanager")
        G_reader_settings:saveSetting("start_with", "ledger")
    elseif not on and start_with == "ledger" then
        G_reader_settings:saveSetting("start_with", self.settings:readSetting("start_with_before") or "filemanager")
        self.settings:delSetting("start_with_before")
    end
    self.settings:delSetting("home")   -- (the old switch, before start_with)
    G_reader_settings:flush()
    self.settings:flush()
end

-- "Reading Ledger" in KOReader's own Settings > Start with menu, next to
-- file browser, history, ... (and Bookshelf's entry, which it patches the
-- same way). Patched once, on the class.
registerStartWith = function()
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or type(FMMenu) ~= "table" or type(FMMenu.getStartWithMenuTable) ~= "function" then return end
    if FMMenu._ledger_patched then return end
    FMMenu._ledger_patched = true
    local orig = FMMenu.getStartWithMenuTable
    FMMenu.getStartWithMenuTable = function(fm_menu, ...)
        local result = orig(fm_menu, ...)
        if type(result) ~= "table" or type(result.sub_item_table) ~= "table" then return result end
        for _i, item in ipairs(result.sub_item_table) do
            if item._ledger then return result end
        end
        table.insert(result.sub_item_table, {
            _ledger = true,
            text = _("reading ledger"),
            radio = true,
            checked_func = function() return G_reader_settings:readSetting("start_with") == "ledger" end,
            callback = function(touchmenu)
                local ledger = fm_menu.ui and fm_menu.ui.ledger
                if ledger then ledger:setHome(true) else G_reader_settings:saveSetting("start_with", "ledger") end
                if touchmenu and touchmenu.closeMenu then touchmenu:closeMenu() end
                if ledger then ledger:show() end
            end,
        })
        local orig_text = result.text_func
        result.text_func = function()
            if G_reader_settings:readSetting("start_with") == "ledger" then
                return _("Start with: reading ledger")
            end
            return orig_text and orig_text() or ""
        end
        return result
    end
end

function Ledger:toggleHome()
    self:setHome(not self:homeOn())
    self:redraw()
end

-- KOReader's reading statistics plugin, which the rival learns from.
function Ledger:statisticsOn()
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    return not disabled.statistics
end

function Ledger:enableStatistics()
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    disabled.statistics = nil
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    G_reader_settings:flush()
    UIManager:show(InfoMessage:new{ text = _("Reading statistics will be on after KOReader restarts."), timeout = 4 })
end

function Ledger:addToMainMenu(menu_items)
    menu_items.reading_ledger = {
        text = _("Reading Ledger"),
        -- with the other plugins, under Tools (in "main" it sat at the very
        -- bottom of the last tab, past Exit, where nobody looks)
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function Ledger:onShowLedger()
    self:show()
    return true
end

-- ---------------------------------------------------------------- Bookbridge, inside
-- Bookbridge stays its own plugin (it updates itself, and works without the
-- Ledger), but with the Ledger installed it lives inside it: its menu opens
-- from the Ledger (Settings > Books, Library > Find), and its entry in
-- KOReader's own menu is tucked away -- unless "In KOReader's menu too" is
-- switched on in that Bookbridge menu.
function Ledger:tuckBookbridge()
    local bb = self:bookbridge()
    if not bb or bb._ledger_menu then return end
    bb._ledger_menu = bb.addToMainMenu   -- (the real one, for the Ledger's own use)
    local ledger = self
    bb.addToMainMenu = function(b, menu_items)
        if ledger.settings:readSetting("bookbridge_in_ko_menu") then
            return b._ledger_menu(b, menu_items)
        end
    end
end

-- Bookbridge's menu. With nothing set up at all -- no book source (see
-- Bookbridge's Sources) and no server -- the two ways in are offered first.
function Ledger:openBookbridge()
    local bb = self:bookbridge()
    if not bb then return self:showBookbridgeMenu() end
    local has_server = bb.server_url and bb.server_url ~= ""
    local has_source = bb.sourcesConfigured and bb:sourcesConfigured()
    if has_server or has_source or not bb.connectServer then
        return self:showBookbridgeMenu()
    end
    -- Bookbridge's own first screen (v0.8+): the no-server path first
    if bb.showStartHere then return bb:showStartHere() end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        title = _("Bookbridge finds books for you. Start with a source -- the Z-Library plugin, an Anna's Archive key -- or connect a book server."),
        buttons = {
            { { text = _("Open Bookbridge (sources, settings)"), callback = function() UIManager:close(dlg); self:showBookbridgeMenu() end } },
            { { text = _("Connect a book server"), callback = function()
                UIManager:close(dlg)
                local Trapper = require("ui/trapper")
                Trapper:wrap(function() bb:connectServer() end)
            end } },
            { { text = _("Close"), callback = function() UIManager:close(dlg) end } },
        },
    }
    UIManager:show(dlg)
end

-- Bookbridge's whole menu, in KOReader's own menu widget, from the Ledger.
function Ledger:showBookbridgeMenu()
    local bb = self:bookbridge()
    if not bb then
        UIManager:show(InfoMessage:new{ text = _("Bookbridge isn't installed. It comes in the same download as the Reading Ledger."), timeout = 4 })
        return
    end
    local items = {}
    local ok, err = pcall(bb._ledger_menu or bb.addToMainMenu, bb, items)
    if not ok or not items.bookbridge then
        logger.warn("ledger: Bookbridge menu:", err)
        return
    end
    local sub = items.bookbridge.sub_item_table
    if type(sub) ~= "table" and items.bookbridge.sub_item_table_func then sub = items.bookbridge.sub_item_table_func() end
    sub = sub or {}
    -- and one of the Ledger's own, last: whether it also shows in KOReader's menu
    local tab = { icon = "appbar.tools" }
    for _, it in ipairs(sub) do tab[#tab + 1] = it end
    tab[#tab + 1] = {
        text = _("In KOReader's menu too"),
        checked_func = function() return self.settings:readSetting("bookbridge_in_ko_menu") and true or false end,
        callback = function()
            self.settings:saveSetting("bookbridge_in_ko_menu", not self.settings:readSetting("bookbridge_in_ko_menu") or nil)
            self.settings:flush()
            -- KOReader builds its menu once per session and can't rebuild it
            -- (MenuSorter consumes the item table): a restart it is
            UIManager:askForRestart()
        end,
        help_text = _("Bookbridge lives in the Reading Ledger (Settings > Books). Switch this on to also have it in KOReader's own menu."),
    }
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local container = CenterContainer:new{ ignore = "height", dimen = Device.screen:getSize() }
    local menu = TouchMenu:new{
        width = Device.screen:getWidth(),
        tab_item_table = { tab },
        show_parent = container,
    }
    menu.close_callback = function() UIManager:close(container) end
    container[1] = menu
    UIManager:show(container)
end

-- Bookbridge's search and request, from the Ledger.
function Ledger:findBook()
    local bb = self:bookbridge()
    if bb and bb.startSearch then return bb:startSearch() end
    self:showBookbridgeMenu()
end

-- ---------------------------------------------------------------- sources
function Ledger:bookbridge()
    local bb = self.ui and self.ui.bookbridge
    return (type(bb) == "table") and bb or nil
end

function Ledger:hardcoverToken()
    local own = self.settings:readSetting("hardcover_token")
    if own and own ~= "" then return own end
    local bb = self:bookbridge()
    if bb and bb.hardcover_token and bb.hardcover_token ~= "" then return bb.hardcover_token end
    return nil
end

function Ledger:collect()
    local t = Timing.start()
    self:flushStats()
    Timing.lap(t, "collect.flushStats")
    self.race_model = nil   -- (today's pages may have changed)
    local bb = self:bookbridge()
    local data = Data.collect(self.ui, { download_dir = bb and bb.download_dir }, t)
    Timing.lap(t, "collect.data")
    -- books moved on in Readest since the last look were read elsewhere
    local recs = {}
    for _, rec in ipairs(data.history or {}) do recs[#recs + 1] = rec end
    if data.lead and not data.lead.last_open then recs[#recs + 1] = data.lead end
    for _, rec in ipairs(data.reading or {}) do if not rec.last_open then recs[#recs + 1] = rec end end
    Readest.observe(self.settings, recs)
    Timing.lap(t, "collect.observe")
    -- (finished books' results are worked out from the statistics when
    -- asked for: Ledger:raceResults)
    return data
end

-- ---------------------------------------------------------------- showing
-- Three pages, one on screen at a time: Reading (the main one), Library and
-- Settings, switched by the tab bar at the bottom. The book page opens on
-- top of whichever is showing.
function Ledger:show()
    local t = exit_timer or Timing.start()
    exit_timer = nil
    Timing.lap(t, "show.start (from book close)")
    UIManager:nextTick(function() Timing.lap(t, "show.drawn") end)
    if not self.settings:readSetting("onboarded") then
        local Onboard = require("ledger_onboard")
        UIManager:show(Onboard:new{ plugin = self })
        return
    end
    self.cache = Data.loadCache()
    self.race_model = nil   -- relearn your habits each time the Ledger opens
    self:showTab("reading")
    self:refreshRemote(false)
    -- ask Readest for reading done on other devices; redraw when it lands
    -- (not on the way back from a book: Readest syncs that book itself as it
    -- closes, so a pull here would only spend Wi-Fi and battery)
    if not self._from_book then Readest.refresh(self.ui, function()
        self.race_model = nil
        self:redraw()
    end, self:bookbridge()) end
    self._from_book = false
end

function Ledger:libraryDirs()
    local bb = self:bookbridge()
    local dirs = { G_reader_settings:readSetting("home_dir") }
    if bb and bb.download_dir and bb.download_dir ~= dirs[1] then dirs[#dirs + 1] = bb.download_dir end
    return dirs
end

function Ledger:showTab(id, opts)
    opts = opts or {}
    self.cache = self.cache or Data.loadCache()
    local old = self.page
    local page
    if id == "library" then
        local books = Data.library(self:libraryDirs(), Data.readestPositions(self.ui), Data.hardcoverMatches())
        for _, rec in ipairs(books) do rec.result = self:raceResult(rec) end
        page = Library:new{ plugin = self, books = books, filter = opts.filter or "all" }
    elseif id == "settings" then
        page = Settings:new{ plugin = self }
    else
        id = "reading"
        local t = Timing.start()
        local data = self:collect()
        Timing.lap(t, "reading.collect")
        self:raceModel()
        Timing.lap(t, "reading.raceModel")
        page = Reading:new{ plugin = self, data = data, cache = self.cache }
        Timing.lap(t, "reading.build")
        self:fetchCovers(data)
        Timing.lap(t, "reading.fetchCovers")
    end
    self.page, self.tab = page, id
    -- (one full flash the first time; after that, coming back from a book
    -- or switching tabs, a plain update: no black flash)
    UIManager:show(page, self._shown_once and "ui" or "flashui")
    self._shown_once = true
    if old and UIManager:isWidgetShown(old) then UIManager:close(old) end
    if id == "library" then
        self:fetchCoversFor(page:visible(), function() page:refreshCovers() end)
    elseif id == "reading" and page.chase then
        self:runInIfMoved(page)
    end
end

-- Remote data or covers changed: redraw whatever page is showing.
-- Play the runners' run-in only when one of them moved since this book's
-- race was last on screen (each frame is an e-ink update).
function Ledger:runInIfMoved(page)
    local chase = page.chase
    local rec = page.books and page.books[page.index]
    if not (chase and rec) then return end
    local key = rec.hash or rec.file
    local last = shown_positions[key]
    shown_positions[key] = { you = chase.you_pct or 0, rival = chase.rival_pct or 0 }
    if last and math.abs(last.you - (chase.you_pct or 0)) < 0.002 and math.abs(last.rival - (chase.rival_pct or 0)) < 0.002 then
        return
    end
    chase:runIn()
end

function Ledger:redraw()
    local page = self.page
    if not (page and UIManager:isWidgetShown(page)) then return end
    if self.tab == "reading" then
        page:update(self:collect(), self.cache)
    elseif self.tab == "library" then
        page:refreshCovers()
    else
        page:update()
    end
end

function Ledger:closeAll()
    -- (not ipairs over the widgets: it stops at the first nil)
    if self.book_page and UIManager:isWidgetShown(self.book_page) then UIManager:close(self.book_page) end
    if self.page and UIManager:isWidgetShown(self.page) then UIManager:close(self.page) end
    self.book_page, self.page, self.tab = nil, nil, nil
    UI.freeSprites()
end

function Ledger:showBook(rec)
    if self.book_page and UIManager:isWidgetShown(self.book_page) then UIManager:close(self.book_page) end
    self.book_page = Book:new{ plugin = self, rec = rec }
    UIManager:show(self.book_page, "flashui")
    self:fetchCovers({ just_in = { rec } })
    local token = self:hardcoverToken()
    if token and rec.hardcover_id and NetworkMgr:isOnline() then
        local page = self.book_page
        Bg.run(function() return Net.hardcoverUserBook(token, rec.hardcover_id) end, function(ok, hc)
            if ok and type(hc) == "table" and page and UIManager:isWidgetShown(page) then page:update(hc) end
        end, 30)
    end
end

-- The whole description, from the Currently reading page.
function Ledger:showDescription(rec, text)
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{ title = rec.title, text = text })
end

-- KOReader's cover cache extracts covers in the background; ask for the
-- ones we're about to show and call back once they're in.
function Ledger:fetchCoversFor(recs, on_done)
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok or not BIM then return end
    local files = {}
    local W = Device.screen:getWidth()
    for _, rec in pairs(recs) do
        if rec and rec.file then
            local iok, info = pcall(BIM.getBookInfo, BIM, rec.file, false)
            if not (iok and info and info.cover_fetched) then
                files[#files + 1] = { filepath = rec.file, cover_specs = { max_cover_w = W, max_cover_h = W * 1.5 } }
            end
        end
    end
    if #files == 0 then return end
    pcall(BIM.extractInBackground, BIM, files)
    -- one extra second per book, capped: the extractor works through them in order
    UIManager:scheduleIn(math.min(20, 4 + #files), function() if on_done then on_done() end end)
end

function Ledger:fetchCovers(data)
    local list = { data.lead }
    for _, r in ipairs(data.reading or {}) do list[#list + 1] = r end
    for _, r in ipairs(data.just_in or {}) do list[#list + 1] = r end
    self:fetchCoversFor(list, function()
        if self.book_page and UIManager:isWidgetShown(self.book_page) then
            self.book_page:update(self.book_page.hc)
        end
        self:redraw()
    end)
end

function Ledger:showLibrary() self:showTab("library") end

-- Out to KOReader's own file browser (folders, file operations).
function Ledger:openFiles()
    self:closeAll()
end

-- ---------------------------------------------------------------- settings
-- What the rival knows about your reading (ledger_race.lua), learned from
-- KOReader's statistics once per showing; finished days are settled (and
-- the rival tuned) on the way.
function Ledger:raceModel()
    if not self.race_model then
        -- the race is rebuilt from the statistics on every device alike
        -- (ledger_race.lua, "the replay"); this is today's model, with the
        -- whole timeline on it
        local T = Race.timeline(Data.allHabits(), self:rival())
        self.race_model = setmetatable({ timeline = T }, { __index = T.model(T.today) })
        self.display_habits = nil
    end
    return self.race_model
end

-- Every finished book's race (any device's), and how many you won.
-- Worked out once per new batch of statistics.
function Ledger:raceResults()
    local T = self:raceModel().timeline
    local key = tostring(T.habits and T.habits.fp) .. "|" .. tostring(T.rival) .. "|" .. T.today
    if not self._results or self._results.key ~= key then
        local won, lost, list = Race.tally(T, Data.finishedTurns())
        local by_hash = {}
        for _, r in ipairs(list) do if r.hash then by_hash[r.hash] = r end end
        self._results = { key = key, won = won, lost = lost, list = list, by_hash = by_hash }
    end
    return self._results
end

function Ledger:raceResult(rec)
    return rec and rec.hash and self:raceResults().by_hash[rec.hash] or nil
end

-- Your reading by day for the counts on the front page: this device's
-- statistics with reading done in Readest folded in (display only; the
-- race itself uses the synced statistics alone).
function Ledger:displayHabits()
    if not self.display_habits then
        self.display_habits = Readest.mergeHabits(Data.readingHabits(), self.settings) or { days = {} }
    end
    return self.display_habits
end

-- Pages read today, in the last 7 days, and the streak of days with reading:
-- this device (the larger of its statistics and how far books moved) plus
-- Readest elsewhere.
function Ledger:readingCounts()
    local days = self:displayHabits().days or {}
    local now = os.time()
    local today = os.date("%Y-%m-%d", now)
    local week = 0
    for i = 0, 6 do week = week + (days[os.date("%Y-%m-%d", now - i * 86400)] or 0) end
    local streak, i = 0, (days[today] or 0) > 0 and 0 or 1
    while i < 60 and (days[os.date("%Y-%m-%d", now - i * 86400)] or 0) > 0 do
        streak = streak + 1
        i = i + 1
    end
    return days[today] or 0, week, streak
end

-- Pages read in Readest (on other devices) today, and in the last 7 days.
function Ledger:readestPages()
    local today = os.date("%Y-%m-%d")
    return Readest.pagesSince(self.settings, today),
        Readest.pagesSince(self.settings, os.date("%Y-%m-%d", os.time() - 6 * 86400))
end

-- A line for "What the rival has learned" about reading done in Readest.
function Ledger:readestSummary()
    local month = Readest.pagesSince(self.settings, os.date("%Y-%m-%d", os.time() - 29 * 86400))
    if month > 0 then
        return string.format("\n\n%d pages in the last 30 days were read in Readest on your other devices; they count too.", month)
    end
    if Readest.plugin(self.ui) then
        return "\n\nReading you do in Readest on your other devices counts too."
    end
    return ""
end

function Ledger:showHabits()
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = string.format(_("What %s has learned"), self:petName(self:rival())),
        text = Race.summary(self, self:raceModel()) .. self:readestSummary(),
    })
end

-- Your runner and your rival (animal ids from ledger_race.lua); never the same.
function Ledger:runner()
    return Race.animal(self.settings:readSetting("runner") or "cat").id
end

function Ledger:rival()
    local r = Race.animal(self.settings:readSetting("rival") or "dog").id
    if r == self:runner() then r = self:runner() == "dog" and "cat" or "dog" end
    return r
end

-- Each animal keeps its own name (cat_name, dog_name, ...).
function Ledger:petName(animal)
    local n = self.settings:readSetting(animal .. "_name")
    return (n and n ~= "") and n or Race.animal(animal).name
end

function Ledger:editPetName(animal)
    local dialog
    dialog = InputDialog:new{
        title = string.format(_("The %s's name"), Race.animal(animal).label:lower()),
        input = self:petName(animal),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog)
                self.settings:saveSetting(animal .. "_name", name ~= "" and name or nil)
                self.settings:flush()
                self:redraw()
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Pick your runner ("runner") or your rival ("rival"), or rename the
-- current one. A rival picked as your runner swaps places with you.
function Ledger:chooseAnimal(which)
    local ButtonDialog = require("ui/widget/buttondialog")
    local current = which == "runner" and self:runner() or self:rival()
    local other = which == "runner" and self:rival() or self:runner()
    local dialog
    local buttons = {}
    for _, a in ipairs(Race.ANIMALS) do
        local text = a.label .. " · " .. self:petName(a.id)
        if which == "rival" then text = text .. " -- " .. a.hint:lower() end
        if a.id == current then text = "✓ " .. text end
        buttons[#buttons + 1] = { { text = text, align = "left", callback = function()
            UIManager:close(dialog)
            if a.id == other then self.settings:saveSetting(which == "runner" and "rival" or "runner", current) end
            self.settings:saveSetting(which, a.id)
            self.settings:flush()
            self:redraw()
        end } }
    end
    buttons[#buttons + 1] = { { text = string.format(_("Rename %s"), self:petName(current)), callback = function()
        UIManager:close(dialog)
        self:editPetName(current)
    end } }
    dialog = ButtonDialog:new{
        title = which == "runner" and _("You run as") or _("Your rival"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- How the race looks (ledger_chase.lua: Chase.STYLES).
function Ledger:raceStyle()
    return self.settings:readSetting("race_style") or "field"
end

function Ledger:chooseRaceStyle()
    local Chase = require("ledger_chase")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local buttons = {}
    for _, st in ipairs(Chase.STYLES) do
        buttons[#buttons + 1] = { { text = (st.id == self:raceStyle() and "✓ " or "") .. st.label, align = "left",
            callback = function()
                UIManager:close(dlg)
                self.settings:saveSetting("race_style", st.id)
                self.settings:flush()
                self:redraw()
            end } }
    end
    dlg = ButtonDialog:new{ title = _("The race's look"), buttons = buttons }
    UIManager:show(dlg)
end

function Ledger:animationsOn()
    return self.settings:readSetting("animations") ~= false
end

function Ledger:toggleAnimations()
    self.settings:saveSetting("animations", not self:animationsOn())
    self.settings:flush()
    self:redraw()
end

-- What each source looks like, for the Settings page.
function Ledger:sourceStatus()
    local c = self.cache or {}
    local out = {}
    if c.hardcover and c.hardcover.username then
        out.hardcover = string.upper(c.hardcover.username)
        out.hardcover_hint = "Signed in -- shelves and yearly goal"
    elseif self:hardcoverToken() then
        out.hardcover = c.hardcover_rejected and "KEY REFUSED" or "KEY SET"
        out.hardcover_hint = c.hardcover_rejected and "Hardcover didn't accept the key" or "Checking on the next refresh"
    else
        out.hardcover = "ADD KEY"
        out.hardcover_hint = "For your yearly goal, paid in fish"
    end
    local rs = G_reader_settings:readSetting("readest_sync")
    if type(rs) == "table" and rs.access_token and rs.user_id then out.readest = "SIGNED IN"
    elseif self.ui and self.ui.readest then out.readest = "NOT SIGNED IN"
    else out.readest = "NOT INSTALLED" end
    local bb = self:bookbridge()
    -- a connected server or a working book source both count
    local ready = bb and ((bb.server_url and bb.server_url ~= "") or (bb.sourcesConfigured and bb:sourcesConfigured()))
    out.bookbridge = bb and (ready and "CONNECTED" or "NOT SET UP") or "NOT INSTALLED"
    -- the two book sources on their own (Bookbridge v0.8.1+ tells; older
    -- builds: through the Bookbridge row)
    if bb and bb.zlibraryState then
        local z = bb:zlibraryState()
        out.zlibrary = string.upper(z.label)
        out.zlibrary_hint = (not z.installed and "Tap to install its plugin -- search needs no account")
            or (not z.loaded and "Tap to restart KOReader")
            or (z.signed_in and "Search and download with your account")
            or "Search works now; tap to sign in for downloads"
    end
    if bb and bb.annasState then
        local a = bb:annasState()
        out.annas = string.upper(a.label)
        out.annas_hint = (not a.set and "Tap to enter your member key -- it downloads directly")
            or (a.state == "token" and "Anna's Archive didn't accept the key -- tap to change it")
            or "Direct search and downloads with your key"
    end
    return out
end

-- Where books come from, in one place: the two sources and Bookbridge itself,
-- each with its state and the one tap that sets it up (Bookbridge does the
-- work; an older Bookbridge without the state helpers gets its menu).
function Ledger:showBooksSetup()
    local bb = self:bookbridge()
    if not bb then return self:showBookbridgeMenu() end
    local st = self:sourceStatus()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local function pick(fn) return function() UIManager:close(dlg); fn() end end
    local buttons = {}
    if st.zlibrary then
        buttons[#buttons + 1] = { { text = _("Z-Library") .. " -- " .. st.zlibrary:lower(), callback = pick(function()
            bb:zlibrarySignIn(function() self:show() end)
        end) } }
    end
    if st.annas then
        buttons[#buttons + 1] = { { text = _("Anna's Archive") .. " -- " .. st.annas:lower(), callback = pick(function()
            if bb.editAnnasSettings then bb:editAnnasSettings() end
        end) } }
    end
    if bb.syncNow then
        -- your devices in step through Readest (Bookbridge 0.9+)
        buttons[#buttons + 1] = { { text = _("Sync now with my other devices"), callback = pick(function() bb:syncNow("manual", true) end) } }
        buttons[#buttons + 1] = { { text = _("Cloud library: every book in Readest"), callback = pick(function()
            UIManager:broadcastEvent(require("ui/event"):new("ReadestOpenLibrary"))
        end) } }
    end
    buttons[#buttons + 1] = { { text = _("Bookbridge: search, requests, sync, settings"),
        callback = pick(function() self:openBookbridge() end) } }
    buttons[#buttons + 1] = { { text = _("Close"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{
        title = ((st.zlibrary and st.zlibrary_hint or st.annas and st.annas_hint)
            and _("Where books come from. Tap a line to set it up or change it.")
            or _("Books come through Bookbridge."))
            .. ((bb.readest_last_sync and bb.readest_last_sync > 0)
                and ("\n" .. _("Last in step with your other devices: ") .. os.date("%H:%M", bb.readest_last_sync)) or ""),
        buttons = buttons,
    }
    UIManager:show(dlg)
end

function Ledger:showAbout()
    local TextViewer = require("ui/widget/textviewer")
    local ok, meta = pcall(dofile, tostring(self.path) .. "/_meta.lua")
    local version = ok and type(meta) == "table" and meta.version or "?"
    -- updates come through Bookbridge, which installs the Ledger like its
    -- other companions (verified, with the previous version kept)
    local bb = self:bookbridge()
    local can_update = bb and bb.installCompanion and bb.companionState
        and pcall(function() return bb:companionState("ledger") end)
    local viewer
    viewer = TextViewer:new{
        title = _("Reading Ledger") .. " v" .. tostring(version),
        buttons_table = { {
            { text = _("Close"), callback = function() UIManager:close(viewer) end },
            -- Hardcover, the trending shelf and requests refresh on their
            -- own; this is for "now"
            { text = _("Refresh now"), callback = function()
                UIManager:close(viewer)
                self:refreshRemote(true)
            end },
            { text = _("Check for updates"), enabled = can_update and true or false, callback = function()
                UIManager:close(viewer)
                local Trapper = require("ui/trapper")
                Trapper:wrap(function() bb:installCompanion("ledger") end)
            end },
        } },
        text = table.concat({
            "Every book is a race against a rival that reads a little more than you usually do; a fish waits at the finish. Your place is the furthest of this device and Readest.",
            "",
            "Sprites from OpenGameArt.org, all public domain (CC0): cat by Shepardskin, dog by Jason of GDN, rabbit by Scratchio, tortoise by Sogomn.",
            "Fonts: Silkscreen and Atkinson Hyperlegible (SIL Open Font License).",
            "Trending books from Open Library.",
            "",
            "Written 100% by an AI (Claude, by Anthropic), directed by Matt.",
        }, "\n"),
    }
    UIManager:show(viewer)
end

-- ---------------------------------------------------------------- remote data
function Ledger:refreshRemote(force)
    if not NetworkMgr:isOnline() then return end
    local c = self.cache or {}
    if not force and c.fetched_at and os.time() - c.fetched_at < REFRESH_EVERY then return end
    if self._refreshing then return end
    self._refreshing = true

    local token = self:hardcoverToken()
    local covers_dir = Data.coversDir()
    local fetch_trending = force or not (c.trending and #c.trending > 0)
        or os.time() - (c.trending_at or 0) >= TRENDING_EVERY
    Bg.run(function()
        local out = {}
        if token then
            local front, err = Net.hardcoverFront(token)
            out.hardcover, out.hardcover_err = front, err
            -- the Library's Want to Read shelf
            if front then out.want = Net.hardcoverWant(token, 12, covers_dir) end
        end
        -- the Library's trending shelf, with or without a Hardcover key:
        -- once a day is plenty for a weekly list
        if fetch_trending then out.trending = Net.openLibraryTrending("weekly", 12, covers_dir) end
        return out
    end, function(ok, out)
        self._refreshing = false
        if not ok or type(out) ~= "table" then return end
        local cache = self.cache or {}
        if out.hardcover then cache.hardcover = out.hardcover elseif token == nil then cache.hardcover = nil end
        if out.hardcover_err == "rejected" then cache.hardcover = nil; cache.hardcover_rejected = true end
        if out.want then cache.want = out.want end
        if token == nil then cache.want = nil end
        if out.trending and #out.trending > 0 then
            cache.trending, cache.trending_at = out.trending, os.time()
        end
        cache.fetched_at = os.time()
        self.cache = cache
        self:refreshRequests()
        Data.saveCache(cache)
        self:redraw()
    end, 60)
end

-- The trending shelf: fetch it now if it's missing or more than a day old.
function Ledger:refreshTrending()
    local c = self.cache or {}
    if c.trending and #c.trending > 0 and os.time() - (c.trending_at or 0) < 86400 then return end
    self:refreshRemote(true)
end

-- A book on one of the Library's outside shelves (Trending, Want to Read,
-- Requested): open it if it's on the device, else say what it is and offer
-- to request it.
function Ledger:showShelfBook(rec)
    if rec.on_device then return self:openBook(rec.on_device) end
    if rec.requested then
        UIManager:show(InfoMessage:new{
            text = (rec.title or "?") .. (rec.author and ("\n" .. rec.author) or "") .. "\n\n"
                .. _("Requested through Bookbridge; it hasn't arrived yet. It shows up under New when it does."),
            timeout = 5,
        })
        return
    end
    return self:showTrending(rec)
end

-- Every finished race: won or lost, and by how much.
function Ledger:showResults()
    local list = self:raceResults().list
    local lines = {}
    local won, lost = 0, 0
    for _, res in ipairs(list) do
        if res.won then won = won + 1 else lost = lost + 1 end
        local who = self:petName(res.rival or self:rival())
        lines[#lines + 1] = string.format("%s  %s\n   %s%s", res.won and "WON " or "LOST", res.title or "?",
            res.won and string.format("beat %s by %d %s", who, res.by or 0, (res.by or 0) == 1 and "page" or "pages")
                or string.format("%s got to the flag first", who),
            res.at and (" · " .. os.date("%d %b %Y", res.at)) or "")
    end
    local text
    if #list == 0 then
        text = _("No finished races yet. Finish a book you're racing and its result lands here.")
    else
        text = string.format(_("%d won, %d lost."), won, lost) .. "\n\n" .. table.concat(lines, "\n\n")
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{ title = _("Race results"), text = text })
end

-- A trending book: open it if it's on the device, else offer to request it.
function Ledger:showTrending(rec)
    if rec.on_device then return self:showBook(rec.on_device) end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local text = rec.title .. (rec.author and ("\n" .. rec.author) or "") .. (rec.year and (" · " .. rec.year) or "")
    local buttons = {}
    local bb = self:bookbridge()
    if bb then
        -- a server: ask Shelfmark (request); sources only: fetch it now;
        -- nothing set up yet: Bookbridge's first screen
        local via_server = bb.server_url and bb.server_url ~= ""
        local ready = via_server or (bb.sourcesConfigured and bb:sourcesConfigured())
        if ready then
            buttons[#buttons + 1] = { { text = via_server and _("Request it with Bookbridge") or _("Get it with Bookbridge"), callback = function()
                UIManager:close(dlg)
                self:requestBook(rec.title, rec.author)
            end } }
        else
            buttons[#buttons + 1] = { { text = _("Set up Bookbridge to get it"), callback = function()
                UIManager:close(dlg)
                self:openBookbridge()
            end } }
        end
    end
    buttons[#buttons + 1] = { { text = _("Close"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{
        title = text .. "\n\n" .. (rec.source or _("Trending on Open Library this week."))
            .. (self:bookbridge() and "" or (" " .. _("With the Bookbridge plugin you can request it from here."))),
        buttons = buttons,
    }
    UIManager:show(dlg)
end

-- Books you asked Shelfmark for that haven't arrived: Bookbridge's requests.
function Ledger:refreshRequests()
    local bb = self:bookbridge()
    if not bb or not bb.server_url or bb.server_url == "" then return end
    if bb.shelfmarkLoginKnownBad and bb:shelfmarkLoginKnownBad() then return end
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local resp, code = bb:apiRequest("GET", "/api/requests", nil, false, 10, 20)
        if code ~= 200 or type(resp) ~= "table" then return end
        local list = resp.requests or resp
        if type(list) ~= "table" then return end
        local waiting = {}
        for _, r in ipairs(list) do
            if type(r) == "table" and r.delivery_state ~= "complete" then
                local bd = type(r.book_data) == "table" and r.book_data or {}
                waiting[#waiting + 1] = {
                    title = type(r.title) == "string" and r.title or bd.title or "?",
                    author = type(bd.author) == "string" and bd.author or nil,
                    note = "requested, not found yet",
                }
            end
        end
        self.cache.requests = waiting
        Data.saveCache(self.cache)
        self:redraw()
    end)
end

-- ---------------------------------------------------------------- actions
function Ledger:openBook(rec)
    if not rec or not rec.file then return end
    self:closeAll()
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(rec.file)
end

-- Open the book, then let Readest move it forward to where you are on your
-- other device (Readest only ever jumps forward).
function Ledger:continueFromReadest(rec)
    pending_readest_jump = rec.file
    self:openBook(rec)
end

function Ledger:onReaderReady()
    local doc = self.ui and self.ui.document
    if pending_readest_jump and doc and doc.file == pending_readest_jump then
        pending_readest_jump = nil
        local rs = self.ui.readest
        if rs and rs.scheduleBackgroundPull then
            rs:scheduleBackgroundPull(0)
        end
    end
end

function Ledger:openLibrary()
    self:showTab("library")
end

function Ledger:search()
    local bb = self:bookbridge()
    if bb and bb.startSearch then
        bb:startSearch()
    else
        UIManager:show(InfoMessage:new{ text = _("Searching for new books needs the Bookbridge plugin."), timeout = 3 })
    end
end

function Ledger:requestBook(title, author)
    local bb = self:bookbridge()
    if bb and bb.doSearch then
        -- same calls (and Trapper context) as Bookbridge's own search dialog:
        -- Shelfmark's search with a server, the sources directly without;
        -- neither set up: Bookbridge's first screen instead of an empty search
        local via_server = bb.server_url and bb.server_url ~= ""
        if not via_server and bb.sourcesConfigured and not bb:sourcesConfigured() then
            return self:openBookbridge()
        end
        local Trapper = require("ui/trapper")
        if via_server then
            Trapper:wrap(function() bb:doSearch({ query = title, author = author, page = 1 }) end)
        elseif bb.getBook then
            Trapper:wrap(function() bb:getBook(title, author) end)
        else
            Trapper:wrap(function() bb:doSearch({ query = title, author = author, page = 1 }) end)
        end
    else
        UIManager:show(InfoMessage:new{
            text = title .. (author and ("\n" .. author) or "") .. "\n\n" .. _("Requesting books needs the Bookbridge plugin."),
            timeout = 4,
        })
    end
end

function Ledger:showRequest(r)
    UIManager:show(InfoMessage:new{
        text = (r.title or "?") .. "\n\n" .. _("Requested. It shows up under new books when it arrives."),
        timeout = 4,
    })
end

function Ledger:editHardcoverKey()
    local dialog
    local rows = { {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
        { text = _("Save"), is_enter_default = true, callback = function()
            local key = dialog:getInputText():gsub("%s+", "")
            UIManager:close(dialog)
            self.settings:saveSetting("hardcover_token", key ~= "" and key or nil)
            self.settings:flush()
            self.cache = self.cache or {}
            self.cache.hardcover_rejected = nil
            self:refreshRemote(true)
        end },
    } }
    -- (with Bookbridge here: paste the key on a phone instead of typing it)
    local bb = self:bookbridge()
    if bb and bb.phoneButtonRow then table.insert(rows, 1, bb:phoneButtonRow()) end
    dialog = InputDialog:new{
        title = _("Hardcover API key"),
        description = _("From hardcover.app/account/api. Your shelves, lists and yearly goal appear on the front page."),
        input = self.settings:readSetting("hardcover_token") or "",
        buttons = rows,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Ledger:showMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        title = _("Reading Ledger"),
        buttons = {
            { { text = _("Refresh now"), callback = function() UIManager:close(dlg); self:refreshRemote(true) end } },
            { { text = _("Hardcover key"), callback = function() UIManager:close(dlg); self:editHardcoverKey() end } },
            { { text = _("Close the Ledger"), callback = function() UIManager:close(dlg); self:closeAll() end } },
        },
    }
    UIManager:show(dlg)
end

function Ledger:onCloseWidget()
    self.settings:flushNow()
    -- the plugin instance belongs to a FileManager or ReaderUI that is going away
    if self.page and UIManager:isWidgetShown(self.page) then UIManager:close(self.page) end
    if self.book_page and UIManager:isWidgetShown(self.book_page) then UIManager:close(self.book_page) end
end

return Ledger
