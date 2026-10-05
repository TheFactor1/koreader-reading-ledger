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
local UI = require("ledger_ui")

local REFRESH_EVERY = 30 * 60   -- remote data older than this is refreshed on show

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
local registerStartWith   -- (below, with the home screen)
local back_from_book = false

local Ledger = WidgetContainer:extend{
    name = "ledger",
    is_doc_only = false,
}

function Ledger:init()
    UI.setPluginDir(self.path)
    shared_settings = shared_settings or LuaSettings:open(DataStorage:getSettingsDir() .. "/ledger.lua")
    self.settings = shared_settings
    Dispatcher:registerAction("ledger_show", {
        category = "none", event = "ShowLedger", title = _("Reading Ledger"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    registerStartWith()
    -- (the old "home" switch becomes start_with = "ledger")
    if self.settings:readSetting("home") == true and not self:homeOn() then self:setHome(true) end
    if not self.ui.document then
        -- the file browser: show the Ledger on top when it's the home screen
        local show_now = (first_start or back_from_book) and self:homeOn()
        first_start, back_from_book = false, false
        if show_now then
            UIManager:nextTick(function()
                if self.ui and not self.ui.tearing_down and not (self.page and UIManager:isWidgetShown(self.page)) then
                    self:show()
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

-- A book closing: the file browser that comes back opens the Ledger.
function Ledger:onCloseDocument()
    back_from_book = true
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
    self:flushStats()
    local bb = self:bookbridge()
    local data = Data.collect(self.ui, { download_dir = bb and bb.download_dir })
    data.pages_today = Data.pagesToday()
    -- books moved on in Readest since the last look were read elsewhere
    local recs = {}
    for _, rec in ipairs(data.history or {}) do recs[#recs + 1] = rec end
    if data.lead and not data.lead.last_open then recs[#recs + 1] = data.lead end
    for _, rec in ipairs(data.reading or {}) do if not rec.last_open then recs[#recs + 1] = rec end end
    Readest.observe(self.settings, recs)
    -- books finished since the last look get their race result
    for _, rec in ipairs(data.history or {}) do
        if Data.isFinished(rec) and not Race.result(self.settings, rec) then
            local races = self.settings:readSetting("races") or {}
            if races[rec.hash or rec.file or ""] then
                Race.finish(rec, Data.readingStats(rec.hash), self.settings, self:rival(), self:raceModel())
            end
        end
    end
    return data
end

-- ---------------------------------------------------------------- showing
-- Three pages, one on screen at a time: Reading (the main one), Library and
-- Settings, switched by the tab bar at the bottom. The book page opens on
-- top of whichever is showing.
function Ledger:show()
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
    Readest.refresh(self.ui, function()
        self.race_model = nil
        self:redraw()
    end)
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
        for _, rec in ipairs(books) do rec.result = Race.result(self.settings, rec) end
        page = Library:new{ plugin = self, books = books, filter = opts.filter or "all" }
    elseif id == "settings" then
        page = Settings:new{ plugin = self }
    else
        id = "reading"
        local data = self:collect()
        page = Reading:new{ plugin = self, data = data, cache = self.cache }
        self:fetchCovers(data)
    end
    self.page, self.tab = page, id
    UIManager:show(page, old and "partial" or "flashui")
    if old and UIManager:isWidgetShown(old) then UIManager:close(old) end
    if id == "library" then
        self:fetchCoversFor(page:visible(), function() page:refreshCovers() end)
    elseif id == "reading" and page.chase then
        page.chase:runIn()
    end
end

-- Remote data or covers changed: redraw whatever page is showing.
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
        -- this device's statistics, with reading done in Readest folded in
        self.race_model = Race.model(Readest.mergeHabits(Data.readingHabits(), self.settings))
        Race.settle(self.settings, self.race_model, self:rival())
    end
    return self.race_model
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
    out.bookbridge = bb and (bb.server_url and bb.server_url ~= "" and "CONNECTED" or "NOT SET UP") or "NOT INSTALLED"
    return out
end

function Ledger:showAbout()
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Reading Ledger"),
        text = table.concat({
            "Every book is a race against a rival that reads a little more than you usually do; a fish waits at the finish. Your place is the furthest of this device and Readest.",
            "",
            "Sprites from OpenGameArt.org, all public domain (CC0): cat by Shepardskin, dog by Jason of GDN, rabbit by Scratchio, tortoise by Sogomn.",
            "Fonts: Silkscreen and Atkinson Hyperlegible (SIL Open Font License).",
            "Trending books from Open Library.",
            "",
            "Written 100% by an AI (Claude, by Anthropic), directed by Matt.",
        }, "\n"),
    })
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
    Bg.run(function()
        local out = {}
        if token then
            local front, err = Net.hardcoverFront(token)
            out.hardcover, out.hardcover_err = front, err
        end
        -- the Library's trending shelf, with or without a Hardcover key
        out.trending = Net.openLibraryTrending("weekly", 12, covers_dir)
        return out
    end, function(ok, out)
        self._refreshing = false
        if not ok or type(out) ~= "table" then return end
        local cache = self.cache or {}
        if out.hardcover then cache.hardcover = out.hardcover elseif token == nil then cache.hardcover = nil end
        if out.hardcover_err == "rejected" then cache.hardcover = nil; cache.hardcover_rejected = true end
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

-- A trending book: open it if it's on the device, else offer to request it.
function Ledger:showTrending(rec)
    if rec.on_device then return self:showBook(rec.on_device) end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local text = rec.title .. (rec.author and ("\n" .. rec.author) or "") .. (rec.year and (" · " .. rec.year) or "")
    local buttons = {}
    if self:bookbridge() then
        buttons[#buttons + 1] = { { text = _("Request it with Bookbridge"), callback = function()
            UIManager:close(dlg)
            self:requestBook(rec.title, rec.author)
        end } }
    end
    buttons[#buttons + 1] = { { text = _("Close"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{
        title = text .. "\n\n" .. (self:bookbridge() and _("Trending on Open Library this week.")
            or _("Trending on Open Library this week. With the Bookbridge plugin you can request it from here.")),
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
        -- same call (and Trapper context) as Bookbridge's own search dialog
        local Trapper = require("ui/trapper")
        Trapper:wrap(function() bb:doSearch({ query = title, author = author, page = 1 }) end)
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
    dialog = InputDialog:new{
        title = _("Hardcover API key"),
        description = _("From hardcover.app/account/api. Your shelves, lists and yearly goal appear on the front page."),
        input = self.settings:readSetting("hardcover_token") or "",
        buttons = { {
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
        } },
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
    -- the plugin instance belongs to a FileManager or ReaderUI that is going away
    if self.page and UIManager:isWidgetShown(self.page) then UIManager:close(self.page) end
    if self.book_page and UIManager:isWidgetShown(self.book_page) then UIManager:close(self.book_page) end
end

return Ledger
