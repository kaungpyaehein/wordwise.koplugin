--[[--
Word Wise: draw short definitions above difficult words (like Kindle's Word
Wise) as a per-page overlay on the ORIGINAL book — no copy, no file rewrite.

How it works:
  * A view module registered with ReaderView paints gloss strings on top of the
    page. For the current page we walk the visible words, look each up in the
    dictionary, and remember a screen box + gloss for the difficult ones.
  * To leave room for the gloss above each line, we raise the document's line
    spacing uniformly (setInterlineSpacePercent). Every line gets the same
    height whether or not it carries a hint, and an interline change only
    re-renders (it never rebuilds the DOM, so no "reload document?" prompt).
  * Hints are recomputed on every page turn / re-render, so only the visible
    page is ever processed.

@module koplugin.wordwise
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local RenderText = require("ui/rendertext")
local SpinWidget = require("ui/widget/spinwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local WordWiseDB = require("wordwise_db")

-- Complex scripts (Myanmar) need OpenType shaping, which RenderText's
-- glyph-by-glyph path lacks. Such glosses are measured and drawn through
-- TextWidget (xtext/HarfBuzz) with a bundled Noto Sans Myanmar face.
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".")
    :gsub("^%./", "")
local MYANMAR_FONT = PLUGIN_DIR .. "/fonts/NotoSansMyanmar-Regular.ttf"
local HAS_MYANMAR_FONT = lfs.attributes(MYANMAR_FONT, "mode") == "file"

-- Font:getFace resolves paths against KOReader's fonts/ dir: older releases
-- (e.g. v2025.10) always prepend "<fontdir>/", newer ones accept "/" and "./"
-- paths as-is. PluginLoader gives a path relative to KOReader's root
-- ("plugins/x.koplugin"), so try it relative to fonts/ first, then as given.
local MYANMAR_FONT_NAME = "NotoSansMyanmar-Regular.ttf"

-- Last resort: copy the bundled font into KOReader's user fonts dir, which
-- FontList scans at startup, so a bare-name lookup finds it after a restart.
local function installMyanmarFont()
    if not HAS_MYANMAR_FONT then return end
    local dir = DataStorage:getDataDir() .. "/fonts"
    local dest = dir .. "/" .. MYANMAR_FONT_NAME
    if lfs.attributes(dest, "mode") == "file" then return end
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local src = io.open(MYANMAR_FONT, "rb")
    if not src then return end
    local data = src:read("*a")
    src:close()
    local out = io.open(dest, "wb")
    if not out then return end
    out:write(data)
    out:close()
    logger.info("WordWise: installed Myanmar font to", dest)
end

local function loadMyanmarFace(size)
    local candidates = {}
    if HAS_MYANMAR_FONT then
        if not MYANMAR_FONT:match("^/") then
            candidates[#candidates + 1] = "../" .. MYANMAR_FONT
            candidates[#candidates + 1] = "./" .. MYANMAR_FONT
        else
            -- Absolute path (Android/Boox: /sdcard/koreader/plugins/...). Newer
            -- KOReader takes it as-is; older ones prepend "<fontdir>/", so also
            -- climb from fontdir up to "/" (extra ".." at root stays at root).
            candidates[#candidates + 1] = MYANMAR_FONT
            candidates[#candidates + 1] = string.rep("../", 24) .. MYANMAR_FONT:sub(2)
        end
    end
    -- Bare names: Font:getFace falls back to searching every known font dir
    -- (user fonts dir, and /system/fonts on Android).
    candidates[#candidates + 1] = MYANMAR_FONT_NAME
    candidates[#candidates + 1] = "NotoSansMyanmar-Regular.otf"
    candidates[#candidates + 1] = "NotoSansMyanmarUI-Regular.ttf"
    candidates[#candidates + 1] = "NotoSansMyanmarUI-Regular.otf"
    for _, path in ipairs(candidates) do
        local ok, face = pcall(Font.getFace, Font, path, size)
        if ok and face then
            logger.info("WordWise: Myanmar face loaded from", path)
            return face
        end
    end
    installMyanmarFont()
end

local function needsShaping(text)
    -- U+1000..U+109F (Myanmar) is UTF-8 E1 80 80 .. E1 82 9F
    return text:find("\225[\128-\130]") ~= nil
end
local WordWiseKindle = require("wordwise_kindle")
local WordWiseL10N = require("wordwise_l10n")

-- The plugin ships a built-in open dictionary (bundled beside this file), but a
-- user-supplied canonical-schema database dropped into WW_DIR overrides it — so
-- you can swap in your own (e.g. a personal Kindle-derived DB) without deleting
-- anything. Resolution order: WW_DIR/wordwise.db, first *.db in WW_DIR, bundled.
local WW_DIR = DataStorage:getDataDir() .. "/wordwise"

-- Directory this plugin was loaded from, used to find the bundled dictionary.
local PLUGIN_ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[^/\\]+$", "")
local BUNDLED_DB = PLUGIN_ROOT .. "wordwise.db"

local MAX_LEVEL = 5                -- hint level 1 (rarest words only) .. 5 (most hints)
local DEFAULT_LEVEL = 3           -- middle of the slider, like Kindle's default
-- While hints are on we raise the book's line-spacing setting to this value, to
-- open a gloss gap above each line. Disabling restores the default spacing.
local HINT_INTERLINE_MIN = 180
local GLOSS_FONT_SIZE = 10        -- default hint font size (adjustable 6..20)
local GLOSS_FONT_MIN = 6          -- selectable hint font-size range (slider)
local GLOSS_FONT_MAX = 20
local WORD_WALK_GUARD = 4000       -- hard cap on words scanned per page

local WordWise = WidgetContainer:extend{
    name = "wordwise",
    is_doc_only = true,
}

-- Only reflowable (crengine) documents expose the word/box APIs we need.
function WordWise:isSupportedDocument()
    return self.ui and self.ui.document and self.ui.rolling ~= nil and not self.ui.paging
end

function WordWise:getHintLevel()
    return G_reader_settings:readSetting("wordwise_hint_level") or DEFAULT_LEVEL
end

function WordWise:getGlossFontSize()
    return G_reader_settings:readSetting("wordwise_gloss_font_size") or GLOSS_FONT_SIZE
end

-- Whether to draw the horizontal underline rule beneath each gloss. On by
-- default. Global, like the hint level.
function WordWise:getShowUnderline()
    return G_reader_settings:nilOrTrue("wordwise_show_underline")
end

-- Resolve the dictionary path: a user DB in WW_DIR (wordwise.db, else the first
-- *.db found there) overrides the dictionary bundled with the plugin. If none
-- is present but this is a Kindle with its own Word Wise corpus on disk, that
-- is converted once into WW_DIR/wordwise.db and used from then on (personal
-- use only -- see wordwise_kindle.lua). Cached (nil = not yet resolved, false
-- = none).
function WordWise:getDBPath()
    if self._db_path ~= nil then
        return self._db_path or nil
    end
    self._db_path = false
    if lfs.attributes(WW_DIR, "mode") == "directory" then
        local preferred = WW_DIR .. "/wordwise.db"
        if lfs.attributes(preferred, "mode") == "file" then
            self._db_path = preferred
            return preferred
        end
        for name in lfs.dir(WW_DIR) do
            if name:match("%.db$") then
                self._db_path = WW_DIR .. "/" .. name
                return self._db_path
            end
        end
    end
    if WordWiseKindle.available() then
        if lfs.attributes(WW_DIR, "mode") ~= "directory" then
            lfs.mkdir(WW_DIR)
        end
        -- One-time conversion; on slow device storage this can take a while,
        -- so show something rather than leave the UI looking hung.
        local info = InfoMessage:new{
            text = self:tr("building"),
        }
        UIManager:show(info)
        UIManager:forceRePaint()
        local converted = WW_DIR .. "/wordwise.db"
        local ok = WordWiseKindle.convert(WordWiseKindle.KLLD_PATH, converted, BUNDLED_DB)
        UIManager:close(info)
        if ok then
            self._db_path = converted
            return converted
        end
    end
    if lfs.attributes(BUNDLED_DB, "mode") == "file" then
        self._db_path = BUNDLED_DB
        return BUNDLED_DB
    end
    return nil
end

function WordWise:getDB()
    if self.db == nil then
        local path = self:getDBPath()
        self.db = (path and WordWiseDB.open(path)) or false
    end
    return self.db or nil
end

function WordWise:hasDB()
    return self:getDBPath() ~= nil
end

-- Enabled state is per-book (stored in the book's sidecar), so each book
-- remembers whether Word Wise is on. Off by default: a book is only affected
-- once the reader turns it on there.
function WordWise:isEnabled()
    local ds = self.ui and self.ui.doc_settings
    return (ds and ds:isTrue("wordwise_enabled")) or false
end

-- Known words: lemmas the user has marked "I already know this word" from the
-- dictionary popup. Stored as a set { [lemma] = true } and suppressed from
-- hints across every book (global, like the hint level). Keyed by lemma so all
-- inflected forms of a word are hidden once it is marked known.
function WordWise:getKnownWords()
    if self.known_words == nil then
        self.known_words = G_reader_settings:readSetting("wordwise_known_words") or {}
    end
    return self.known_words
end

function WordWise:isWordKnown(lemma)
    return lemma ~= nil and self:getKnownWords()[lemma] == true
end

function WordWise:setWordKnown(lemma, known)
    if not lemma then return end
    local kw = self:getKnownWords()
    kw[lemma] = known or nil
    G_reader_settings:saveSetting("wordwise_known_words", kw)
end

-- Lifecycle ----------------------------------------------------------------

function WordWise:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- infofont is NotoSans (proportional), closer to Kindle's gloss font than
    -- the monospace infont.
    self:loadGlossFaces(self:getGlossFontSize())
    self.hints = {}
    -- Register the overlay painter with ReaderView.
    self.overlay = { paintTo = function(_, bb, x, y) self:paintHints(bb, x, y) end }
    if self.ui.view then
        self.ui.view:registerViewModule("wordwise", self.overlay)
    end
    self:registerDictButtons()
end

-- The lemma this dictionary popup is looking at, if it is a word Word Wise
-- knows (so the "already know" button only appears for glossed words). Returns
-- the de-inflected lemma, matching how hints are keyed.
function WordWise:dictLemmaFor(dict_popup)
    if not (dict_popup and dict_popup.word) then return nil end
    local key = dict_popup.word:gsub("[^%a]", "")
    if #key < 3 then return nil end
    local db = self:getDB()
    if not db then return nil end
    local entry = db:lookup(key)
    return entry and entry.key or nil
end

-- Localize one of Word Wise's own UI strings to the current UI language. These
-- strings aren't in KOReader's catalog (see wordwise_l10n.lua), so we translate
-- them ourselves: look up the key for the current language, fall back to the
-- English source (en_GB), and substitute any extra args into %1, %2, ... .
function WordWise:tr(key, ...)
    local lang = G_reader_settings:readSetting("language")
    local t = lang and WordWiseL10N[lang]
    local s = (t and t[key]) or (WordWiseL10N.en_GB and WordWiseL10N.en_GB[key]) or key
    if select("#", ...) > 0 then return T(s, ...) end
    return s
end

-- Label for the toggle button given the popup's lemma.
function WordWise:knownButtonText(lemma)
    if lemma and self:isWordKnown(lemma) then
        return self:tr("show")
    end
    return self:tr("know")
end

-- Toggle the known state for the popup's word, hide/show its hint, and flip the
-- button's own label in place (both KOReader vintages build a button_table with
-- our button id, so this works whichever registration path added the button).
function WordWise:onKnownButtonTap(dict_popup)
    local lemma = self:dictLemmaFor(dict_popup)
    if not lemma then return end
    self:setWordKnown(lemma, not self:isWordKnown(lemma))
    self:refresh()  -- repaint the page so the hint appears/disappears now
    local bt = dict_popup.button_table
    local button = bt and bt.button_by_id and bt.button_by_id["wordwise_known"]
    if button then
        button:setText(self:knownButtonText(lemma), button.width)
        UIManager:setDirty(dict_popup, function() return "ui", button.dimen end)
    end
end

-- Add an "I already know this word" button to the dictionary popup. Tapping it
-- suppresses the Word Wise hint for that word everywhere; on a known word it
-- flips to "Show Word Wise hint" so the choice is reversible.
--
-- Two KOReader vintages are supported: the newer ReaderDictionary:addToDictButtons
-- API (used when present), and older builds that instead emit a DictButtonsReady
-- event -- handled by WordWise:onDictButtonsReady below. Only one path is ever
-- live on a given build, so the button is never duplicated.
function WordWise:registerDictButtons()
    if not (self.ui and self.ui.dictionary
            and self.ui.dictionary.addToDictButtons) then
        return
    end
    self.ui.dictionary:addToDictButtons({
        id = "wordwise_known",
        conditional = true,
        show_func = function(dict_popup)
            return self:dictLemmaFor(dict_popup) ~= nil
        end,
        text_func = function(dict_popup)
            return self:knownButtonText(self:dictLemmaFor(dict_popup))
        end,
        callback = function(dict_popup)
            self:onKnownButtonTap(dict_popup)
        end,
    })
end

-- Older-build hook: inject the button into the popup's button rows just before
-- the button table is built. Fires only on builds without addToDictButtons.
-- Placed directly below the VocabBuilder "Add to vocabulary builder" row when
-- present (its plugin sorts before ours, so it has already inserted its row);
-- otherwise appended.
function WordWise:onDictButtonsReady(dict_popup, buttons)
    local lemma = self:dictLemmaFor(dict_popup)
    if not lemma then return end
    local pos = #buttons + 1
    for i, row in ipairs(buttons) do
        if row[1] and row[1].id == "vocabulary" then
            pos = i + 1
            break
        end
    end
    table.insert(buttons, pos, {
        {
            id = "wordwise_known",
            text = self:knownButtonText(lemma),
            font_bold = false,
            callback = function() self:onKnownButtonTap(dict_popup) end,
        },
    })
end

-- The line spacing the current book is set to (crengine's configurable value,
-- the same one the Font menu edits and the sidecar persists).
function WordWise:currentLineSpacing()
    return (self.ui.font and self.ui.font.configurable
        and self.ui.font.configurable.line_spacing) or 100
end

-- The line spacing to fall back to as "default": the reader's global default if
-- set, else KOReader's built-in medium default (100). Used when restoring on
-- disable if we have no trustworthy captured original.
function WordWise:defaultLineSpacing()
    return G_reader_settings:readSetting("copt_line_spacing")
        or (G_defaults and G_defaults:readSetting("DCREREADER_CONFIG_LINE_SPACE_PERCENT_MEDIUM"))
        or 100
end

-- Turn the raised gloss spacing on/off by editing the book's ACTUAL line-spacing
-- setting (not a runtime-only override), which persists per-book. Only called
-- when the reader toggles Word Wise: enabling sets HINT_INTERLINE_MIN (=180%),
-- disabling sets the default. We never re-assert it on open, so once it is on
-- the reader is free to lower the line spacing again and it sticks.
function WordWise:setLineSpacing(on)
    if not self:isSupportedDocument() then return end
    local conf = self.ui.font and self.ui.font.configurable
    if not conf then return end
    conf.line_spacing = on and HINT_INTERLINE_MIN or self:defaultLineSpacing()
    self.ui.document:setInterlineSpacePercent(conf.line_spacing)
    self.ui:handleEvent(Event:new("UpdatePos"))
end

function WordWise:onReaderReady()
    if not self:isSupportedDocument() then return end
    if self:isEnabled() and self:hasDB() then
        -- The book was left at the raised spacing (persisted per-book) when it
        -- was turned on, so it reopens laid out correctly; just paint the hints.
        UIManager:nextTick(function() self:refresh() end)
    end
end

-- Close the dictionary DB when the document closes so the SQLite connection and
-- prepared statement are released deterministically (rather than at GC).
function WordWise:onCloseDocument()
    if self.db then
        self.db:close()
        self.db = nil
    end
end

-- Recompute per page turn / re-render.
function WordWise:onPosUpdate() self:computePageHints() end
function WordWise:onPageUpdate() self:computePageHints() end

-- A KOReader "profile" switch -- or any font / margin / line-height / style
-- change -- re-renders the document, moving every word to a new position. Our
-- hints cache absolute screen boxes, so after such a reflow they would keep
-- painting glosses at the OLD positions (scattered over the new text) until the
-- reader toggled Word Wise off and on. PosUpdate / PageUpdate don't reliably
-- refresh + repaint the overlay on the delayed "partial rerendering" path,
-- which KOReader enables by default, so also key off the re-render events every
-- other position-caching module (highlights, annotations, dogear, page map,
-- ToC, thumbnails) uses. nextTick lets the new layout settle first; refresh()
-- recomputes the hints and its full setDirty repaints them against the final
-- geometry.
function WordWise:onDocumentRerendered()
    if not (self:isEnabled() and self:isSupportedDocument()) then return end
    UIManager:nextTick(function() self:refresh() end)
end
WordWise.onDocumentPartiallyRerendered = WordWise.onDocumentRerendered

-- Core: enumerate this page's words, keep glosses for the difficult ones -----

function WordWise:computePageHints()
    self.hints = {}
    self.text_col = nil
    if not (self:isEnabled() and self:isSupportedDocument()) then return end
    local db = self:getDB()
    if not db then return end
    local doc = self.ui.document
    local page = doc:getCurrentPage()
    local start_xp = doc:getPageXPointer(page)
    if not start_xp then return end
    local level = self:getHintLevel()

    local first_xp, last_xp  -- text span actually laid out on this page
    local xp = doc:getNextVisibleWordStart(start_xp)
    local guard = 0
    while xp and guard < WORD_WALK_GUARD do
        guard = guard + 1
        if not doc:isXPointerInCurrentPage(xp) then break end
        local end_xp = doc:getNextVisibleWordEnd(xp)
        if not end_xp then break end
        first_xp = first_xp or xp
        last_xp = end_xp
        local word = doc:getTextFromXPointers(xp, end_xp)
        if word then
            local key = word:gsub("[^%a]", "")
            if #key >= 3 then
                local entry = db:lookup(key)
                -- difficulty 1 = rarest .. 5 = common; show up to the hint level,
                -- and never for words the user has marked as already known.
                if entry and entry.difficulty <= level and not self:isWordKnown(entry.key) then
                    local boxes = doc:getScreenBoxesFromPositions(xp, end_xp, true)
                    -- Use the FIRST line-segment: a word hyphenated across two
                    -- lines otherwise yields a tall multi-line bounding box and
                    -- the gloss lands a line too high / off-column.
                    local sbox = boxes and boxes[1]
                    if sbox and sbox.w > 0 and sbox.h > 0 then
                        self.hints[#self.hints + 1] = {
                            text = entry.gloss, box = sbox,
                            difficulty = entry.difficulty,
                        }
                    end
                end
            end
        end
        local nxt = doc:getNextVisibleWordStart(end_xp)
        if not nxt or nxt == xp then break end
        xp = nxt
    end

    -- The text column glosses must stay inside: the actual rendered extent of
    -- this page's lines, not the page-margin setting. The book's CSS/block
    -- margin insets the text further than getPageMargins() reports, so clamping
    -- to the page margin still leaves glosses drifting into the blank margin.
    -- One call returns a box per line segment; the min/max spans the real column
    -- (justified lines reach both edges). paintHints falls back to page margins
    -- / screen edges when this is unavailable.
    if first_xp and last_xp then
        local line_boxes = doc:getScreenBoxesFromPositions(first_xp, last_xp, true)
        local lo, hi
        for _, b in ipairs(line_boxes or {}) do
            if b.w > 0 then
                if not lo or b.x < lo then lo = b.x end
                if not hi or b.x + b.w > hi then hi = b.x + b.w end
            end
        end
        if lo and hi and hi > lo then
            self.text_col = { left = lo, right = hi }
        end
    end
end

local GLOSS_HGAP = 8   -- minimum horizontal gap between two glosses on a line
local CARET_DEPTH = 7  -- clearance kept between the gloss rule and the word

-- Draw the optional thin rule spanning [x0, x1] under a gloss. No arrow.
local function drawWordMarker(bb, x0, x1, ytop, color, with_rule)
    if with_rule then bb:paintRect(x0, ytop, x1 - x0, 1, color) end
end

-- Font-level vertical metrics (max ascent/descent) for the current gloss face,
-- the same for every gloss no matter which glyphs a given string contains.
-- paintHints lays glosses out with these instead of each string's own ink
-- extents (sizeUtf8Text's y_top/y_bottom), so the caret always sits the same
-- distance below the baseline. Per-string extents made a gloss with no
-- descenders (e.g. "an outdoor meal") pull its caret right up against the
-- letters and look cramped, while one with descenders ("a background scene or
-- setting") looked fine. Cached; recomputed when the face changes (font size).
function WordWise:getGlossMetrics()
    local face = self.gloss_face
    local m = self._gloss_metrics
    if m and m.face == face then return m end
    local ascent, descent
    local ok, height, asc = pcall(function()
        return face.ftsize:getHeightAndAscender()
    end)
    if ok and height and asc then
        ascent = math.floor(asc + 0.5)
        descent = math.ceil(height - asc)
    else
        -- Fallback for builds without the freetype metrics API: probe a string
        -- spanning the full ascender + descender range of the face.
        local sz = RenderText:sizeUtf8Text(0, 10000, face, "Agjpqy", true, false)
        ascent, descent = sz.y_top, sz.y_bottom
    end
    if descent < 0 then descent = 0 end
    m = { face = face, ascent = ascent, descent = descent }
    self._gloss_metrics = m
    return m
end

function WordWise:paintHints(bb, x, y)
    if not (self:isEnabled() and self.hints and #self.hints > 0) then return end
    local screen_w = bb:getWidth()
    local color = Blitbuffer.COLOR_BLACK
    local show_underline = self:getShowUnderline()

    -- Keep glosses within the text content column, never in the page margins: a
    -- gloss centered over a word near the column edge would otherwise spill into
    -- (or, with a large hint font, right across) the blank margin, detached from
    -- the text. Prefer the real rendered column (computePageHints, accounts for
    -- the book's CSS margin); fall back to the page-margin setting, then to the
    -- screen edges.
    local left_bound, right_bound = 2, screen_w - 2
    if self.text_col then
        left_bound = self.text_col.left
        right_bound = self.text_col.right
    else
        local ok, margins = pcall(function() return self.ui.document:getPageMargins() end)
        if ok and margins and margins.left and margins.right then
            left_bound = margins.left
            right_bound = screen_w - margins.right
        end
    end

    -- Lay each gloss out: measure it, center it over its word, and clamp it
    -- inside the text column (right edge first, so the left wins if the gloss is
    -- wider than the column -- e.g. a word wrapped across a line break anchors on
    -- its first segment, which can sit hard against the right margin).
    --
    -- Vertically, the hint unit is gloss text, then the rule, then the caret
    -- pointing down at the word. The raised leading is split evenly above/below
    -- each line's glyphs, so the blank band above the word is centered on the
    -- line-box top (box.y). We center the whole unit in that band so it sits in
    -- the middle of the gap regardless of the line spacing -- but never let the
    -- caret drop onto the word (clamp to just above it when the gap is tight).
    local GLOSS_RULE_GAP = 1  -- padding between the gloss text bottom and the rule
    local spacing = self:currentLineSpacing()
    -- Font-level ascent/descent, identical for every gloss (see getGlossMetrics):
    -- laying glosses out by these constants -- not each string's own ink extents
    -- -- keeps the caret a uniform distance below the baseline, so a hint with no
    -- descenders looks the same as one with them.
    local metrics = self:getGlossMetrics()
    local ascent, descent = metrics.ascent, metrics.descent
    -- Noto Sans Myanmar ink reaches ~1.0 em above the baseline and ~0.54 em
    -- below it (stacked marks like ု ူ under medials); its hhea box (1.32 /
    -- 0.86 em) is far taller than the ink, so use the ink extents instead.
    local GLOSS_NEAR_GAP = 2  -- gap between a gloss and the top of its word
    local msize = self.complex_face and self.complex_face.size or 0
    local myanmar_ascent = math.ceil(msize * 1.0)
    local myanmar_descent = math.ceil(msize * 0.54)
    local items = {}
    for _, h in ipairs(self.hints) do
        local w = self:glossWidth(h.text, screen_w)
        local tx = math.floor(h.box.x + (h.box.w - w) / 2 + 0.5)
        local max_x = right_bound - w
        if tx > max_x then tx = max_x end
        if tx < left_bound then tx = left_bound end
        local leading = h.box.h * (1 - 100 / spacing)
        local half = math.floor(leading / 2)
        local word_top = h.box.y + half
        local a, d = ascent, descent
        if self.complex_face ~= self.gloss_face and needsShaping(h.text) then
            a, d = myanmar_ascent, myanmar_descent
        end
        -- Sit the gloss just above its own word, not in the middle of the gap
        -- where it reads as belonging to the line above. With the rule shown,
        -- leave room for it between the gloss and the word. Never climb into
        -- the previous line's glyphs when the line spacing is tight.
        local clearance = show_underline and (GLOSS_RULE_GAP + 1 + GLOSS_NEAR_GAP) or GLOSS_NEAR_GAP
        local baseline = word_top - clearance - d
        local prev_bottom = h.box.y - half
        if baseline - a < prev_bottom then baseline = prev_bottom + a end
        baseline = math.floor(math.min(baseline, word_top - 1 - d) + 0.5)
        local marker_y = math.min(baseline + d + GLOSS_RULE_GAP, word_top - GLOSS_NEAR_GAP - 1)
        items[#items + 1] = {
            h = h, x0 = tx, x1 = tx + w, band = h.box.y,
            difficulty = h.difficulty or 5,
            marker_y = marker_y,
            baseline = baseline,
            word_cx = math.floor(h.box.x + h.box.w / 2 + 0.5),
        }
    end

    -- De-overlap: glosses on the same line (same band) can collide
    -- horizontally. Place them rarer-word-first (lower difficulty = more
    -- valuable) and drop any that would still overlap an already-placed gloss,
    -- keeping the page readable. Different lines sit in separate bands, so they
    -- never overlap vertically.
    table.sort(items, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        if a.difficulty ~= b.difficulty then return a.difficulty < b.difficulty end
        return a.x0 < b.x0
    end)
    local placed = {}  -- band -> list of {x0, x1}
    for _, it in ipairs(items) do
        if it.baseline > 2 then
            local list = placed[it.band]
            local fits = true
            if list then
                for _, iv in ipairs(list) do
                    if it.x0 < iv[2] + GLOSS_HGAP and it.x1 + GLOSS_HGAP > iv[1] then
                        fits = false
                        break
                    end
                end
            else
                list = {}
                placed[it.band] = list
            end
            if fits then
                list[#list + 1] = { it.x0, it.x1 }
                self:drawGloss(bb, it.x0, it.baseline, it.h.text, color)
                drawWordMarker(bb, it.x0, it.x1, it.marker_y, color, show_underline)
            end
        end
    end
end

-- Recompute + repaint (interline change already repaints; this is for the
-- difficulty/enable toggles that don't relayout).
function WordWise:refresh()
    self:computePageHints()
    UIManager:setDirty("all", "ui")
end

function WordWise:loadGlossFaces(size)
    self.gloss_face = Font:getFace("infofont", size)
    self.complex_face = loadMyanmarFace(size)
    if not self.complex_face then
        logger.warn("WordWise: cannot load Myanmar font", MYANMAR_FONT)
        self.complex_face = self.gloss_face
    end
    logger.info("WordWise: myanmar font", MYANMAR_FONT, "exists", HAS_MYANMAR_FONT,
        "face", self.complex_face and self.complex_face.realname,
        "xtext", G_reader_settings:nilOrTrue("use_xtext"))
end

function WordWise:glossWidget(text, color)
    return TextWidget:new{ text = text, face = self.complex_face, padding = 0, fgcolor = color }
end

function WordWise:glossWidth(text, max_w)
    if needsShaping(text) then
        local tw = self:glossWidget(text)
        local w = tw:getSize().w
        tw:free()
        return w
    end
    return RenderText:sizeUtf8Text(0, max_w, self.gloss_face, text, true, false).x
end

function WordWise:drawGloss(bb, x, baseline, text, color)
    if needsShaping(text) then
        local tw = self:glossWidget(text, color)
        tw:paintTo(bb, x, baseline - tw:getBaseline())
        tw:free()
        return
    end
    RenderText:renderUtf8Text(bb, x, baseline, self.gloss_face, text, true, false, color)
end

function WordWise:setHintLevel(value)
    G_reader_settings:saveSetting("wordwise_hint_level", value)
    self:refresh()
end

function WordWise:setGlossFontSize(value)
    G_reader_settings:saveSetting("wordwise_gloss_font_size", value)
    -- rebuild the cached face; paintHints re-measures gloss widths from it
    self:loadGlossFaces(value)
    self:refresh()
end

function WordWise:setShowUnderline(on)
    G_reader_settings:saveSetting("wordwise_show_underline", on)
    self:refresh()
end

function WordWise:setEnabled(on)
    if on and not self:hasDB() then
        UIManager:show(InfoMessage:new{
            text = self:tr("no_db") .. WW_DIR,
        })
        return
    end
    self.ui.doc_settings:saveSetting("wordwise_enabled", on) -- per-book
    self:setLineSpacing(on) -- relayout + repaint; onPosUpdate recomputes hints
    if not on then
        self.hints = {}
        UIManager:setDirty("all", "ui")
    end
end

-- Menu ----------------------------------------------------------------------

function WordWise:onDispatcherRegisterActions()
    Dispatcher:registerAction("wordwise_toggle", {
        category = "none", event = "WordWiseToggle",
        title = self:tr("toggle"), reader = true,
    })
end

function WordWise:addToMainMenu(menu_items)
    menu_items.wordwise = {
        text = _("Word Wise"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:getSubMenu() end,
    }
end

function WordWise:getSubMenu()
    return {
        {
            text = self:tr("show_inline"),
            checked_func = function() return self:isEnabled() end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            callback = function() self:setEnabled(not self:isEnabled()) end,
        },
        {
            text_func = function()
                return self:tr("hint_level", self:getHintLevel())
            end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            sub_item_table_func = function()
                local items = {}
                local labels = {
                    self:tr("level_rarest"), "2", "3", "4",
                    self:tr("level_most"),
                }
                for d = 1, MAX_LEVEL do
                    items[d] = {
                        text = labels[d],
                        checked_func = function() return self:getHintLevel() == d end,
                        radio = true,
                        callback = function() self:setHintLevel(d) end,
                    }
                end
                return items
            end,
        },
        {
            text = self:tr("underline"),
            checked_func = function() return self:getShowUnderline() end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            callback = function() self:setShowUnderline(not self:getShowUnderline()) end,
        },
        {
            text_func = function()
                return self:tr("font_size_menu", self:getGlossFontSize())
            end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = self:tr("font_size_title"),
                    value = self:getGlossFontSize(),
                    value_min = GLOSS_FONT_MIN,
                    value_max = GLOSS_FONT_MAX,
                    default_value = GLOSS_FONT_SIZE,
                    keep_shown_on_apply = true, -- live preview as you slide/apply
                    callback = function(spin)
                        self:setGlossFontSize(spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
    }
end

function WordWise:onWordWiseToggle()
    self:setEnabled(not self:isEnabled())
    return true
end

return WordWise
