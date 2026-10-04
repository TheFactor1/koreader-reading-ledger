--[[
The Reading Ledger: a front page for KOReader with pixel pets.

Every book is a race between Biscuit the cat (your place on this device) and
Pip the dog (your place in Readest, on your phone or tablet). Pip also
fetches new books; Biscuit naps on the ones you're waiting for; your yearly
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
local UI = require("ledger_ui")

local REFRESH_EVERY = 30 * 60   -- remote data older than this is refreshed on show

-- Set by "Catch up with the dog": the file whose Readest position to jump to
-- once it's open (the reader's own plugin instance does the jump).
local pending_readest_jump = nil

local Ledger = WidgetContainer:extend{
    name = "ledger",
    is_doc_only = false,
}

function Ledger:init()
    UI.setPluginDir(self.path)
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/ledger.lua")
    Dispatcher:registerAction("ledger_show", {
        category = "none", event = "ShowLedger", title = _("Reading Ledger"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
end

function Ledger:addToMainMenu(menu_items)
    menu_items.reading_ledger = {
        text = _("Reading Ledger"),
        sorting_hint = "main",
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
    local bb = self:bookbridge()
    local data = Data.collect(self.ui, { download_dir = bb and bb.download_dir })
    data.pages_today = Data.pagesToday()
    return data
end

-- ---------------------------------------------------------------- showing
-- Three pages, one on screen at a time: Reading (the main one), Library and
-- Settings, switched by the tab bar at the bottom. The book page opens on
-- top of whichever is showing.
function Ledger:show()
    self.cache = Data.loadCache()
    self:showTab("reading")
    self:refreshRemote(false)
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

-- The whole description, from the Reading page.
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
local PET_DEFAULT = { cat = "Biscuit", dog = "Pip" }

function Ledger:petName(which)
    local n = self.settings:readSetting(which .. "_name")
    return (n and n ~= "") and n or PET_DEFAULT[which]
end

function Ledger:editPetName(which)
    local dialog
    dialog = InputDialog:new{
        title = which == "cat" and _("The cat's name") or _("The dog's name"),
        input = self:petName(which),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog)
                self.settings:saveSetting(which .. "_name", name ~= "" and name or nil)
                self.settings:flush()
                self:redraw()
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
        out.hardcover_hint = "Without one, trending books come from Open Library"
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
            "Every book is a race: the cat runs for this device, the dog for Readest on your phone or tablet, and a fish waits at the finish.",
            "",
            "Cat sprites by Shepardskin and dog sprites by Jason of GDN, both public domain (CC0), from OpenGameArt.org.",
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
        if not out.hardcover then
            out.trending = Net.openLibraryTrending("weekly", 6, covers_dir)
        end
        return out
    end, function(ok, out)
        self._refreshing = false
        if not ok or type(out) ~= "table" then return end
        local cache = self.cache or {}
        if out.hardcover then cache.hardcover = out.hardcover elseif token == nil then cache.hardcover = nil end
        if out.hardcover_err == "rejected" then cache.hardcover = nil; cache.hardcover_rejected = true end
        if out.trending then cache.trending = out.trending end
        cache.fetched_at = os.time()
        self.cache = cache
        self:refreshRequests()
        Data.saveCache(cache)
        self:redraw()
    end, 60)
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
        text = (r.title or "?") .. "\n\n" .. _("Requested. Biscuit is watching for it; it lands under Pip fetched when it arrives."),
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
