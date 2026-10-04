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
local Home = require("ledger_home")
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
function Ledger:show()
    if self.home then UIManager:close(self.home) end
    self.cache = Data.loadCache()
    local data = self:collect()
    self.home = Home:new{ plugin = self, data = data, cache = self.cache }
    UIManager:show(self.home, "flashui")
    self:fetchCovers(data)
    self:refreshRemote(false)
end

function Ledger:redraw()
    if self.home and UIManager:isWidgetShown(self.home) then
        self.home:update(self:collect(), self.cache)
    end
end

function Ledger:closeAll()
    -- (not ipairs over {book_page, home}: it stops at the first nil)
    if self.book_page and UIManager:isWidgetShown(self.book_page) then UIManager:close(self.book_page) end
    if self.home and UIManager:isWidgetShown(self.home) then UIManager:close(self.home) end
    self.book_page, self.home = nil, nil
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

-- KOReader's cover cache extracts covers in the background; ask for the
-- ones we're about to show and redraw once they're in.
function Ledger:fetchCovers(data)
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok or not BIM then return end
    local files = {}
    local list = { data.lead }
    for _, r in ipairs(data.just_in or {}) do list[#list + 1] = r end
    local W = Device.screen:getWidth()
    for _, rec in pairs(list) do
        if rec and rec.file then
            local iok, info = pcall(BIM.getBookInfo, BIM, rec.file, false)
            if not (iok and info and info.cover_fetched) then
                files[#files + 1] = { filepath = rec.file, cover_specs = { max_cover_w = W, max_cover_h = W * 1.5 } }
            end
        end
    end
    if #files == 0 then return end
    pcall(BIM.extractInBackground, BIM, files)
    UIManager:scheduleIn(6, function()
        if self.book_page and UIManager:isWidgetShown(self.book_page) then
            self.book_page:update(self.book_page.hc)
        end
        self:redraw()
    end)
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
    logger.info("ledger: library (closing the Ledger)", self.ui.document and "over a book" or "in the file browser")
    self:closeAll()
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
    if self.home and UIManager:isWidgetShown(self.home) then UIManager:close(self.home) end
    if self.book_page and UIManager:isWidgetShown(self.book_page) then UIManager:close(self.book_page) end
end

return Ledger
