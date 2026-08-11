--[[--
This plugin removes the printed page number from the bottom of PDF/DjVu pages.

It injects two options into the KOpt (PDF/DjVu) settings dialog, between "Page Crop" and
"Margin":

* "Page Number Crop" (toggle, default on): each page is rendered at low resolution
  and the bottom strip is analyzed. Only the strip that clearly contains a page number is
  cropped; if no such strip is found (e.g. a manga panel reaching the bottom of the page),
  nothing is cropped, so no content is ever lost.

* "No crop on blank pages" (toggle, default off): a page that is almost entirely
  white (e.g. a chapter divider or a title page with only a small logo) is shown
  with no crop at all, instead of the auto page-crop zooming into that small
  element. Independent of the page-number crop.

The crop only applies when the "Page Crop" setting is "auto": the page-number strip (the
number plus its white gutter) is removed, so the crop reaches the bottom edge of the main
content (the bottom-most panel). When Page Crop is none/manual/semi-auto, the plugin is
inert.

The crop is applied to the page's bounding box, on top of the auto page crop, so it takes
effect in the content-fit zoom modes. The settings are stored per-book
(kopt_page_number_crop_auto, kopt_no_crop_blank_pages) like any other KOpt option.

@module koplugin.PageNumberCrop
--]]--

local Document = require("document/document")
local KoptOptions = require("ui/data/koptoptions")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local optionsutil = require("ui/data/optionsutil")
local logger = require("logger")
local _ = require("gettext")
local C_ = _.pgettext

-- Master switch for the page-number crop. Only usable when "Page Crop" is "auto";
-- for none/semi-auto/manual the toggle is greyed out (enabled_func below), which
-- also keeps the crop from being turned on in those modes.
local PAGE_NUMBER_CROP_AUTO_OPTION = {
    name = "page_number_crop_auto",
    name_text = _("Page Number Crop"),
    toggle = {C_("Page Number Crop", "off"), C_("Page Number Crop", "on")},
    values = {0, 1},
    default_value = 1,
    enabled_func = function(configurable)
        -- The crop only makes sense on top of the auto page crop, so the option is
        -- only active (and usable) when "Page Crop" is "auto" (trim_page == 1);
        -- for none/semi-auto/manual it is greyed out. Also not meaningful on
        -- reflowed documents.
        return configurable.text_wrap ~= 1 and configurable.trim_page == 1
    end,
    -- Fire the core "ReZoom" event directly (like the "Page Crop" option does), so
    -- the page is re-rendered with the new state even without this plugin's own
    -- event handler being involved.
    event = "ReZoom",
    args = {0, 1},
    name_text_hold_callback = optionsutil.showValues,
    help_text = _([[Master switch for the page-number crop.
This option is only available when "Page Crop" is set to "auto"; otherwise it is
greyed out.]]),
}

-- When "Page Crop" is "auto", a page that is almost entirely white -- e.g. a chapter
-- divider or a title page with only a small logo -- would be auto-cropped into that
-- lone small element. This option instead keeps such pages uncropped (an effective
-- "no crop" for that page), independent of the page-number crop above.
local NO_CROP_BLANK_PAGES_OPTION = {
    name = "no_crop_blank_pages",
    name_text = _("No crop on blank pages"),
    toggle = {C_("No crop on blank pages", "off"), C_("No crop on blank pages", "on")},
    values = {0, 1},
    default_value = 0,
    enabled_func = function(configurable)
        -- Same preconditions as the page-number crop: only meaningful on top of the
        -- auto page crop, and not on reflowed documents.
        return configurable.text_wrap ~= 1 and configurable.trim_page == 1
    end,
    -- Fire the core "ReZoom" event directly, like the page-number crop does, so the
    -- page is re-rendered with the new state.
    event = "ReZoom",
    args = {0, 1},
    name_text_hold_callback = optionsutil.showValues,
    help_text = _([[Do not crop almost-blank pages.
When "Page Crop" is "auto", a page that is almost entirely white -- e.g. a chapter
divider or a title page with only a small logo -- would otherwise be cropped into
that small element. When this option is enabled, such pages are shown with no crop
at all.]]),
}

local PageNumberCrop = WidgetContainer:extend{
    name = "pagenumbercrop",
    is_doc_only = true,
    -- Rendering/analysis tuning for the "no crop on blank pages" feature.
    BLANK_RENDER_MAX_PX = 256,     -- long edge of the low-res full-page analysis tile
    BLANK_MAX_CONTENT_AREA = 0.10, -- content box smaller than 10% of the page = "almost blank"
}

-- How often to silently check for updates in the background (once a week).
-- Manual checks from the menu are never rate-limited.
local UPDATE_CHECK_INTERVAL_S = 7 * 24 * 60 * 60

-- Lazily require the updater module, so a missing/broken updater file never
-- takes the whole plugin down with it (the crop feature itself never depends
-- on network access).
local function getUpdater()
    local ok, updater = pcall(require, "pagenumbercrop_updater")
    if not ok then
        logger.warn("PageNumberCrop: updater module not available:", updater)
        return nil
    end
    return updater
end

function PageNumberCrop:init()
    -- Update checking is unrelated to the crop feature itself (which only
    -- applies to KOpt/PDF/DjVu documents), so it runs regardless of document
    -- type, before the KOpt-only early return below.
    self:maybeCheckForUpdatesInBackground()
    self.ui.menu:registerToMainMenu(self)

    if not self.document.koptinterface then
        -- Only relevant to documents rendered through the KOpt engine
        -- (PDF/DjVu), where pages can be cropped via a bounding box.
        return
    end
    self:addOptionToConfigMenu()
    self:patchPageBBox()
    -- Seed the configurable value: ReaderConfig:loadDefaults runs before plugins
    -- are loaded, so it doesn't know about our injected option yet. The per-book
    -- value (kopt_page_number_crop_auto), if any, will override this via loadSettings.
    local configurable = self.document.configurable
    if configurable.page_number_crop_auto == nil then
        local auto = G_reader_settings:readSetting("kopt_page_number_crop_auto")
        configurable.page_number_crop_auto = auto == nil and 1 or auto
    end
    if configurable.no_crop_blank_pages == nil then
        local blank = G_reader_settings:readSetting("kopt_no_crop_blank_pages")
        configurable.no_crop_blank_pages = blank == nil and 0 or blank
    end
    self:_neutralizeLegacyCrop(configurable)
    logger.info("PageNumberCrop: active; auto-detect =",
        configurable.page_number_crop_auto,
        "; blank skip =", configurable.no_crop_blank_pages,
        "; trim_page =", configurable.trim_page,
        "; text_wrap =", configurable.text_wrap)
end

-- Runs a silent (no "checking…" popup) update check at most once every
-- UPDATE_CHECK_INTERVAL_S, tracked via a global setting so it applies across
-- all books, not per-book. Scheduled a few seconds out so it never competes
-- with the page render that's about to happen when a book is opened.
function PageNumberCrop:maybeCheckForUpdatesInBackground()
    local last = G_reader_settings:readSetting("pagenumbercrop_last_update_check") or 0
    if os.time() - last < UPDATE_CHECK_INTERVAL_S then
        return
    end
    G_reader_settings:saveSetting("pagenumbercrop_last_update_check", os.time())
    local updater = getUpdater()
    if not updater then
        return
    end
    UIManager:scheduleIn(3, function()
        local ok, err = pcall(updater.checkSilentForUpdates)
        if not ok then
            logger.warn("PageNumberCrop: background update check failed:", err)
        end
    end)
end

-- Adds a manual "check for updates" entry under the Reader's main menu
-- (Plugins section, where doc-only plugins with no menu of their own land).
function PageNumberCrop:addToMainMenu(menu_items)
    menu_items.page_number_crop_check_updates = {
        text = _("Page Number Crop: check for updates"),
        -- Where this shows up in the main menu tree; "more_tools" is the
        -- standard bucket for small utility plugins with no menu of their
        -- own (same one hello.koplugin/autostandby.koplugin use). Without
        -- this the item has nowhere to attach and never renders.
        sorting_hint = "more_tools",
        callback = function()
            local updater = getUpdater()
            if updater then
                updater.checkForUpdates()
            else
                UIManager:show(InfoMessage:new{
                    text = _("Updater module not found (pagenumbercrop_updater.lua is missing)."),
                })
            end
        end,
    }
end

-- The original core patch (page-number-crop.patch) rewrote KoptInterface:getPageBBox
-- to crop a fixed percentage of the page height (kopt_page_number_crop) in *every*
-- trim mode, with no auto-detect toggle. If that patch is still applied on the
-- device, its crop survives even when this option is off -- which is why turning
-- "Auto-detect page number" off used to not stop the crop. Since this plugin wraps
-- getPageBBox, its "off" path returned the already-cropped core bbox.
-- Neutralize the setting (the core patch reads it live on each render), after the
-- per-book settings are applied.
function PageNumberCrop:_neutralizeLegacyCrop(configurable)
    if type(configurable.page_number_crop) == "number" and configurable.page_number_crop > 0 then
        configurable.page_number_crop = 0
        logger.info("PageNumberCrop: neutralized legacy kopt_page_number_crop",
            "(old core patch still present?)")
    end
end

-- Called after per-book settings are loaded (ReaderConfig runs before plugins, so
-- configurable is fully populated here). Re-asserts the neutralization in case a
-- saved per-book kopt_page_number_crop was just loaded.
function PageNumberCrop:onReadSettings(config)
    self:_neutralizeLegacyCrop(self.document.configurable)
end

-- Insert the options into the KOpt settings dialog, between "Page Crop" and "Margin".
-- Also drop the obsolete fixed-% crop option from the original core patch, so it
-- can't be re-enabled and crop the page number again.
function PageNumberCrop:addOptionToConfigMenu()
    for _, tab in ipairs(KoptOptions) do
        if tab.icon == "appbar.crop" then
            local removed_legacy = false
            for i = #tab.options, 1, -1 do
                local option = tab.options[i]
                if option.name == "page_number_crop" then
                    -- Legacy option from page-number-crop.patch: crops a fixed % of
                    -- the page in every trim mode, with no auto-detect. Superseded
                    -- by the auto-detect option.
                    table.remove(tab.options, i)
                    removed_legacy = true
                end
                if option.name == "trim_page" then
                    -- Insert our options right after "Page Crop", skipping any that are
                    -- already present (e.g. from a previous document or upgrade).
                    local has_auto, has_blank = false, false
                    for _, o in ipairs(tab.options) do
                        if o.name == "page_number_crop_auto" then has_auto = true end
                        if o.name == "no_crop_blank_pages" then has_blank = true end
                    end
                    local insert_at = i + 1
                    if not has_auto then
                        table.insert(tab.options, insert_at, PAGE_NUMBER_CROP_AUTO_OPTION)
                    end
                    insert_at = insert_at + 1
                    if not has_blank then
                        table.insert(tab.options, insert_at, NO_CROP_BLANK_PAGES_OPTION)
                    end
                    if removed_legacy then
                        logger.info("PageNumberCrop: removed legacy 'Page number crop' option")
                    end
                    return
                end
            end
        end
    end
end

-- Wrap the document's getPageBBox so the page-number strip is cropped out of the
-- auto page-crop bbox. Only active when "Page Crop" is "auto" (trim_page == 1) and
-- the option is enabled.
function PageNumberCrop:patchPageBBox()
    if self.document._page_number_crop_patched then
        return
    end
    self.document._page_number_crop_patched = true
    local document = self.document
    local orig_getPageBBox = document.getPageBBox
    -- Per-page detection cache, in native (bbox) units. Filled lazily.
    document._pagenum_cache = {}
    document._pagenum_blank_cache = {}
    -- Rolling history of accepted detections (as a fraction of page height),
    -- used to sanity-check new detections against where the number has
    -- consistently been on earlier pages of this book.
    document._pagenum_history = {}
    document.getPageBBox = function(self, pageno)
        local configurable = self.configurable
        -- Reflowed PDFs have no printed page numbers, and the analysis render must
        -- see the uncropped bbox (see _pagenum_strip below). The crop only makes
        -- sense on top of the auto page crop. Each feature is independent: the
        -- page-number crop additionally needs page_number_crop_auto == 1, while the
        -- blank-page skip needs no_crop_blank_pages == 1.
        -- NOTE: 0 is truthy in Lua, so these option values must be compared to
        -- a concrete truth (== 1), not used directly as booleans.
        local auto = configurable and configurable.page_number_crop_auto
        local blank = configurable and configurable.no_crop_blank_pages
        local auto_crop = configurable and configurable.text_wrap ~= 1
            and configurable.trim_page == 1
        local crop_active = auto_crop and (auto == 1 or auto == "1")
        local blank_active = auto_crop and (blank == 1 or blank == "1")
        local active = crop_active or blank_active
        if self._pagenum_state ~= active then
            -- Log once per state change, so logs show exactly when the plugin turns
            -- on and off (and why).
            self._pagenum_state = active
            logger.info("PageNumberCrop: state ->", active and "active" or "inactive",
                "(auto-detect =", configurable and configurable.page_number_crop_auto,
                ", blank skip =", configurable and configurable.no_crop_blank_pages,
                ", trim_page =", configurable and configurable.trim_page, ")")
        end
        if self._pagenum_analysis_flag or not active then
            return orig_getPageBBox(self, pageno)
        end
        local bbox = orig_getPageBBox(self, pageno)
        if not bbox then
            return bbox
        end

        -- Almost-blank pages (a chapter divider, a title page with only a small
        -- logo...) are shown with no crop at all: the whole page, instead of the
        -- auto page-crop zooming into the lone small element. This also skips the
        -- page-number crop below for those pages.
        if blank_active and self:_page_mostly_blank(pageno) then
            local page_size = self:getNativePageDimensions(pageno)
            return { x0 = 0, y0 = 0, x1 = page_size.w, y1 = page_size.h }
        end

        if crop_active then
            -- New bottom edge: the bottom of the main content (the bottom-most panel),
            -- i.e. everything below it -- the white gutter and the page number -- is
            -- cropped. 0 when no page number was detected.
            local crop_y = self:_pagenum_strip(pageno)
            if crop_y and crop_y > 0 and crop_y > bbox.y0 and crop_y < bbox.y1 then
                -- Only crop when we're actually removing a meaningful strip (the number
                -- and its gutter). A one-pixel difference means the auto crop already
                -- handled it, and we must never shave into the content itself.
                local page_size = self:getNativePageDimensions(pageno)
                local min_removal = page_size and math.max(1, page_size.h * 0.001) or 1
                if bbox.y1 - crop_y >= min_removal then
                    -- Copy the bbox so we don't mutate a potentially shared/cached one.
                    bbox = { x0 = bbox.x0, y0 = bbox.y0, x1 = bbox.x1, y1 = bbox.y1 }
                    bbox.y1 = crop_y
                end
            end
        end
        return bbox
    end
    -- Detect the native y-coordinate where the crop should end: right below the
    -- bottom-most panel, above the page-number strip and its white gutter.
    -- Returns 0 when no page number is detected (so nothing gets cropped).
    document._pagenum_strip = function(self, pageno)
        local cached = self._pagenum_cache[pageno]
        if cached ~= nil then
            return cached
        end
        self._pagenum_cache[pageno] = 0 -- fill first, so detection is re-entrant-safe
        local page_size = self:getNativePageDimensions(pageno)
        if not (page_size and page_size.w > 0 and page_size.h > 0) then
            logger.info("PageNumberCrop: page", pageno, "no page number [ no render (page_size) ]")
            self._pagenum_cache[pageno] = 0
            return 0
        end

        -- Render (uncropped, unrotated, no gamma shift) only the bottom strip of
        -- the page at the given zoom, and analyze it. Rendering just the strip --
        -- instead of the whole page at a small fixed zoom -- is what makes
        -- high-resolution manga legible: at a full-page render downscaled to a
        -- small fixed width, thin-font number strokes fall below one pixel and
        -- vanish. `zoom` controls how much of that legibility we pay for.
        local analyze_frac = 0.15
        local strip_h_nat = math.max(1, math.floor(page_size.h * analyze_frac))
        local strip_y0_nat = page_size.h - strip_h_nat
        local function renderAndAnalyze(zoom)
            self._pagenum_analysis_flag = true
            local ok, result, info, suspicious = pcall(function()
                -- The strip in native page coordinates, plus its pre-scaled size, so
                -- Document.renderPage renders exactly this strip (never a full-page
                -- tile at this zoom, and the tile is not dumped to the disk cache).
                local rect = Geom:new{
                    x = 0, y = strip_y0_nat,
                    w = page_size.w, h = strip_h_nat,
                }
                rect.scaled_rect = self:transformRect(rect, zoom, 0)
                local tile = Document.renderPage(self, pageno, rect, zoom, 0, 1.0, 1.0, false)
                if not tile or not tile.bb then
                    return 0, "render returned no tile", false
                end
                -- tile.bb is the bottom strip; analyze the whole of it, then convert
                -- the y from strip-local to page-native pixels.
                local rel_y, rel_detail, rel_suspicious = PageNumberCrop.analyzeStrip(tile.bb, 0)
                if rel_y > 0 then
                    rel_y = strip_y0_nat + rel_y / zoom
                end
                return rel_y, rel_detail, rel_suspicious
            end)
            self._pagenum_analysis_flag = false
            if ok and type(result) == "number" then
                return result, info or "", suspicious or false
            end
            return 0, "analysis error: " .. tostring(result), false
        end

        -- Fast path: the cheap zoom that has worked fine for the vast majority of
        -- books (including small/medium-resolution manga). Cap 700px/2.0x keeps
        -- this render small, so most pages pay only this cost.
        local zoom_fast = math.min(700 / strip_h_nat, 2.0)
        local crop_y, detail, suspicious = renderAndAnalyze(zoom_fast)
        local used_fallback = false

        -- Fallback path: only paid when the fast pass found nothing but noise
        -- (a handful of stray dark pixels near the edge -- see analyzeStrip),
        -- which is the signature of a thin/anti-aliased number that didn't
        -- survive the fast zoom's downscale on a large/high-res page. Re-render
        -- the same strip sharper. This only fires for the minority of "hard"
        -- pages, so most pages never pay this extra cost.
        if crop_y == 0 and suspicious then
            local zoom_fallback = math.min(1000 / strip_h_nat, 2.5)
            local crop_y2, detail2, _ = renderAndAnalyze(zoom_fallback)
            used_fallback = true
            if crop_y2 > 0 then
                crop_y, detail = crop_y2, detail2 .. " [fallback zoom]"
            else
                detail = detail .. " | fallback zoom: " .. detail2
            end
        end

        -- Consistency check: the printed page number sits at (almost) the same
        -- relative position on every page of a book. Compare this detection
        -- against the median of previously accepted ones (as a fraction of page
        -- height, so it still works if the book mixes page sizes). A detection
        -- that's wildly off is very likely a false positive (some other small
        -- dark element near the bottom edge), not a real page-number move --
        -- reject it rather than risk cropping real content.
        if crop_y > 0 then
            local history = self._pagenum_history
            local frac = crop_y / page_size.h
            if #history >= 3 then
                local sorted = {}
                for _, f in ipairs(history) do sorted[#sorted + 1] = f end
                table.sort(sorted)
                local median = sorted[math.ceil(#sorted / 2)]
                local tolerance = 0.03 -- 3% of page height
                if math.abs(frac - median) > tolerance then
                    if not used_fallback then
                        local zoom_fallback = math.min(1000 / strip_h_nat, 2.5)
                        local crop_y2, detail2 = renderAndAnalyze(zoom_fallback)
                        local frac2 = crop_y2 > 0 and (crop_y2 / page_size.h) or nil
                        if frac2 and math.abs(frac2 - median) <= tolerance then
                            crop_y, detail, frac = crop_y2,
                                detail2 .. " [fallback zoom, matched history]", frac2
                        else
                            detail = detail .. string.format(
                                " | outlier vs history (median=%.3f) after fallback -> skip crop", median)
                            crop_y = 0
                        end
                    else
                        detail = detail .. string.format(
                            " | outlier vs history (median=%.3f) -> skip crop", median)
                        crop_y = 0
                    end
                end
            end
            if crop_y > 0 then
                table.insert(history, frac)
                if #history > 30 then
                    table.remove(history, 1) -- bound memory on very long books
                end
            end
        end

        if crop_y > 0 then
            logger.warn("PageNumberCrop: page", pageno, "crop y =",
                string.format("%.1f", crop_y), "[", detail, "]")
        else
            logger.info("PageNumberCrop: page", pageno, "no page number [", detail, "]")
        end
        self._pagenum_cache[pageno] = crop_y
        return crop_y
    end

    -- Decide whether the page is "almost entirely white" (only a small amount of
    -- content, e.g. a lone logo), in which case the caller shows it with no crop.
    -- Cached per page; returns false on any failure, so a normal crop is attempted.
    document._page_mostly_blank = function(self, pageno)
        local cached = self._pagenum_blank_cache[pageno]
        if cached ~= nil then
            return cached
        end
        -- Fill first, so a re-entrant render (renderPage -> getPageBBox) never
        -- recurses on this page.
        self._pagenum_blank_cache[pageno] = false
        local page_size = self:getNativePageDimensions(pageno)
        if not (page_size and page_size.w > 0 and page_size.h > 0) then
            logger.info("PageNumberCrop: page", pageno,
                "blank check skipped [ no render (page_size) ]")
            return false
        end

        -- Render the whole page at low resolution -- the long edge capped at
        -- BLANK_RENDER_MAX_PX -- and measure how much of it is inked. Rendering the
        -- whole page (not a strip) is what makes the "almost entirely white" test
        -- meaningful, and the small tile keeps the extra cost low.
        local zoom = math.min(
            PageNumberCrop.BLANK_RENDER_MAX_PX / page_size.w,
            PageNumberCrop.BLANK_RENDER_MAX_PX / page_size.h,
            1.0)
        self._pagenum_analysis_flag = true
        local ok, mostly_blank = pcall(function()
            local rect = Geom:new{ x = 0, y = 0, w = page_size.w, h = page_size.h }
            rect.scaled_rect = self:transformRect(rect, zoom, 0)
            local tile = Document.renderPage(self, pageno, rect, zoom, 0, 1.0, 1.0, false)
            if not tile or not tile.bb then
                return false
            end
            return PageNumberCrop.pageMostlyBlank(tile.bb)
        end)
        self._pagenum_analysis_flag = false
        if ok and type(mostly_blank) == "boolean" then
            self._pagenum_blank_cache[pageno] = mostly_blank
            if mostly_blank then
                logger.info("PageNumberCrop: page", pageno, "mostly blank -> no crop")
            end
            return mostly_blank
        end
        logger.warn("PageNumberCrop: blank analysis error:", mostly_blank)
        return false
    end
end

--[[--
Detect the page-number strip at the bottom of a rendered page and return the
y-coordinate where the crop should end: the bottom edge of the main content (the
bottom-most panel). Everything from the page number and its white gutter is cropped.

If no such strip is found, 0 is returned (nothing gets cropped), so content that
reaches the bottom of the page is never cut into.

@param bb Blitbuffer of the rendered page (any orientation, unrotated).
@treturn number y-coordinate of the crop edge (pixels from the top), 0 when nothing
    should be cropped.
@treturn[opt] string a short human-readable summary of the detection metrics.
@treturn[opt] boolean true when nothing but noise was found and a sharper re-render
    (higher zoom) might recover a real detection; false for any other outcome
    (including "nothing to crop" outcomes that are not resolution-related).
--]]
function PageNumberCrop.analyzeStrip(bb, y_start_override)
    local w, h = bb.w, bb.h
    if not w or not h or w < 20 or h < 40 then
        return 0, "tiny page"
    end
    -- By default analyze only the bottom 15% of the page; the caller can pass a bb
    -- that already is the bottom strip (the analysis render) and set
    -- y_start_override = 0 to analyze the whole of it.
    local analyze_frac = 0.15
    local y_start = y_start_override
        or math.max(0, math.floor(h * (1 - analyze_frac)))
    -- A row counts as "inked" above this ratio of dark columns. Deliberately low:
    -- a thin-font number on a high-resolution page renders with only a few dark
    -- pixels per row (the log showed such numbers registering as a single 1px
    -- band), so 0.5% was too strict and discarded every row but the darkest one.
    local ink_threshold = 0.002
    -- Only clearly-dark pixels count as ink. 128 (mid-gray) instead of the previous
    -- 160: at the low analysis resolution, a thin font's anti-aliased edges smear
    -- into light-gray pixels that 160 counts as ink, making a sparse page number
    -- look like a dense panel-like band.
    local dark_threshold = 128 -- grayscale value below which a pixel counts as ink
    local x_step = 2 -- sample every other column for speed

    local function isDark(color)
        -- color is a color cdata object (Color8/ColorRGB24/ColorRGB32/...) returned
        -- by bb:getPixel. getColor8() is blitbuffer's own canonical grayscale
        -- conversion: for an already-8bpp-grayscale tile (the common case for a
        -- render meant only for analysis, not display) it's a no-op (`return self`,
        -- see koreader-base/ffi/blitbuffer.lua), and for RGB tiles it's a single
        -- luma-weighted conversion done in fixed-point -- cheaper and more accurate
        -- than averaging getR()/getG()/getB() ourselves in Lua.
        return color:getColor8().a < dark_threshold
    end

    -- Lazily compute & cache a row's ink ratio and horizontal ink span. Scanning
    -- proceeds bottom-up and stops as soon as the bottom-most panel is found --
    -- typically well above y_start, since the last panel on a page usually starts
    -- much higher than the bottom 15% -- so rows above that point are never even
    -- read. This is the main cost of this function (up to ~1M getPixel calls on a
    -- large page), so avoiding the unused part of the window matters.
    local ink = {}
    local span = {}
    local cols = math.ceil(w / x_step)
    local function scanRow(y)
        local count = 0
        local xmin, xmax = w, -1
        for x = 0, w - 1, x_step do
            if isDark(bb:getPixel(x, y)) then
                count = count + 1
                if x < xmin then xmin = x end
                if x > xmax then xmax = x end
            end
        end
        ink[y] = count / cols
        span[y] = (xmax >= xmin) and (xmax - xmin + 1) or 0
    end
    local function inkAt(y)
        if ink[y] == nil then
            scanRow(y)
        end
        return ink[y]
    end

    -- A page number is a small, sparse, narrow glyph near the bottom edge. Panels
    -- (or panel floors) are denser and wider, so those limits are what reject them.
    -- Height is only a secondary signal: a large or outlined number may be tall.
    local max_row_ink = 0.30 -- a row through a page number is mostly white
    local max_band_span = w * 0.60 -- a page number never spans most of the width
    local max_band_h = math.max(2, h * 0.04) -- typical page numbers are small
    local max_big_band_h = math.max(3, h * 0.15) -- a huge number, if sparse & narrow
    local min_gutter_h = math.max(1, math.floor(h * 0.01))
    -- A handful of stray dark pixels (scan/compression artifacts, a couple of
    -- anti-aliased columns) can register as ink at the very low ink_threshold,
    -- forming a "band" only a few pixels wide. A real digit stroke always spans a
    -- meaningfully wider horizontal run. Bands narrower than this are treated as
    -- if they were white space instead of a number/panel candidate -- this both
    -- stops noise from being mistaken for the number and lets real digit strokes
    -- merge across noise into a single stack rather than the stack breaking (and
    -- the crop landing mid-number).
    local min_band_span = math.max(3, math.floor(w * 0.005))

    -- Skip any white margin at the very bottom edge.
    local y = h - 1
    while y >= y_start and inkAt(y) <= ink_threshold do
        y = y - 1
    end
    if y < y_start then
        return 0, "no ink at the bottom"
    end

    -- Scan upward, closing off one ink band at a time and classifying it
    -- immediately. Stops the moment a panel-like (real, non-noise) band is
    -- found: either it's the very first one (nothing to crop -- a panel reaches
    -- the bottom edge) or a later one (the anchor for the crop point, i.e. the
    -- panel floor above the page number). Either way, nothing above it is
    -- relevant, so those rows are never read.
    local bands = {}
    local descr = {}
    while y >= y_start do
        local bottom = y
        local top = y
        local b_ink, b_span = 0, 0
        local panel_like = false
        while y >= y_start and inkAt(y) > ink_threshold do
            top = y
            if ink[y] > b_ink then b_ink = ink[y] end
            if span[y] > b_span then b_span = span[y] end
            if not panel_like and (b_ink > max_row_ink or b_span > max_band_span) then
                -- panel_like is an "any row in this run exceeds the threshold"
                -- condition, so one qualifying row is enough to decide it -- no
                -- need to keep extending upward just to find this band's exact
                -- top. This is what turns scanning a large solid panel into just
                -- the handful of rows it took to become unambiguously panel-like.
                panel_like = true
                y = y - 1
                break
            end
            y = y - 1
        end

        local h_str = tostring(bottom - top + 1)
        if panel_like then h_str = ">=" .. h_str end -- top is a lower bound when short-circuited
        table.insert(descr, string.format("h=%s ink=%.2f span=%d%%%s",
            h_str, b_ink, math.floor(b_span / w * 100), panel_like and " PANEL" or ""))

        if b_span >= min_band_span then -- a real (non-noise) band
            if panel_like then
                local detail = "bands(" .. #descr .. ") " .. table.concat(descr, ", ")
                if #bands == 0 then
                    -- A panel reaching the bottom edge of the page: there is
                    -- nothing below it to crop, hence no removable page-number strip.
                    return 0, "panel reaches the bottom [" .. detail .. "]"
                end
                -- The bottom-most ink was sparse & narrow: the page number -- but
                -- possibly only its darker part, since on high-resolution pages the
                -- number's faint upper strokes render as sparse bands of their own
                -- (the log showed numbers cropping at a 1-7px gutter, i.e.
                -- mid-number, because the crop anchored on the darker bottom part
                -- and the faint top remained visible). Anchor the crop on this
                -- panel-like band instead -- the panel floor -- so the whole number
                -- (faint top included) and the margin below the last panel are
                -- removed.
                local log_detail = string.format("crop_y=%d %s", bottom, detail)
                return bottom, log_detail
            end
            table.insert(bands, { top = top, bottom = bottom, row_ink = b_ink, span = b_span })
        end

        -- Skip the white gap above this band before looking for the next one.
        while y >= y_start and inkAt(y) <= ink_threshold do
            y = y - 1
        end
    end

    -- No panel-like band anywhere in the window: the bottom strip is just the
    -- page number (plus margin).
    local detail = "bands(" .. #descr .. ") " .. table.concat(descr, ", ")
    if #bands == 0 then
        return 0, "only noise bands [" .. detail .. "]", true
    end
    local first = bands[1]

    -- No panel-like band in the window: the bottom strip is just the page number
    -- (plus margin). Crop above it as before, extending past the sparse bands that
    -- are faint parts of the same number, so we don't stop mid-number.
    local stack_top = first.top
    local prev_top = first.top
    for i = 2, #bands do
        -- A band is part of the same number when it starts close above the stack.
        local gap = prev_top - bands[i].bottom - 1
        if gap <= math.max(min_gutter_h, h * 0.02) then
            stack_top = bands[i].top
            prev_top = bands[i].top
        else
            break
        end
    end
    local band_h = first.bottom - stack_top + 1

    -- White gutter above the stack (separates the number from the content).
    local gutter_len = 0
    local yy = stack_top - 1
    while yy >= y_start and ink[yy] <= ink_threshold do
        gutter_len = gutter_len + 1
        yy = yy - 1
    end

    local fallback_detail = string.format("band_h=%d row_ink=%.2f span=%d%% gutter=%dpx",
        band_h, first.row_ink, math.floor(first.span / w * 100), gutter_len)

    -- A sparse & narrow band can only be a number (or small standalone text).
    -- Height is allowed to be large when the band is separated from the content by
    -- a white gutter; a band glued to the content is only accepted when small, so
    -- we don't crop a tall text column that happens to be sparse.
    local glued = gutter_len < min_gutter_h
    if band_h > max_band_h and (glued or band_h > max_big_band_h) then
        return 0, "band too tall (" .. band_h .. " px) [" .. fallback_detail .. "]"
    end

    -- There must be content above the stack (more than just the page number).
    local has_content = false
    for ry = y_start, math.max(y_start, yy) do
        if ink[ry] > ink_threshold then
            has_content = true
            break
        end
    end
    if not has_content then
        return 0, "no content above the band [" .. fallback_detail .. "]"
    end

    -- Crop edge: the bottom of the content above the gutter (the bottom-most panel),
    -- so the gutter and the page number below it are cropped. When the number sits
    -- flush against the content (gutter 0), crop_y == stack_top: exactly the number's
    -- top edge, which removes the number without shaving any pixel of the content.
    local crop_y = stack_top - gutter_len
    local log_detail = string.format("crop_y=%d %s", crop_y, fallback_detail)
    return crop_y, log_detail
end

--[[--
Detect an "almost entirely white" page: the inked content fits inside a small box
relative to the page (e.g. a lone logo on a chapter divider or title page). Such
pages are shown with no crop at all, so the auto page-crop doesn't zoom into that
small element.

@param bb Blitbuffer of the full page rendered at low resolution.
@treturn boolean true when the page is almost entirely white.
--]]
function PageNumberCrop.pageMostlyBlank(bb)
    local w, h = bb.w, bb.h
    if not w or not h or w < 20 or h < 20 then
        return false
    end
    -- Only clearly-dark pixels count as content (same threshold as analyzeStrip).
    local dark_threshold = 128
    local x_step, y_step = 2, 2 -- sample every other pixel, for speed

    local found = false
    local xmin, ymin, xmax, ymax = w, h, -1, -1
    for y = 0, h - 1, y_step do
        for x = 0, w - 1, x_step do
            if bb:getPixel(x, y):getColor8().a < dark_threshold then
                found = true
                if x < xmin then xmin = x end
                if x > xmax then xmax = x end
                if y < ymin then ymin = y end
                if y > ymax then ymax = y end
            end
        end
    end
    if not found then
        return true -- a fully blank page
    end
    -- The content box as a fraction of the page area. Below BLANK_MAX_CONTENT_AREA
    -- the page is almost entirely white: keep it uncropped.
    local content_area = (xmax - xmin + 1) * (ymax - ymin + 1) / (w * h)
    return content_area < PageNumberCrop.BLANK_MAX_CONTENT_AREA
end

return PageNumberCrop