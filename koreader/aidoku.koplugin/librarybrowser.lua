--[[--
Primary Aidoku screen: the user's bookmarked manga library, enhanced with:
- Three switchable library views:
  1. Compact list (精简列表): dense title-only rows with right-aligned download badges
  2. List (列表): 2:3 cover thumbnail on the left + title & status on the right
  3. Grid (网格): multi-column cover grid with small centered title beneath each cover
- Asynchronous non-blocking cover thumbnail fetching & disk/LRU caching via CoverCache.
- Clear visual annotations for downloaded books (full-book vs partial chapter
  download counts, plus live background download queue indicators).
- Direct menu access to Multi-source Search Plus, Download Manager, Library View,
  Library Sorting (Last read / Name / Downloaded first), and Settings.
- Long-press actions per book: open chapters, one-click batch download all
  chapters, remove local downloads, or remove from library.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ChapterCache = require("chaptercache")
local ChapterOrder = require("chapterorder")
local ConfirmBox = require("ui/widget/confirmbox")
local CoverCache = require("covercache")
local Device = require("device")
local DownloadQueue = require("downloadqueue")
local DownloadsEngine = require("downloadsengine")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InstalledSources = require("installedsources")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local OpenWidgets = require("openwidgets")
local OverlapGroup = require("ui/widget/overlapgroup")
local Prefetch = require("prefetch")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local Screen = Device.screen

local VIEW_OPTIONS = {
    {
        id = "compact",
        label = function() return _("Compact list (title only)") end,
        short = function() return _("Compact list") end,
    },
    {
        id = "list",
        label = function() return _("List (cover + title)") end,
        short = function() return _("List") end,
    },
    {
        id = "grid",
        label = function() return _("Grid (cover + title)") end,
        short = function() return _("Grid") end,
    },
}

local function viewShortLabel(mode)
    for _idx, opt in ipairs(VIEW_OPTIONS) do
        if opt.id == mode then
            return opt.short()
        end
    end
    return VIEW_OPTIONS[1].short()
end

local _line_height_cache = {}
local function measureLineHeight(font_size, bold)
    local key = tostring(font_size) .. (bold and ":b" or ":r")
    if _line_height_cache[key] then
        return _line_height_cache[key]
    end
    local probe = TextWidget:new{
        text = "Ag中",
        face = Font:getFace("cfont", font_size),
        bold = bold or false,
        padding = 0,
    }
    local h = math.max(12, probe:getSize().h)
    if probe.free then
        probe:free()
    end
    _line_height_cache[key] = h
    return h
end

local function proportionalFontSize(nominal, max_size, row_h)
    local scale_unit = math.max(1, Screen:scaleBySize(64))
    local fs = math.floor(nominal * (row_h / scale_unit) + 0.5)
    fs = math.max(12, fs)
    if max_size and fs > max_size then
        return max_size
    end
    return fs
end

local function setFocusVisual(widget, focused)
    if not widget or not widget[1] then
        return
    end
    widget.is_focused = focused and true or false
    widget[1].invert = widget.is_focused
    local d = widget[1].dimen or widget.dimen
    if d then
        UIManager:setDirty(nil, "ui", d)
    end
end

local function snapshotFocus(menu)
    if menu and menu.selected then
        return { x = menu.selected.x, y = menu.selected.y }
    end
    return nil
end

local function restoreFocus(menu, old_selected)
    if not menu or not menu.layout or #menu.layout == 0 then
        return
    end
    if old_selected then
        local row = menu.layout[old_selected.y]
        if row and row[old_selected.x] then
            menu:moveFocusTo(old_selected.x, old_selected.y, 0)
            return
        end
    end
    if Device:hasKeys() and not Device:isTouchDevice() then
        menu:moveFocusTo(1, 1, 0)
    end
end

-- Builds a crisp 2:3 typographic placeholder when a manga cover is not yet cached.
local function buildPlaceholderCover(title, cover_w, cover_h, border_sz)
    local inner_w = math.max(1, cover_w - 2 * border_sz)
    local inner_h = math.max(1, cover_h - 2 * border_sz)
    local pad_h = math.max(3, Screen:scaleBySize(5))
    local pad_v = math.max(3, Screen:scaleBySize(6))
    local text_w = math.max(12, inner_w - 2 * pad_h)
    local text_h = math.max(12, inner_h - 2 * pad_v)
    local fs = math.max(10, math.min(14, math.floor(inner_w / math.max(1, Screen:scaleBySize(7)))))

    local tb = TextBoxWidget:new{
        text = BD.auto(title or ""),
        face = Font:getFace("cfont", fs),
        width = text_w,
        height = text_h,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    return FrameContainer:new{
        width = cover_w,
        height = cover_h,
        bordersize = border_sz,
        color = Blitbuffer.COLOR_GRAY,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            tb,
        },
    }
end

-- Builds a framed 2:3 cover widget (real scaled Blitbuffer when cached, else
-- typographic placeholder) plus an optional corner badge for Grid view.
local function buildCoverWidget(entry_item, cover_w, cover_h, show_badge, covers_dir)
    local border_sz = Size.border.thin
    local inner_w = math.max(1, cover_w - 2 * border_sz)
    local inner_h = math.max(1, cover_h - 2 * border_sz)
    local lib_entry = entry_item.library_entry
    local bb = lib_entry and CoverCache:getScaledBB(
        covers_dir, entry_item.source_key_resolved, lib_entry.manga_key, inner_w, inner_h
    ) or nil

    local base_box
    if bb then
        base_box = FrameContainer:new{
            width = cover_w,
            height = cover_h,
            bordersize = border_sz,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            padding = 0,
            margin = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                ImageWidget:new{
                    image = bb,
                    image_disposable = false,
                    width = inner_w,
                    height = inner_h,
                    scale_factor = 1,
                },
            },
        }
    else
        base_box = buildPlaceholderCover(entry_item.raw_title or entry_item.text, cover_w, cover_h, border_sz)
    end

    if show_badge and entry_item.grid_badge and entry_item.grid_badge ~= "" then
        local badge_pad_h = math.max(2, Screen:scaleBySize(3))
        local badge_pad_v = math.max(1, Screen:scaleBySize(1))
        local max_badge_w = math.max(16, cover_w - 2 * border_sz - 2 * badge_pad_h - 4)
        local badge_tw = TextWidget:new{
            text = entry_item.grid_badge,
            face = Font:getFace("cfont", 10),
            bold = true,
            padding = 0,
            max_width = max_badge_w,
            truncate_with_ellipsis = true,
        }
        local badge_frame = FrameContainer:new{
            bordersize = border_sz,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            padding_left = badge_pad_h,
            padding_right = badge_pad_h,
            padding_top = badge_pad_v,
            padding_bottom = badge_pad_v,
            margin = 0,
            badge_tw,
        }
        local bsz = badge_frame:getSize()
        local inset = math.max(1, border_sz)
        local overlay_row = RightContainer:new{
            dimen = Geom:new{ w = math.max(1, cover_w - inset), h = bsz.h + inset },
            TopContainer:new{
                dimen = Geom:new{ w = bsz.w, h = bsz.h + inset },
                VerticalGroup:new{
                    VerticalSpan:new{ width = inset },
                    badge_frame,
                },
            },
        }
        return OverlapGroup:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            allow_mirroring = false,
            base_box,
            overlay_row,
        }, (bb ~= nil)
    end

    return base_box, (bb ~= nil)
end

-- ===== List View Row (Cover + Title) =====

local LibraryListItem = InputContainer:extend{
    entry = nil,
    item_w = 0,
    item_h = 0,
    cover_w = 0,
    cover_h = 0,
    covers_dir = nil,
    show_parent = nil,
    menu = nil,
}

function LibraryListItem:init()
    self.dimen = Geom:new{ w = self.item_w, h = self.item_h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self:buildContent()
end

function LibraryListItem:buildContent()
    if self[1] and type(self[1].free) == "function" then
        pcall(function() self[1]:free() end)
    end

    local pad_h = Screen:scaleBySize(10)
    local pad_v = Screen:scaleBySize(6)
    local gap_h = Screen:scaleBySize(12)
    local content_h = math.max(20, self.item_h - 2 * pad_v)
    local text_w = math.max(40, self.item_w - 2 * pad_h - self.cover_w - gap_h)

    local cover_widget, has_cover = buildCoverWidget(
        self.entry, self.cover_w, self.cover_h, false, self.covers_dir
    )
    self.has_cover = has_cover

    local fs_title = proportionalFontSize(18, 20, self.item_h)
    local fs_sub = proportionalFontSize(13, 15, self.item_h)
    local title_lh = measureLineHeight(fs_title, true)

    local status_widget
    local reserved_sub_h = 0
    local sub_gap = math.max(2, Screen:scaleBySize(3))
    if self.entry.list_status and self.entry.list_status ~= "" then
        status_widget = TextWidget:new{
            text = self.entry.list_status,
            face = Font:getFace("cfont", fs_sub),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = text_w,
            truncate_with_ellipsis = true,
            padding = 0,
        }
        reserved_sub_h = status_widget:getSize().h + sub_gap
        if content_h - reserved_sub_h < title_lh then
            if status_widget.free then status_widget:free() end
            status_widget = nil
            reserved_sub_h = 0
        end
    end

    local title_budget = math.max(title_lh, math.min(title_lh * 2, content_h - reserved_sub_h))
    local title_widget = TextBoxWidget:new{
        text = BD.auto(self.entry.raw_title or self.entry.text or ""),
        face = Font:getFace("cfont", fs_title),
        width = text_w,
        height = title_budget,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        bold = true,
    }

    local text_stack = VerticalGroup:new{ align = "left" }
    table.insert(text_stack, title_widget)
    if status_widget then
        table.insert(text_stack, VerticalSpan:new{ width = sub_gap })
        table.insert(text_stack, status_widget)
    end
    local stack_h = math.min(content_h, text_stack:getSize().h)

    self[1] = FrameContainer:new{
        width = self.item_w,
        height = self.item_h,
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        invert = self.is_focused and true or false,
        focusable = false,
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad_v },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = pad_h },
                CenterContainer:new{
                    dimen = Geom:new{ w = self.cover_w, h = content_h },
                    cover_widget,
                },
                HorizontalSpan:new{ width = gap_h },
                CenterContainer:new{
                    dimen = Geom:new{ w = text_w, h = content_h },
                    LeftContainer:new{
                        dimen = Geom:new{ w = text_w, h = stack_h },
                        text_stack,
                    },
                },
                HorizontalSpan:new{ width = pad_h },
            },
            VerticalSpan:new{ width = pad_v },
        },
    }
end

function LibraryListItem:paintTo(bb, x, y)
    self._screen_x = x
    self._screen_y = y
    InputContainer.paintTo(self, bb, x, y)
end

function LibraryListItem:refreshCover()
    if not self.menu or self.menu.closed then
        return
    end
    self:buildContent()
    if self._screen_x and self._screen_y then
        local dirty = Geom:new{ x = self._screen_x, y = self._screen_y, w = self.item_w, h = self.item_h }
        UIManager:setDirty(self.show_parent or self.menu, function()
            return "ui", dirty
        end)
    end
end

function LibraryListItem:onFocus()
    setFocusVisual(self, true)
    return true
end

function LibraryListItem:onUnfocus()
    setFocusVisual(self, false)
    return true
end

function LibraryListItem:onTapSelect()
    if not self[1] or not self[1].dimen then
        return
    end
    self.menu:onMenuSelect(self.entry)
    return true
end

function LibraryListItem:onHoldSelect()
    if not self[1] or not self[1].dimen then
        return
    end
    self.menu:onMenuHold(self.entry)
    return true
end

-- ===== Grid View Cell (Cover + Small Title Below) =====

local LibraryGridItem = InputContainer:extend{
    entry = nil,
    cell_w = 0,
    cell_h = 0,
    cover_w = 0,
    cover_h = 0,
    cover_area_h = 0,
    title_gap = 0,
    title_box_h = 0,
    title_font_size = 13,
    covers_dir = nil,
    show_parent = nil,
    menu = nil,
}

function LibraryGridItem:init()
    self.dimen = Geom:new{ w = self.cell_w, h = self.cell_h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self:buildContent()
end

function LibraryGridItem:buildContent()
    if self[1] and type(self[1].free) == "function" then
        pcall(function() self[1]:free() end)
    end

    local cover_widget, has_cover = buildCoverWidget(
        self.entry, self.cover_w, self.cover_h, true, self.covers_dir
    )
    self.has_cover = has_cover

    local pad_h = math.max(2, Screen:scaleBySize(3))
    local title_w = math.max(20, self.cell_w - 2 * pad_h)
    local title_widget = TextBoxWidget:new{
        text = BD.auto(self.entry.raw_title or self.entry.text or ""),
        face = Font:getFace("cfont", self.title_font_size),
        width = title_w,
        height = self.title_box_h,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        bold = false,
    }
    local actual_title_h = math.min(self.title_box_h, title_widget:getSize().h)

    self[1] = FrameContainer:new{
        width = self.cell_w,
        height = self.cell_h,
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        invert = self.is_focused and true or false,
        focusable = false,
        VerticalGroup:new{
            align = "center",
            BottomContainer:new{
                dimen = Geom:new{ w = self.cell_w, h = self.cover_area_h },
                cover_widget,
            },
            VerticalSpan:new{ width = self.title_gap },
            TopContainer:new{
                dimen = Geom:new{ w = self.cell_w, h = self.title_box_h },
                CenterContainer:new{
                    dimen = Geom:new{ w = self.cell_w, h = actual_title_h },
                    title_widget,
                },
            },
        },
    }
end

function LibraryGridItem:paintTo(bb, x, y)
    self._screen_x = x
    self._screen_y = y
    InputContainer.paintTo(self, bb, x, y)
end

function LibraryGridItem:refreshCover()
    if not self.menu or self.menu.closed then
        return
    end
    self:buildContent()
    if self._screen_x and self._screen_y then
        local dirty = Geom:new{ x = self._screen_x, y = self._screen_y, w = self.cell_w, h = self.cell_h }
        UIManager:setDirty(self.show_parent or self.menu, function()
            return "ui", dirty
        end)
    end
end

function LibraryGridItem:onFocus()
    setFocusVisual(self, true)
    return true
end

function LibraryGridItem:onUnfocus()
    setFocusVisual(self, false)
    return true
end

function LibraryGridItem:onTapSelect()
    if not self[1] or not self[1].dimen then
        return
    end
    self.menu:onMenuSelect(self.entry)
    return true
end

function LibraryGridItem:onHoldSelect()
    if not self[1] or not self[1].dimen then
        return
    end
    self.menu:onMenuHold(self.entry)
    return true
end

-- ===== LibraryBrowser =====

local LibraryBrowser = Menu:extend{
    title_bar_left_icon = "appbar.menu",
}

function LibraryBrowser:init()
    self.title = _("Library")
    self.refresh_pending = false
    CoverCache:resetFailures()
    self.item_table = self:genItemTable()
    self.subtitle = self:computeSubtitle()
    Menu.init(self)
    OpenWidgets.push(self)

    self.listener_key = tostring(self)
    DownloadQueue:subscribe(self.listener_key, function(event_kind)
        if self.closed then
            return
        end
        if event_kind ~= "progress" then
            self:scheduleRefresh()
        end
    end)
end

function LibraryBrowser:onCloseWidget()
    self.closed = true
    if self.listener_key then
        DownloadQueue:unsubscribe(self.listener_key)
    end
    CoverCache:cancelPending()
    CoverCache:clearMemoryCache()
    Menu.onCloseWidget(self)
    OpenWidgets.remove(self)
end

function LibraryBrowser:scheduleRefresh()
    if self.refresh_pending then
        return
    end
    self.refresh_pending = true
    UIManager:scheduleIn(0.45, function()
        self.refresh_pending = false
        if not self.closed then
            self:refresh()
        end
    end)
end

local function entryKey(entry)
    return (entry.source_key and entry.source_key ~= "") and entry.source_key or entry.source_path
end

function LibraryBrowser:currentViewMode()
    return self.store and self.store:libraryViewMode() or "compact"
end

function LibraryBrowser:hasRealItems()
    return self.item_table and #self.item_table > 0 and not self.item_table[1].is_placeholder
end

function LibraryBrowser:availableBodyHeight()
    local avail_h = (self.inner_dimen and self.inner_dimen.h) or Screen:getHeight()
    if not self.no_title and self.title_bar then
        avail_h = avail_h - self.title_bar:getHeight()
    end
    local footer_h = 0
    if self.page_return_arrow and self.page_info_text then
        footer_h = math.max(self.page_return_arrow:getSize().h, self.page_info_text:getSize().h) + Size.padding.button
    elseif self.page_info then
        footer_h = self.page_info:getSize().h + Size.padding.button
    end
    return math.max(120, avail_h - footer_h)
end

function LibraryBrowser:computeCustomLayoutMetrics(view_mode)
    local inner_w = (self.inner_dimen and self.inner_dimen.w) or Screen:getWidth()
    local avail_h = self:availableBodyHeight()
    local is_portrait = inner_w <= ((self.inner_dimen and self.inner_dimen.h) or Screen:getHeight())

    if view_mode == "list" then
        local pad_v = Screen:scaleBySize(6)
        local target_rows = is_portrait and 6 or 4
        local min_row_h = Screen:scaleBySize(72)
        local max_rows = math.max(1, math.floor(avail_h / min_row_h))
        local perpage = math.max(1, math.min(target_rows, max_rows))
        local separators_h = math.max(0, perpage - 1)
        local item_h = math.max(40, math.floor((avail_h - separators_h) / perpage))
        local cover_h = math.max(32, item_h - 2 * pad_v)
        local cover_w = math.max(22, math.floor(cover_h * 2 / 3))
        return {
            mode = "list",
            perpage = perpage,
            item_w = inner_w,
            item_h = item_h,
            cover_w = cover_w,
            cover_h = cover_h,
        }
    end

    -- Grid mode: 3x3 in portrait, 4x2 in landscape (clamped cleanly on short screens).
    local gap = Screen:scaleBySize(10)
    local cols = is_portrait and 3 or 4
    local target_rows = is_portrait and 3 or 2
    local title_fs = 13
    local title_lh = measureLineHeight(title_fs, false)
    local title_gap = Screen:scaleBySize(4)
    local title_box_h = title_lh * 2
    local strip_h = title_gap + title_box_h
    local min_cell_h = strip_h + Screen:scaleBySize(64)
    local max_rows = math.max(1, math.floor((avail_h - gap) / (min_cell_h + gap)))
    local rows = math.max(1, math.min(target_rows, max_rows))

    local cell_w = math.max(48, math.floor((inner_w - (cols + 1) * gap) / cols))
    local cell_h = math.max(strip_h + 36, math.floor((avail_h - (rows + 1) * gap) / rows))
    local cover_area_h = math.max(36, cell_h - strip_h)

    local max_cw = math.max(24, cell_w - Screen:scaleBySize(4))
    local max_ch = cover_area_h
    local cover_w, cover_h
    if math.floor(max_ch * 2 / 3) <= max_cw then
        cover_h = max_ch
        cover_w = math.max(20, math.floor(cover_h * 2 / 3))
    else
        cover_w = max_cw
        cover_h = math.max(30, math.min(max_ch, math.floor(cover_w * 3 / 2)))
    end

    return {
        mode = "grid",
        cols = cols,
        rows = rows,
        gap = gap,
        perpage = cols * rows,
        cell_w = cell_w,
        cell_h = cell_h,
        cover_w = cover_w,
        cover_h = cover_h,
        cover_area_h = cover_area_h,
        title_gap = title_gap,
        title_box_h = title_box_h,
        title_font_size = title_fs,
    }
end

function LibraryBrowser:_recalculateDimen(no_recalculate_dimen)
    local view_mode = self:currentViewMode()
    if view_mode == "compact" or not self:hasRealItems() then
        return Menu._recalculateDimen(self, no_recalculate_dimen)
    end
    local m = self:computeCustomLayoutMetrics(view_mode)
    self._layout_metrics = m
    self.perpage = m.perpage
    self.page_num = math.max(1, math.ceil(#self.item_table / self.perpage))
    if not self.page or self.page < 1 then
        self.page = 1
    elseif self.page > self.page_num then
        self.page = self.page_num
    end
    if view_mode == "list" then
        self.item_width = m.item_w
        self.item_height = m.item_h
        self.item_dimen = Geom:new{ x = 0, y = 0, w = m.item_w, h = m.item_h }
    else
        self.item_width = (self.inner_dimen and self.inner_dimen.w) or Screen:getWidth()
        self.item_height = m.cell_h
        self.item_dimen = Geom:new{ x = 0, y = 0, w = m.cell_w, h = m.cell_h }
    end
end

function LibraryBrowser:getPageNumber(item_number)
    local view_mode = self:currentViewMode()
    if view_mode ~= "compact" and self:hasRealItems() then
        local perpage = math.max(1, self.perpage or 1)
        if #self.item_table == 0 or not item_number or item_number <= 0 then
            return 1
        end
        return math.ceil(math.min(item_number, #self.item_table) / perpage)
    end
    return Menu.getPageNumber(self, item_number)
end

function LibraryBrowser:updateItems(select_number, no_recalculate_dimen)
    local view_mode = self:currentViewMode()
    if view_mode == "compact" or not self:hasRealItems() then
        CoverCache:cancelPending()
        return Menu.updateItems(self, select_number, no_recalculate_dimen)
    end

    if not no_recalculate_dimen or not self._layout_metrics or self._layout_metrics.mode ~= view_mode then
        self:_recalculateDimen()
    end
    local m = self._layout_metrics
    local old_dimen = self.dimen and self.dimen:copy()
    local old_selected = snapshotFocus(self)

    self.layout = {}
    self.item_group:clear()
    if self.page_info then self.page_info:resetLayout() end
    if self.return_button then self.return_button:resetLayout() end
    if self.content_group then self.content_group:resetLayout() end

    self.page_num = math.max(1, math.ceil(#self.item_table / self.perpage))
    if self.page > self.page_num then
        self.page = self.page_num
    elseif self.page < 1 then
        self.page = 1
    end

    local idx_s = (self.page - 1) * self.perpage + 1
    local idx_e = math.min(self.page * self.perpage, #self.item_table)
    local cover_requests = {}

    if view_mode == "list" then
        for idx = idx_s, idx_e do
            local entry_item = self.item_table[idx]
            if not entry_item then
                break
            end
            entry_item.idx = idx
            local w = LibraryListItem:new{
                entry = entry_item,
                item_w = m.item_w,
                item_h = m.item_h,
                cover_w = m.cover_w,
                cover_h = m.cover_h,
                covers_dir = self.covers_dir,
                show_parent = self.show_parent or self,
                menu = self,
            }
            table.insert(self.item_group, w)
            table.insert(self.layout, { w })
            if idx < idx_e then
                table.insert(self.item_group, LineWidget:new{
                    dimen = Geom:new{ w = m.item_w, h = 1 },
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                })
            end
            if not w.has_cover and entry_item.library_entry then
                local le = entry_item.library_entry
                table.insert(cover_requests, {
                    source_key = entry_item.source_key_resolved,
                    source_path = le.source_path,
                    manga_key = le.manga_key,
                    cover_url = le.cover,
                    entry = le,
                    on_ready = function() w:refreshCover() end,
                })
            end
        end
    else
        local idx = idx_s
        while idx <= idx_e do
            local row_widgets = {}
            local row_group = HorizontalGroup:new{ align = "top" }
            table.insert(self.item_group, VerticalSpan:new{ width = m.gap })
            table.insert(row_group, HorizontalSpan:new{ width = m.gap })
            for _col = 1, m.cols do
                local entry_item = self.item_table[idx]
                if entry_item and idx <= idx_e then
                    entry_item.idx = idx
                    local w = LibraryGridItem:new{
                        entry = entry_item,
                        cell_w = m.cell_w,
                        cell_h = m.cell_h,
                        cover_w = m.cover_w,
                        cover_h = m.cover_h,
                        cover_area_h = m.cover_area_h,
                        title_gap = m.title_gap,
                        title_box_h = m.title_box_h,
                        title_font_size = m.title_font_size,
                        covers_dir = self.covers_dir,
                        show_parent = self.show_parent or self,
                        menu = self,
                    }
                    table.insert(row_group, w)
                    table.insert(row_widgets, w)
                    if not w.has_cover and entry_item.library_entry then
                        local le = entry_item.library_entry
                        table.insert(cover_requests, {
                            source_key = entry_item.source_key_resolved,
                            source_path = le.source_path,
                            manga_key = le.manga_key,
                            cover_url = le.cover,
                            entry = le,
                            on_ready = function() w:refreshCover() end,
                        })
                    end
                else
                    table.insert(row_group, HorizontalSpan:new{ width = m.cell_w })
                end
                table.insert(row_group, HorizontalSpan:new{ width = m.gap })
                idx = idx + 1
            end
            table.insert(self.item_group, row_group)
            if #row_widgets > 0 then
                table.insert(self.layout, row_widgets)
            end
        end
        table.insert(self.item_group, VerticalSpan:new{ width = m.gap })
    end

    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()
    restoreFocus(self, old_selected)

    UIManager:setDirty(self.show_parent or self, function()
        local rd = (old_dimen and self.dimen and old_dimen:combine(self.dimen)) or self.dimen
        return "ui", rd
    end)

    if #cover_requests > 0 and self.covers_dir and self.covers_dir ~= "" then
        CoverCache:requestBatch(cover_requests, {
            engine = self.engine,
            store = self.store,
            sources_dir = self.sources_dir,
            covers_dir = self.covers_dir,
        })
    end
end

function LibraryBrowser:computeSubtitle()
    local parts = {}
    if self.store:isEphemeralMode() then
        table.insert(parts, _("Ephemeral Mode"))
    end
    local qstats = DownloadQueue:getStats()
    if qstats.pending > 0 then
        table.insert(parts, T(_("Downloading (%1 in queue)"), qstats.pending))
    end
    return table.concat(parts, " · ")
end

function LibraryBrowser:sortedLibraryEntries(dl_stats, meta_map)
    local entries = self.store:libraryEntries()
    local order = self.store:librarySortOrder()
    if order == "last_read" then
        table.sort(entries, function(a, b)
            local la = self.store:lastReadAt(entryKey(a), a.manga_key)
            local lb = self.store:lastReadAt(entryKey(b), b.manga_key)
            if la ~= lb then return la > lb end
            return a.title:lower() < b.title:lower()
        end)
    elseif order == "downloaded" then
        table.sort(entries, function(a, b)
            local ma = meta_map[entryKey(a) .. "\0" .. a.manga_key]
            local mb = meta_map[entryKey(b) .. "\0" .. b.manga_key]
            local ga = DownloadsEngine.lookupMangaGroup(dl_stats, entryKey(a), a.manga_key, a.title, ma and ma.canonical_key)
            local gb = DownloadsEngine.lookupMangaGroup(dl_stats, entryKey(b), b.manga_key, b.title, mb and mb.canonical_key)
            local ca = ga and ga.count or 0
            local cb = gb and gb.count or 0
            if ca ~= cb then return ca > cb end
            return a.title:lower() < b.title:lower()
        end)
    else
        table.sort(entries, function(a, b) return a.title:lower() < b.title:lower() end)
    end
    return entries
end

function LibraryBrowser:genItemTable()
    local dl_stats = self.downloads_engine:mangaDownloadStats()
    local meta_map = self.store:getMangaMetaMap()
    local item_table = {}

    for _idx, entry in ipairs(self:sortedLibraryEntries(dl_stats, meta_map)) do
        local skey = entryKey(entry)
        local meta = meta_map[skey .. "\0" .. entry.manga_key]
        local canonical = meta and meta.canonical_key or ""
        local total_ch = meta and meta.chapter_count or 0
        local dl_group = DownloadsEngine.lookupMangaGroup(dl_stats, skey, entry.manga_key, entry.title, canonical)
        local dl_count = dl_group and dl_group.count or 0
        local active_q, queued_q = DownloadQueue:getMangaTaskStats(skey, entry.manga_key, canonical)

        local prefix = ""
        local right_parts = {}
        local grid_badge = nil

        if (active_q + queued_q) > 0 then
            prefix = "▶ "
            table.insert(right_parts, T(_("DL %1"), active_q + queued_q))
            grid_badge = string.format("▶ %d", active_q + queued_q)
        elseif dl_count > 0 then
            prefix = "✓ "
        end

        if dl_count > 0 then
            if total_ch > 0 and dl_count >= total_ch then
                table.insert(right_parts, T(_("Downloaded all (%1 ch)"), dl_count))
                if not grid_badge then grid_badge = "✓" end
            elseif total_ch > 0 then
                table.insert(right_parts, T(_("Downloaded %1/%2 ch"), dl_count, total_ch))
                if not grid_badge then grid_badge = string.format("✓%d/%d", dl_count, total_ch) end
            else
                table.insert(right_parts, T(_("Downloaded %1 ch"), dl_count))
                if not grid_badge then grid_badge = string.format("✓%d", dl_count) end
            end
        end

        local mandatory_str = table.concat(right_parts, " · ")
        local list_status = mandatory_str ~= "" and (prefix .. mandatory_str) or ""

        table.insert(item_table, {
            text = prefix .. entry.title,
            raw_title = entry.title,
            mandatory = mandatory_str,
            list_status = list_status,
            grid_badge = grid_badge,
            source_key_resolved = skey,
            library_entry = entry,
            dl_group = dl_group,
        })
    end

    if #item_table == 0 then
        table.insert(item_table, {
            -- TRANSLATORS: KOReader mirrors the layout for RTL languages, so the menu button is top right there.
            text = _("Library is empty. Use the menu (top left) to find manga."),
            dim = true,
            is_placeholder = true,
        })
    end
    return item_table
end

function LibraryBrowser:refresh()
    local saved_page = self.page
    self.item_table = self:genItemTable()
    self._layout_metrics = nil
    self:updateItems(saved_page)
    if self.title_bar then
        self.title_bar:setTitle(_("Library"))
        self.title_bar:setSubTitle(self:computeSubtitle(), true)
    end
end

function LibraryBrowser:switchViewMode(new_mode)
    local cur_mode = self:currentViewMode()
    if new_mode == cur_mode then
        return
    end
    local top_item_idx = math.max(1, ((self.page or 1) - 1) * math.max(1, self.perpage or 1) + 1)
    self.store:setLibraryViewMode(new_mode)
    self._layout_metrics = nil
    self:_recalculateDimen()
    self.page = self:getPageNumber(top_item_idx)
    self:updateItems(self.page, true)
    if self.title_bar then
        self.title_bar:setSubTitle(self:computeSubtitle(), true)
    end
end

function LibraryBrowser:promptViewMenu()
    local current = self:currentViewMode()
    local dialog
    local buttons = {}
    for _idx, opt in ipairs(VIEW_OPTIONS) do
        local is_cur = (opt.id == current)
        local mode_id = opt.id
        table.insert(buttons, {{
            text = (is_cur and "✓ " or "") .. opt.label(),
            callback = function()
                UIManager:close(dialog)
                self:switchViewMode(mode_id)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("Library view"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function LibraryBrowser:openDownloadManager()
    local DownloadsBrowser = require("downloadsbrowser")
    UIManager:show(DownloadsBrowser:new{
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        downloads_dir = self.downloads_dir,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
    })
end

function LibraryBrowser:onLeftButtonTap()
    local qstats = DownloadQueue:getStats()
    local view_mode = self:currentViewMode()
    local sort_order = self.store:librarySortOrder()
    local sort_labels = {
        name = _("Sort: Name"),
        last_read = _("Sort: Last read"),
        downloaded = _("Sort: Downloaded first"),
    }
    local next_sort = {
        name = "last_read",
        last_read = "downloaded",
        downloaded = "name",
    }
    local dm_text = qstats.pending > 0
        and T(_("Download Manager (%1 active)"), qstats.pending)
        or _("Download Manager")

    local dialog
    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function() return self.title_bar.left_button.image.dimen end,
        buttons = {
            {{
                text = _("Multi-source Search…"),
                callback = function()
                    UIManager:close(dialog)
                    local GlobalSearchBrowser = require("globalsearchbrowser")
                    UIManager:show(GlobalSearchBrowser:new{
                        engine = self.engine,
                        store = self.store,
                        downloads_engine = self.downloads_engine,
                        ui = self.ui,
                        sources_dir = self.sources_dir,
                        downloads_dir = self.downloads_dir,
                        is_popout = false,
                        is_borderless = true,
                        title_bar_fm_style = true,
                        refresh_callback = function() self:refresh() end,
                    })
                end,
            }},
            {{
                text = dm_text,
                callback = function()
                    UIManager:close(dialog)
                    self:openDownloadManager()
                end,
            }},
            {{
                text = T(_("View: %1…"), viewShortLabel(view_mode)),
                callback = function()
                    UIManager:close(dialog)
                    self:promptViewMenu()
                end,
            }},
            {{
                text = sort_labels[sort_order] or sort_labels.name,
                callback = function()
                    UIManager:close(dialog)
                    self.store:setLibrarySortOrder(next_sort[sort_order] or "name")
                    self.page = 1
                    self:refresh()
                end,
            }},
            {{
                text = _("Settings"),
                callback = function()
                    UIManager:close(dialog)
                    local SettingsBrowser = require("settingsbrowser")
                    UIManager:show(SettingsBrowser:new{
                        aidoku = self.aidoku,
                        engine = self.engine,
                        store = self.store,
                        downloads_engine = self.downloads_engine,
                        ui = self.ui,
                        sources_dir = self.sources_dir,
                        downloads_dir = self.downloads_dir,
                        is_popout = false,
                        is_borderless = true,
                        title_bar_fm_style = true,
                        refresh_callback = function()
                            self.downloads_dir = self.aidoku.downloads_dir
                            self.downloads_engine = self.aidoku.downloads_engine
                            self:refresh()
                        end,
                    })
                end,
            }},
            {{
                text = _("Check for Updates"),
                callback = function()
                    UIManager:close(dialog)
                    self:checkForUpdates()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

local function readOwnVersion(plugin_path)
    local f = io.open(plugin_path .. "/VERSION", "r")
    if not f then
        return ""
    end
    local v = f:read("*a") or ""
    f:close()
    return (v:gsub("%s+$", ""))
end

function LibraryBrowser:checkForUpdates()
    local plugin_path = self.aidoku.path
    local bin_arch = self.aidoku.bin_arch
    local current_version = readOwnVersion(plugin_path)
    Trapper:wrap(function()
        local result, err = self.engine:checkUpdate(bin_arch, current_version)
        if not result then
            UIManager:show(InfoMessage:new{ text = T(_("Could not check for updates:\n%1"), err) })
            return
        end
        if result.status == "up_to_date" then
            UIManager:show(InfoMessage:new{
                text = T(_("Plugin is up to date (%1)."), result.current),
                timeout = 2,
            })
            return
        end
        local message
        if result.status == "update_available" then
            message = T(
                _("Update available: %1\nInstalled: %2"),
                result.latest,
                current_version == "" and _("unknown") or current_version
            )
        else
            message = T(
                _("Latest: %1\nInstalled version unknown."),
                result.latest
            )
        end
        UIManager:show(ConfirmBox:new{
            text = message,
            ok_text = _("Download & Install"),
            ok_callback = function()
                self:applyUpdate(result)
            end,
        })
    end)
end

function LibraryBrowser:applyUpdate(check_result)
    Trapper:wrap(function()
        local applied, err = self.engine:selfUpdate(self.aidoku.path, check_result.assetUrl)
        if not applied then
            UIManager:show(InfoMessage:new{ text = T(_("Update failed:\n%1"), err) })
            return
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Updated to %1. Restart KOReader to apply."), applied.version),
        })
    end)
end

function LibraryBrowser:migrateLegacyBookmark(entry)
    if entry.source_key and entry.source_key ~= "" then
        return entry.source_key
    end
    if not entry.source_path or entry.source_path == "" then
        return nil
    end
    local manifest = self.engine:manifest(entry.source_path)
    if not manifest or type(manifest.key) ~= "string" or manifest.key == "" then
        return nil
    end
    self.store:removeBookmark(entry.source_path, entry.manga_key)
    self.store:addBookmark(manifest.key, entry.source_path, entry.manga_key, entry.title, entry.cover)
    return manifest.key
end

function LibraryBrowser:openEntryManga(entry)
    Trapper:wrap(function()
        local source_key = self:migrateLegacyBookmark(entry)
        local found = source_key and InstalledSources.findByKey(self.sources_dir, self.engine, source_key)
        if not found then
            UIManager:show(InfoMessage:new{
                text = T(_("'%1' is no longer installed. Hold to remove it."), entry.title),
            })
            return
        end
        local MangaBrowser = require("mangabrowser")
        UIManager:show(MangaBrowser:new{
            engine = self.engine,
            store = self.store,
            downloads_engine = self.downloads_engine,
            ui = self.ui,
            sources_dir = self.sources_dir,
            source_path = found.path,
            source_key = source_key,
            source_name = found.name,
            downloads_dir = self.downloads_dir,
            manga = { Key = entry.manga_key, Title = entry.title, Cover = entry.cover },
            is_popout = false,
            is_borderless = true,
            title_bar_fm_style = true,
            refresh_callback = function() self:refresh() end,
        })
    end)
end

function LibraryBrowser:batchDownloadEntry(entry)
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local source_key = self:migrateLegacyBookmark(entry)
            local found = source_key and InstalledSources.findByKey(self.sources_dir, self.engine, source_key)
            if not found then
                UIManager:show(InfoMessage:new{
                    text = T(_("'%1' is no longer installed."), entry.title),
                })
                return
            end
            local updated = ChapterCache.get(source_key, entry.manga_key)
            if not updated then
                local err
                updated, err = self.engine:mangaUpdate(found.path, entry.manga_key)
                if not updated then
                    UIManager:show(InfoMessage:new{ text = T(_("Could not load chapters:\n%1"), err) })
                    return
                end
                ChapterCache.set(source_key, entry.manga_key, updated)
                if updated.Key and updated.Key ~= entry.manga_key then
                    ChapterCache.set(source_key, updated.Key, updated)
                end
            end
            local chapters = type(updated.Chapters) == "table" and updated.Chapters or {}
            self.store:recordMangaMeta(source_key, entry.manga_key, updated.Key, #chapters)
            if type(updated.Cover) == "string" and updated.Cover ~= "" then
                self.store:updateBookmarkCover(source_key, entry.manga_key, updated.Cover)
            end
            local ordered = ChapterOrder.orderedByReading(chapters)
            local mtitle = Prefetch.mangaLabel(updated)
            local specs = {}
            for _idx, c in ipairs(ordered) do
                if self.downloads_engine:path(source_key, updated.Key, c.Key) == ""
                    and self.downloads_engine:path(source_key, entry.manga_key, c.Key) == ""
                then
                    local clabel = Prefetch.chapterLabel(c)
                    local safe = util.getSafeFilename(clabel .. ".cbz", self.downloads_dir)
                    table.insert(specs, {
                        source_key = source_key,
                        source_path = found.path,
                        source_name = found.name,
                        manga_key = updated.Key,
                        manga_title = mtitle,
                        manga = updated,
                        chapter_key = c.Key,
                        chapter_title = clabel,
                        chapter = c,
                        out_path = self.downloads_dir .. "/" .. safe,
                        downloads_dir = self.downloads_dir,
                        manga_dir_name = mtitle .. " [" .. source_key .. "]",
                    })
                end
            end
            if #specs == 0 then
                self:refresh()
                UIManager:show(InfoMessage:new{
                    text = T(_("All %1 chapters are already downloaded locally."), #ordered),
                    timeout = 2,
                })
                return
            end
            local added = DownloadQueue:enqueueBatch(specs, {
                engine = self.engine,
                store = self.store,
                downloads_engine = self.downloads_engine,
                downloads_dir = self.downloads_dir,
            })
            self:refresh()
            UIManager:show(ConfirmBox:new{
                text = T(_("Queued %1 chapter(s) of '%2' for download."), added, mtitle),
                ok_text = _("View Progress"),
                cancel_text = _("OK"),
                ok_callback = function()
                    self:openDownloadManager()
                end,
            })
        end)
    end)
end

function LibraryBrowser:onMenuSelect(item)
    if item.is_placeholder then
        return true
    end
    self:openEntryManga(item.library_entry)
    return true
end

function LibraryBrowser:onMenuHold(item)
    if item.is_placeholder then
        return true
    end
    local entry = item.library_entry
    local dl_group = item.dl_group
    local dialog
    local buttons = {
        {{
            text = _("Open chapter list"),
            callback = function()
                UIManager:close(dialog)
                self:openEntryManga(entry)
            end,
        }},
    }

    if not self.store:isEphemeralMode() then
        table.insert(buttons, {{
            text = _("Download all chapters"),
            callback = function()
                UIManager:close(dialog)
                self:batchDownloadEntry(entry)
            end,
        }})
    end

    if dl_group and dl_group.count > 0 then
        table.insert(buttons, {{
            text = T(_("Delete %1 downloaded chapter(s)…"), dl_group.count),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove all %1 downloaded chapters of '%2'?"), dl_group.count, entry.title),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        self.downloads_engine:removeManga(dl_group.sourceKey, dl_group.mangaKey, entry.title)
                        self:refresh()
                    end,
                })
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Remove from library…"),
        callback = function()
            UIManager:close(dialog)
            UIManager:show(ConfirmBox:new{
                text = T(_("Remove '%1' from your library?"), entry.title),
                ok_text = _("Remove"),
                ok_callback = function()
                    local key = entryKey(entry)
                    self.store:removeBookmark(key, entry.manga_key)
                    if self.covers_dir and self.covers_dir ~= "" then
                        CoverCache:invalidateEntry(self.covers_dir, key, entry.manga_key)
                        os.remove(CoverCache.diskPath(self.covers_dir, key, entry.manga_key))
                    end
                    self:refresh()
                end,
            })
        end,
    }})

    dialog = ButtonDialog:new{
        title = entry.title,
        buttons = buttons,
    }
    UIManager:show(dialog)
    return true
end

return LibraryBrowser
