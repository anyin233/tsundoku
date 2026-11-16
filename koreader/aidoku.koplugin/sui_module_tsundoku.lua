--[[--
SimpleUI Bento modules provided by Tsundoku (積読):
  1. `tsundoku_hub`: Compact Bento action hub placed beside Clock on the Home
     Screen with one-tap entry to Manga Library, Global Book Search, and
     Koobone Subscription Refresh (long-press opens Koobone Shelf), plus an
     optional Downloads tile and live sync/queue indicator.
  2. `tsundoku_series`: Swipeable/grid Manga Series shelf rendered using
     SimpleUI's GroupCell & GridRenderer (enableable via Edit Home Screen
     or Tabbed Grid via the registered `tsundoku` group source).
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local Screen = Device.screen

local function safeRequire(name)
    local ok, mod = pcall(require, name)
    if ok then
        return mod
    end
    return nil
end

local function makeText(UI, opts)
    if UI and type(UI.makeColoredText) == "function" then
        local ok, w = pcall(UI.makeColoredText, opts)
        if ok and w then
            return w
        end
    end
    return TextWidget:new{
        text = opts.text,
        face = opts.face,
        bold = opts.bold,
        fgcolor = opts.fgcolor,
        max_width = opts.max_width,
        padding = opts.padding or 0,
    }
end

local function makeTileIcon(QARenderer, tile, sz, blk_ink, tint)
    if QARenderer and type(QARenderer.buildIcon) == "function" then
        local ok, w = pcall(
            QARenderer.buildIcon,
            { icon = tile.icon, label = tile.label },
            sz,
            blk_ink,
            { tint = tint, container_w = sz, container_h = sz }
        )
        if ok and w then
            return w
        end
    end
    local iw = ImageWidget:new{
        file = tile.icon,
        width = sz,
        height = sz,
        is_icon = true,
        alpha = true,
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = sz, h = sz },
        iw,
    }
end

local function safeColor(c)
    if not c then
        return nil
    end
    local ok, valid = pcall(function()
        return type(c.getColorRGB32) == "function"
    end)
    if ok and valid then
        return c
    end
    return nil
end

local function guardPaintTo(widget, tag)
    if not widget or type(widget.paintTo) ~= "function" then
        return widget
    end
    local orig_paint = widget.paintTo
    widget.paintTo = function(self_w, bb, x, y)
        local ok, err = pcall(orig_paint, self_w, bb, x, y)
        if not ok then
            logger.warn(tag or "tsundoku_sui_module", "paintTo error:", tostring(err))
        end
    end
    return widget
end

local SETTING_SHOW_HEADER = "tsundoku_hub_show_header"
local SETTING_SHOW_DOWNLOADS = "tsundoku_hub_show_downloads"

local M = {}

local function showHeader(SUISettings, pfx)
    return SUISettings:nilOrTrue(pfx .. SETTING_SHOW_HEADER)
end

local function setShowHeader(SUISettings, pfx, v)
    SUISettings:saveSetting(pfx .. SETTING_SHOW_HEADER, v and true or false)
end

local function showDownloadsTile(SUISettings, pfx)
    return SUISettings:isTrue(pfx .. SETTING_SHOW_DOWNLOADS)
end

local function setShowDownloadsTile(SUISettings, pfx, v)
    SUISettings:saveSetting(pfx .. SETTING_SHOW_DOWNLOADS, v and true or false)
end

local function computeHubDims(scale, SUIStyle)
    scale = scale or 1.0
    local fs_detail = (SUIStyle and SUIStyle.FS_DETAIL) or 15
    local fs_caption = (SUIStyle and SUIStyle.FS_CAPTION) or 12
    return {
        scale = scale,
        header_fs = math.max(9, math.floor(fs_detail * scale)),
        status_fs = math.max(8, math.floor(fs_caption * scale)),
        header_h = math.max(16, math.floor(Screen:scaleBySize(17) * scale)),
        header_gap = math.max(3, math.floor(Screen:scaleBySize(5) * scale)),
        tile_h = math.max(46, math.floor(Screen:scaleBySize(52) * scale)),
        icon_sz = math.max(16, math.floor(Screen:scaleBySize(22) * scale)),
        icon_gap = math.max(2, math.floor(Screen:scaleBySize(3) * scale)),
        label_fs = math.max(9, math.floor(fs_caption * 1.05 * scale)),
        tile_gap = math.max(4, math.floor(Screen:scaleBySize(6) * scale)),
        tile_radius = math.max(3, math.floor(Screen:scaleBySize(6) * scale)),
    }
end

local function buildTileCard(tile, tile_w, d, ctx, UI, SUIStyle, QARenderer, plain_ink)
    local ink_tbl = type(ctx and ctx.ink) == "table" and ctx.ink or plain_ink
    local blk_ink = safeColor(ink_tbl.blk) or safeColor(SUIStyle.COLOR and SUIStyle.COLOR.text_primary) or Blitbuffer.COLOR_BLACK
    local sub_ink = safeColor(ink_tbl.sub) or safeColor(SUIStyle.COLOR and SUIStyle.COLOR.text_dim) or blk_ink
    local tint = (ink_tbl ~= plain_ink) or nil
    local border = SUIStyle.BORDER_SZ or 1
    local face_reg = SUIStyle.FACE_REGULAR or "cfont"
    local inner_w = math.max(12, tile_w - 2 * border)
    local inner_h = math.max(12, d.tile_h - 2 * border)

    local icon_w = makeTileIcon(QARenderer, tile, d.icon_sz, blk_ink, tint)

    local lbl_w = makeText(UI, {
        text = tile.label,
        face = Font:getFace(face_reg, d.label_fs),
        bold = true,
        fgcolor = tint and blk_ink or nil,
        max_width = math.max(12, inner_w - Screen:scaleBySize(8)),
        padding = 0,
    })
    if tile.sub_label and tile.sub_label ~= "" then
        lbl_w = makeText(UI, {
            text = tile.sub_label,
            face = Font:getFace(face_reg, d.label_fs),
            bold = true,
            fgcolor = tile.active and (tint and blk_ink or nil) or sub_ink,
            max_width = math.max(12, inner_w - Screen:scaleBySize(8)),
            padding = 0,
        })
    end

    local stack = VerticalGroup:new{
        align = "center",
        icon_w,
        VerticalSpan:new{ width = d.icon_gap },
        lbl_w,
    }

    local card_bg = (ctx and ctx.text_alpha) and nil or (SUIStyle.COLOR and SUIStyle.COLOR.surface) or Blitbuffer.COLOR_WHITE
    local frame = FrameContainer:new{
        bordersize = border,
        color = blk_ink,
        background = card_bg,
        radius = d.tile_radius,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            stack,
        },
    }

    local tappable = InputContainer:new{
        dimen = Geom:new{ w = tile_w, h = d.tile_h },
        [1] = frame,
    }
    local tap_ev = "TapTsundoku_" .. tile.id
    tappable.ges_events = {
        [tap_ev] = {
            GestureRange:new{
                ges = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    tappable["on" .. tap_ev] = function()
        if tile.on_tap then
            tile.on_tap()
        end
        return true
    end
    if type(tile.on_hold) == "function" then
        local hold_ev = "HoldTsundoku_" .. tile.id
        local hold_rel_ev = "HoldReleaseTsundoku_" .. tile.id
        tappable.ges_events[hold_ev] = {
            GestureRange:new{
                ges = "hold",
                range = function() return tappable.dimen end,
            },
        }
        tappable.ges_events[hold_rel_ev] = {
            GestureRange:new{
                ges = "hold_release",
                range = function() return tappable.dimen end,
            },
        }
        tappable["on" .. hold_ev] = function()
            return true
        end
        tappable["on" .. hold_rel_ev] = function()
            tile.on_hold()
            return true
        end
    end
    if UI.makeFocusable then
        UI.makeFocusable(tappable, tappable["on" .. tap_ev])
    end
    return tappable
end

function M.buildModules(bridge)
    local Chrome = safeRequire("features/sui_module_chrome")
    local Config = safeRequire("infra/sui_config")
    local SUISettings = safeRequire("infra/sui_store")
    local UI = safeRequire("infra/sui_core")
    local SUIStyle = safeRequire("features/sui_style")
    local QARenderer = safeRequire("engines/sui_quickactions_render")
    local GridRenderer = safeRequire("engines/sui_book_grid")
    local GroupCell = safeRequire("engines/sui_group_cell")

    if not (Config and SUISettings and SUIStyle) then
        logger.warn("tsundoku_sui_module: core SimpleUI modules unavailable")
        return nil, nil
    end

    local plain_ink = (Chrome and Chrome.PLAIN_INK) or {
        blk = (SUIStyle.COLOR and SUIStyle.COLOR.text_primary) or Blitbuffer.COLOR_BLACK,
        sub = (UI and UI.CLR_TEXT_SUB) or (SUIStyle.COLOR and SUIStyle.COLOR.text_dim) or Blitbuffer.COLOR_BLACK,
    }
    local face_reg = SUIStyle.FACE_REGULAR or "cfont"

    local hub_mod
    local ok_hub, err_hub = pcall(function()
        hub_mod = {
            id = "tsundoku_hub",
            name = _.brandName(),
            label = nil, -- Keeps Row 1 compact beside Clock with no tall outside caption.
            category = "shortcuts",
            enabled_key = "tsundoku_hub_enabled",
            default_on = true,
        }

        function hub_mod.build(w, ctx)
            local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
            local lf = (ctx and ctx.landscape_factor) or 1
            local base_scale = type(Config.getModuleScale) == "function"
                and Config.getModuleScale(hub_mod.id, pfx) or 1.0
            local scale = base_scale * lf
            local d = computeHubDims(scale, SUIStyle)
            local summary = bridge.getSummary()

            local ink_tbl = type(ctx and ctx.ink) == "table" and ctx.ink or plain_ink
            local blk_ink = safeColor(ink_tbl.blk) or safeColor(SUIStyle.COLOR and SUIStyle.COLOR.text_primary) or Blitbuffer.COLOR_BLACK
            local sub_ink = safeColor(ink_tbl.sub) or safeColor(SUIStyle.COLOR and SUIStyle.COLOR.text_dim) or blk_ink
            local tint = (ink_tbl ~= plain_ink) or nil

            local rows = VerticalGroup:new{ align = "left" }

            if showHeader(SUISettings, pfx) then
                local status_text
                if summary.syncing then
                    status_text = "↻ " .. _("Syncing…")
                elseif summary.queue_count > 0 then
                    status_text = T(_("↓ %1 queued"), summary.queue_count)
                else
                    status_text = T(_("%1 series"), summary.series_count or 0)
                end

                local title_w = makeText(UI, {
                    text = _.brandName(),
                    face = Font:getFace(face_reg, d.header_fs),
                    bold = true,
                    fgcolor = tint and blk_ink or nil,
                    max_width = math.max(40, math.floor(w * 0.45)),
                    padding = 0,
                })
                local status_w = makeText(UI, {
                    text = status_text,
                    face = Font:getFace(face_reg, d.status_fs),
                    fgcolor = sub_ink,
                    max_width = math.max(40, math.floor(w * 0.52)),
                    padding = 0,
                })

                local header = OverlapGroup:new{
                    dimen = Geom:new{ w = w, h = d.header_h },
                    LeftContainer:new{
                        dimen = Geom:new{ w = w, h = d.header_h },
                        title_w,
                    },
                    RightContainer:new{
                        dimen = Geom:new{ w = w, h = d.header_h },
                        status_w,
                    },
                }
                rows[#rows + 1] = header
                rows[#rows + 1] = VerticalSpan:new{ width = d.header_gap }
            end

            local tiles = {
                {
                    id = "library",
                    label = _("Manga Library"),
                    icon = bridge.iconPath("tsundoku.svg"),
                    on_tap = function()
                        bridge.openLibrary()
                    end,
                },
                {
                    id = "search",
                    label = _("Search Manga"),
                    icon = bridge.iconPath("tsundoku_search.svg"),
                    on_tap = function()
                        bridge.openSearch(true)
                    end,
                },
                {
                    id = "koobone",
                    label = summary.syncing and _("Syncing…") or _("Refresh Koobone"),
                    active = summary.syncing,
                    icon = bridge.iconPath("tsundoku_koobone.svg"),
                    on_tap = function()
                        bridge.syncKoobone(ctx and ctx.refresh_fn)
                    end,
                    on_hold = function()
                        bridge.openKoobone()
                    end,
                },
            }
            if showDownloadsTile(SUISettings, pfx) then
                tiles[#tiles + 1] = {
                    id = "downloads",
                    label = summary.queue_count > 0
                        and T(_("Downloads (%1)"), summary.queue_count)
                        or _("Downloads"),
                    icon = bridge.iconPath("tsundoku_downloads.svg"),
                    on_tap = function()
                        bridge.openDownloads()
                    end,
                }
            end

            local n = #tiles
            local total_gaps = (n - 1) * d.tile_gap
            local base_tile_w = math.max(24, math.floor((w - total_gaps) / n))
            local used_w = 0
            local row = HorizontalGroup:new{ align = "center" }
            local kb_stops = {}

            for idx, tile in ipairs(tiles) do
                if idx > 1 then
                    row[#row + 1] = HorizontalSpan:new{ width = d.tile_gap }
                    used_w = used_w + d.tile_gap
                end
                local tw = (idx == n) and math.max(24, w - used_w) or base_tile_w
                used_w = used_w + tw
                local card = buildTileCard(tile, tw, d, ctx, UI, SUIStyle, QARenderer, plain_ink)
                row[#row + 1] = card
                kb_stops[#kb_stops + 1] = { id = "tsundoku_hub:" .. tile.id, widget = card }
            end

            if ctx and ctx.kbStops then
                ctx.kbStops(hub_mod.id, kb_stops)
            end

            rows[#rows + 1] = row
            return guardPaintTo(rows, "tsundoku_hub")
        end

        function hub_mod.getHeight(ctx)
            local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
            local lf = (ctx and ctx.landscape_factor) or 1
            local base_scale = type(Config.getModuleScale) == "function"
                and Config.getModuleScale(hub_mod.id, pfx) or 1.0
            local scale = base_scale * lf
            local d = computeHubDims(scale, SUIStyle)
            local h = d.tile_h
            if showHeader(SUISettings, pfx) then
                h = h + d.header_h + d.header_gap
            end
            return h
        end

        function hub_mod.getMenuItems(ctx_menu)
            local pfx = ctx_menu.pfx
            local refresh = ctx_menu.refresh
            local _lc = ctx_menu._

            local size_group = {}
            if type(Config.makeScaleItem) == "function" then
                size_group[#size_group + 1] = Config.makeScaleItem{
                    text_func = function() return _lc("Scale") end,
                    enabled_func = function() return type(Config.isScaleLinked) ~= "function" or not Config.isScaleLinked() end,
                    title = _lc("Scale"),
                    info = _lc("Scale for this module.\n100% is the default size."),
                    get = function() return Config.getModuleScalePct(hub_mod.id, pfx) end,
                    set = function(v) Config.setModuleScale(v, hub_mod.id, pfx) end,
                    refresh = refresh,
                }
            end

            local content_rows = {
                {
                    text = _("Show Status Header"),
                    checked_func = function() return showHeader(SUISettings, pfx) end,
                    keep_menu_open = true,
                    callback = function()
                        setShowHeader(SUISettings, pfx, not showHeader(SUISettings, pfx))
                        if refresh then refresh() end
                    end,
                },
                {
                    text = _("Show Downloads Tile"),
                    checked_func = function() return showDownloadsTile(SUISettings, pfx) end,
                    keep_menu_open = true,
                    callback = function()
                        setShowDownloadsTile(SUISettings, pfx, not showDownloadsTile(SUISettings, pfx))
                        if refresh then refresh() end
                    end,
                },
            }

            local behaviour_rows = {
                {
                    text = _("Home screen series tap"),
                    sub_item_table = {
                        {
                            text = _("Open series chapter list"),
                            radio = true,
                            checked_func = function()
                                return bridge.getSeriesTapMode() == "series_view"
                            end,
                            keep_menu_open = true,
                            callback = function()
                                bridge.setSeriesTapMode("series_view")
                                if refresh then refresh() end
                            end,
                        },
                        {
                            text = _("Resume active chapter"),
                            radio = true,
                            checked_func = function()
                                return bridge.getSeriesTapMode() == "resume"
                            end,
                            keep_menu_open = true,
                            callback = function()
                                bridge.setSeriesTapMode("resume")
                                if refresh then refresh() end
                            end,
                        },
                    },
                },
            }

            if type(Config.buildModuleMenu) == "function" then
                return Config.buildModuleMenu({
                    content = content_rows,
                    appearance = #size_group > 0 and { size = size_group } or nil,
                    behaviour = behaviour_rows,
                }, ctx_menu)
            end
            return behaviour_rows
        end
    end)
    if not ok_hub then
        logger.warn("tsundoku_sui_module: failed building hub_mod:", tostring(err_hub))
        hub_mod = nil
    end

    -- Dedicated Manga Series Shelf module built with SimpleUI's GroupCell & GridRenderer
    local series_mod
    if GridRenderer and type(GridRenderer.makeModule) == "function"
            and GroupCell and type(GroupCell.makeSettings) == "function" and type(GroupCell.new) == "function" then
        local ok_ser, err_ser = pcall(function()
            local series_settings = GroupCell.makeSettings{
                keyFor = function(pfx, field)
                    return pfx .. "tsundoku_series_" .. field
                end,
                default_style = "single",
            }

            local series_cell = GroupCell.new{
                owner_id = "tsundoku_series",
                settings = series_settings,
                describe = function(series_key, _ctx)
                    return bridge.describeSeriesGroup(series_key)
                end,
            }

            series_mod = GridRenderer.makeModule{
                id = "tsundoku_series",
                name = _.brandName() .. " · " .. _("Manga Series"),
                category = "books",
                label = _.brandName(),
                text_label = _("Label"),
                default_on = false,
                is_book_mod = true,
                has_covers = true,
                max_items = 5,
                paged = true,
                hold_dialog_label = _.brandName(),

                getFileList = function(_ctx)
                    return bridge.getSeriesKeyList()
                end,

                renderCell = series_cell.renderCell,
                getCellHeight = series_cell.getCellHeight,
                updateCovers = series_cell.updateCovers,
                progress_style = { locked = "none" },
                grid = true,
                default_rows = 1,
                default_cols = 5,
                extra_menu_items_after = type(GroupCell.makeMenuItems) == "function"
                    and function(ctx_menu) return GroupCell.makeMenuItems(ctx_menu, series_settings) end
                    or nil,
            }

            local build_grid = series_mod.build
            function series_mod.build(w, ctx)
                local widget = build_grid(w, ctx)
                if widget then
                    return guardPaintTo(widget, "tsundoku_series")
                end
                local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
                local ink_tbl = type(ctx and ctx.ink) == "table" and ctx.ink or plain_ink
                local sub_ink = safeColor(ink_tbl.sub) or safeColor(SUIStyle.COLOR and SUIStyle.COLOR.text_dim)
                return guardPaintTo(CenterContainer:new{
                    dimen = Geom:new{ w = w, h = series_mod.getHeight(ctx) },
                    makeText(UI, {
                        text = hold_on
                            and _("No manga series yet  —  long press to configure")
                            or _("No manga series yet"),
                        face = Font:getFace(face_reg, SUIStyle.FS_BODY or 18),
                        fgcolor = sub_ink,
                    }),
                }, "tsundoku_series")
            end
        end)
        if not ok_ser then
            logger.warn("tsundoku_sui_module: failed building series_mod:", tostring(err_ser))
            series_mod = nil
        end
    end

    return hub_mod, series_mod
end

return M
