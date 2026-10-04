--[[
The Currently reading page: the Ledger's main page, all about the book you're on.

  CURRENTLY READING                                  < 1/2 >
  [cover]  Golden Son
           Pierce Brown
           Red Rising Saga, book 2
           442 pages · about 4 h left
           [CATCH UP WITH THE DOG]
  Description, a few lines (tap for all of it)
  [ the race: you against your rival, to the flag ]
  Biscuit (you) · p. 203                                 Pip · p. 230
  Today 23 pages. 8 more to out-read Pip.
  TODAY 23 | THIS WEEK 140 | STREAK 4 DAYS
  2 new books · waiting for 1 ›
  fish goal
  [LIBRARY] [CURRENTLY READING] [SETTINGS]

Several books on the go: swipe, or tap < >, to switch between them.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local UIManager = require("ui/uimanager")
local Chase = require("ledger_chase")
local Data = require("ledger_data")
local Race = require("ledger_race")
local UI = require("ledger_ui")

local Screen = Device.screen

local Reading = InputContainer:extend{
    name = "ledger_reading",
    covers_fullscreen = true,
    plugin = nil,
    data = nil,     -- Data.collect() + pages_today
    cache = nil,
    index = 1,      -- which book on the go is shown
}

function Reading:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextBook = { { Device.input.group.PgFwd } },
            PrevBook = { { Device.input.group.PgBack } },
        }
    end
    self.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    self.books = {}
    local d = self.data or {}
    if d.lead then self.books[#self.books + 1] = d.lead end
    for _, r in ipairs(d.reading or {}) do self.books[#self.books + 1] = r end
    self.index = math.max(1, math.min(self.index or 1, #self.books))
    self[1] = self:build()
end

function Reading:onClose()
    self.plugin:closeAll()
    return true
end

function Reading:onSwipe(_, ges)
    local dir = ges and ges.direction
    if dir == "west" then return self:onNextBook() end
    if dir == "east" then return self:onPrevBook() end
end

function Reading:switchTo(i)
    if #self.books < 2 then return true end
    self.index = (i - 1) % #self.books + 1
    self:update()
    return true
end

function Reading:onNextBook() return self:switchTo(self.index + 1) end
function Reading:onPrevBook() return self:switchTo(self.index - 1) end

function Reading:update(data, cache)
    if data then self.data = data; self:init() return self:repaint() end
    if cache then self.cache = cache end
    self[1] = self:build()
    self:repaint()
end

function Reading:repaint()
    UIManager:setDirty(self, "ui")
    if self.chase then self.chase:runIn() end
end

local function statBlock(label, value, w)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local vg = VerticalGroup:new{ align = "center",
        UI.text(value, "bold", 16), UI.text(label:upper(), "pix", 8, UI.INK2) }
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = vg:getSize().h }, vg }
end

function Reading:build(squeeze)
    squeeze = squeeze or 0
    local function s(n) return Screen:scaleBySize(n) end
    local W, H = self.dimen.w, self.dimen.h
    local m = math.floor(W * 0.045)
    local cw = W - 2 * m
    local plugin = self.plugin
    local d = self.data or {}
    local c = self.cache or {}
    local rec = self.books[self.index]

    local main = VerticalGroup:new{ align = "left" }
    local function add(w) main[#main + 1] = w end

    -- top line: page name, and which of several books
    local right
    if #self.books > 1 then
        right = HorizontalGroup:new{ align = "center",
            UI.tappable(UI.text("<", "pix", 11), function() self:onPrevBook() end),
            UI.hspace(s(10)),
            UI.text(string.format("%d/%d", self.index, #self.books), "pix", 11),
            UI.hspace(s(10)),
            UI.tappable(UI.text(">", "pix", 11), function() self:onNextBook() end),
        }
    else
        right = UI.text(os.date("%a %d %b"):upper(), "pix", 11)
    end
    add(UI.header(cw, "CURRENTLY READING", right))

    -- the gaps between sections; whatever room is left over on the page is
    -- shared out between them, so nothing bunches up at the top
    local gaps = {}
    local function gap(h)
        local sp = UI.vspace(h)
        gaps[#gaps + 1] = sp
        add(sp)
    end

    self.chase = nil
    if not rec then
        add(UI.para(string.format("Nothing on the go. %s is waiting for a book -- pick one from the Library.",
            plugin:petName("cat")), "body", 14, cw))
    else
        -- cover and details
        local cover_w = math.floor(cw * (0.36 - 0.05 * squeeze))
        local cover = UI.tappable((UI.cover(rec, cover_w, math.floor(cover_w * 1.5))), function() plugin:showBook(rec) end)
        local info_w = cw - cover_w - s(16)
        local title = UI.para(rec.title or "?", "bold", 20, info_w)
        local info = VerticalGroup:new{ align = "left", title }
        if rec.author then info[#info + 1] = UI.text(rec.author, "body", 13, UI.INK2, info_w) end
        info[#info + 1] = UI.vspace(s(8))
        if rec.series then
            local series = rec.series .. (rec.series_index and (", book " .. rec.series_index) or "")
            info[#info + 1] = UI.para(series, "body", 11, info_w, UI.INK2)
        end
        local facts = {}
        if rec.pages then facts[#facts + 1] = rec.pages .. " pages" end
        local stats = self.stats_for == rec.hash and self.stats or Data.readingStats(rec.hash)
        self.stats, self.stats_for = stats, rec.hash
        local left = Data.timeLeft(stats.pace or stats.all_pace, rec.pages, rec.pct)
        if left then facts[#facts + 1] = left end
        if #facts > 0 then info[#info + 1] = UI.para(table.concat(facts, " · "), "body", 11, info_w, UI.INK2) end
        info[#info + 1] = UI.vspace(s(12))
        if Data.readestAhead(rec) then
            -- two places to open it: where Readest got to, or where this
            -- device is; both buttons as wide as the wider one
            local ahead, here, note = Data.jumpLabels(rec)
            info[#info + 1] = UI.para(note, "body", 11, info_w, UI.BLACK)
            info[#info + 1] = UI.vspace(s(6))
            local bw = math.min(info_w, math.max(UI.buttonWidth(ahead), UI.buttonWidth(here)))
            info[#info + 1] = UI.button(ahead, function() plugin:continueFromReadest(rec) end, false, nil, bw)
            info[#info + 1] = UI.vspace(s(6))
            info[#info + 1] = UI.button(here, function() plugin:openBook(rec) end, true, nil, bw)
        else
            info[#info + 1] = UI.button("Keep reading", function() plugin:openBook(rec) end)
        end
        -- line the cover's top edge up with the top of the title's capitals
        -- (the title's line box has room above the letters)
        local cap_top = math.max(0, title:getBaseline() - math.floor(UI.face("bold", 20).size * 0.70 + 0.5))
        add(HorizontalGroup:new{ align = "top",
            VerticalGroup:new{ align = "left", UI.vspace(cap_top), cover }, UI.hspace(s(16)), info })
        gap(s(12))

        -- description
        local desc = Data.description(rec)
        local lines = math.max(0, 4 - squeeze)
        if desc and lines > 0 then
            local box = TextBoxWidget:new{
                text = desc, face = UI.face("body", 12), width = cw,
                height = math.floor(UI.face("body", 12).size * 1.45 * lines),
                height_overflow_show_ellipsis = true, fgcolor = UI.BLACK,
            }
            add(UI.tappable(box, function() plugin:showDescription(rec, desc) end))
            gap(s(12))
        end

        -- the race
        local race = Race.state(rec, stats, plugin.settings, plugin:runner(), plugin:rival(), plugin:raceModel())
        local lines = Race.lines(plugin, rec, race, self.cache)
        local chase = Chase:new{
            width = cw, height = math.floor(H * (0.19 - 0.02 * squeeze)),
            you = plugin:runner(), rival = plugin:rival(),
            you_pct = race.you_pct, rival_pct = race.rival_pct, napping = race.napping,
            you_says = lines.you_says, rival_says = lines.rival_says, fish_says = lines.fish_says,
            animate = plugin:animationsOn(), t = 1,
        }
        chase.show_parent = self
        self.chase = chase
        add(chase)
        add(UI.vspace(s(4)))
        add(UI.spread(cw, UI.text(lines.you_label, "body", 10, UI.INK2), UI.text(lines.rival_label, "body", 10, UI.INK2)))
        add(UI.vspace(s(6)))
        add(UI.text(lines.today, "body", 11, UI.BLACK, cw))
        gap(s(14))
    end

    -- stats
    local st = self.stats or Data.readingStats(nil)
    local bw = math.floor(cw / 3)
    add(UI.rule(cw, s(2)))
    add(UI.vspace(s(8)))
    add(HorizontalGroup:new{ align = "center",
        statBlock("Today", tostring(st.today) .. " p", bw),
        statBlock("This week", tostring(st.week) .. " p", bw),
        statBlock("Streak", st.streak .. (st.streak == 1 and " day" or " days"), bw),
    })
    add(UI.vspace(s(8)))
    add(UI.rule(cw, s(2)))
    gap(s(10))

    -- arrivals and waiting, one line into the library
    local n_new = #(d.just_in or {})
    local n_wait = #(c.requests or {})
    local line = string.format("%d new %s · waiting for %d  ›", n_new, n_new == 1 and "book" or "books", n_wait)
    add(UI.tappable(UI.text(line, "body", 12, UI.BLACK, cw), function() plugin:showTab("library", { filter = "new" }) end))

    -- footer: goal, then the tabs
    local foot = VerticalGroup:new{ align = "left" }
    local hc = c.hardcover
    if hc and hc.goal and hc.goal.goal then
        local fish = UI.fishRow(math.min(hc.goal.goal, 24), hc.goal.progress or 0, cw / 22)
        foot[#foot + 1] = UI.spread(cw, fish,
            UI.text(string.format("%d/%d in %s", hc.goal.progress or 0, hc.goal.goal, os.date("%Y")), "pix", 10))
    else
        foot[#foot + 1] = UI.tappable(UI.text("Add your Hardcover key in Settings for your yearly goal ›", "body", 11, UI.INK2, cw),
            function() plugin:showTab("settings") end)
    end
    foot[#foot + 1] = UI.vspace(s(12))
    foot[#foot + 1] = UI.tabBar(cw, "reading", function(id) plugin:showTab(id) end)

    local used = main:getSize().h + foot:getSize().h + 2 * m
    if used > H and squeeze < 3 then return self:build(squeeze + 1) end
    -- share the spare room: up to s(20) more per gap, the rest stays above
    -- the footer (the gap after the arrivals line is the last one)
    local last = UI.vspace(0)
    gaps[#gaps + 1] = last
    main[#main + 1] = last
    local spare = math.max(0, H - used)
    local each = math.min(s(20), math.floor(spare / #gaps))
    for _, sp in ipairs(gaps) do sp.width = sp.width + each end
    used = used + each * #gaps
    main:resetLayout()
    return FrameContainer:new{
        background = UI.WHITE, bordersize = 0, margin = 0, padding = m,
        VerticalGroup:new{ align = "left", main, UI.vspace(math.max(0, H - used)), foot },
    }
end

return Reading
