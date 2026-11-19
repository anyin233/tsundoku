--[[--
Full-book cross-volume Table of Contents hook for sharded Tsundoku EPUBs.

When a novel is split into 50-chapter EPUB volumes for fast e-ink loading,
KOReader's built-in ReaderToc only sees the currently open volume's NCX/spine.
Hooking ReaderToc:onShowToc() lets the reader browse and search every chapter
across every downloaded volume in one unified TOC menu and jump transparently
across volume files.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DownloadsEngine = require("downloadsengine")
local EpubHelper = require("epubhelper")
local Event = require("ui/event")
local Font = require("ui/font")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local OpenWidgets = require("openwidgets")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local BookToc = {}

local function cleanTitle(title)
    title = tostring(title or ""):gsub("\r", "")
    title = title:match("^%s*(.-)%s*$") or title
    if title == "" then
        return "\u{2013}"
    end
    return title
end

local function buildTocItems(book, norm_cur, cur_vol_pages, cur_vol_xps, current_global_idx, search_query)
    local items = {}
    local query = (type(search_query) == "string" and search_query ~= "") and search_query or nil
    for _idx, ch in ipairs(book.chapters) do
        local label = cleanTitle(ch.title)
        if not query or util.stringSearch(label, query) ~= 0 then
            local is_cur_vol = (DownloadsEngine.normalizePath(ch.epubPath) == norm_cur)
            local page_num = is_cur_vol and cur_vol_pages[ch.fragIndex] or nil
            local mandatory = page_num and tostring(page_num) or T(_("Vol.%1"), ch.volumeIndex)
            table.insert(items, {
                text = label,
                mandatory = mandatory,
                mandatory_dim = not is_cur_vol,
                bidi_wrap_func = BD.auto,
                chapter = ch,
                epub_path = ch.epubPath,
                chapter_key = ch.key,
                frag_index = ch.fragIndex,
                volume_index = ch.volumeIndex,
                volume_start = ch.volumeStart,
                volume_end = ch.volumeEnd,
                xpointer = is_cur_vol
                    and (cur_vol_xps[ch.fragIndex] or string.format("/body/DocFragment[%d]/body", ch.fragIndex))
                    or nil,
            })
        end
    end
    if not query and current_global_idx and items[current_global_idx] then
        items.current = current_global_idx
    end
    return items
end

function BookToc.show(aidoku, toc_self, original_on_show_toc)
    local file = aidoku and aidoku.document and aidoku.document.file
    if not file or not EpubHelper.isEpub(file) then
        return false
    end
    if toc_self and toc_self.search_string ~= nil then
        return false
    end

    local book = EpubHelper.readBookIndex(file, aidoku.downloads_engine)
    if not book or type(book.volumes) ~= "table" or #book.volumes <= 1
        or type(book.chapters) ~= "table" or #book.chapters == 0
    then
        return false
    end

    local norm_cur = DownloadsEngine.normalizePath(file)
    local cur_xp = EpubHelper.currentXPointer(file, aidoku.ui)
    local cur_frag = EpubHelper.parseDocFragmentIndex(cur_xp)

    local cur_vol_pages = {}
    local cur_vol_xps = {}
    if toc_self and type(toc_self.fillToc) == "function" then
        pcall(toc_self.fillToc, toc_self)
        for idx, entry in ipairs(toc_self.toc or {}) do
            local f_idx = EpubHelper.parseDocFragmentIndex(entry.xpointer) or idx
            if f_idx and not cur_vol_pages[f_idx] then
                if entry.page then
                    cur_vol_pages[f_idx] = entry.page
                end
                if type(entry.xpointer) == "string" and entry.xpointer ~= "" then
                    cur_vol_xps[f_idx] = entry.xpointer
                end
            end
        end
    end

    local current_vol_idx
    local first_in_cur_vol
    local current_global_idx
    for _idx, ch in ipairs(book.chapters) do
        if DownloadsEngine.normalizePath(ch.epubPath) == norm_cur then
            if not current_vol_idx then
                current_vol_idx = ch.volumeIndex
                first_in_cur_vol = ch.globalIndex
            end
            if cur_frag and ch.fragIndex == cur_frag then
                current_global_idx = ch.globalIndex
                break
            end
        end
    end
    current_global_idx = current_global_idx or first_in_cur_vol or 1

    if aidoku.ui and aidoku.ui.view and aidoku.ui.view.shouldInvertBiDiLayoutMirroring
        and aidoku.ui.view:shouldInvertBiDiLayoutMirroring()
    then
        BD.invert()
    end

    local items_per_page = (G_reader_settings and G_reader_settings:readSetting("toc_items_per_page")) or 14
    local items_font_size = (G_reader_settings and G_reader_settings:readSetting("toc_items_font_size"))
        or (Menu.getItemFontSize and Menu.getItemFontSize(items_per_page))
        or 20
    local items_with_dots = (not G_reader_settings) or G_reader_settings:nilOrTrue("toc_items_with_dots")

    local full_items = buildTocItems(book, norm_cur, cur_vol_pages, cur_vol_xps, current_global_idx, nil)
    local default_subtitle = T(_("%1 · %2 ch (%3 vols)"),
        (book.title ~= "" and book.title or ""), #book.chapters, #book.volumes)
    local search_query = nil

    local toc_menu
    local menu_container

    local function navigateToItem(item)
        if not item or not item.epub_path then
            return
        end
        if toc_menu and toc_menu.close_callback then
            toc_menu:close_callback()
        end
        if DownloadsEngine.normalizePath(item.epub_path) == norm_cur then
            if aidoku.ui and aidoku.ui.link and aidoku.ui.link.addCurrentLocationToStack then
                aidoku.ui.link:addCurrentLocationToStack()
            end
            local xp = item.xpointer or string.format("/body/DocFragment[%d]/body", item.frag_index or 1)
            aidoku.ui:handleEvent(Event:new("GotoXPointer", xp, xp))
            return
        end
        if lfs.attributes(item.epub_path, "mode") ~= "file" then
            UIManager:show(InfoMessage:new{
                text = _("Volume file not found on disk."),
                timeout = 2,
            })
            return
        end
        if aidoku.syncCurrentEpubProgress then
            aidoku:syncCurrentEpubProgress(false)
        end
        EpubHelper.prepareJumpToChapter(item.epub_path, item.chapter_key, {
            ui = aidoku.ui,
            frag_index = item.frag_index,
            sync_typography_from = aidoku.ui and aidoku.ui.doc_settings or nil,
        })
        if aidoku.ui and aidoku.ui.switchDocument then
            aidoku.ui:switchDocument(item.epub_path)
        end
    end

    local function openVolumePicker()
        local vol_items = {}
        for _vi, v in ipairs(book.volumes) do
            local v_start = v.volumeStart > 0 and v.volumeStart or 1
            local v_end = v.volumeEnd >= v_start and v.volumeEnd or (v_start + #v.chapters - 1)
            local first_title = v.chapters[1] and cleanTitle(v.chapters[1].title) or ""
            table.insert(vol_items, {
                text = T(_("Vol.%1 (%2–%3)"), v.volumeIndex, v_start, v_end),
                mandatory = first_title,
                bold = (current_vol_idx == v.volumeIndex),
                volume = v,
            })
        end
        if current_vol_idx then
            for i, vi in ipairs(vol_items) do
                if vi.volume.volumeIndex == current_vol_idx then
                    vol_items.current = i
                    break
                end
            end
        end

        local vol_menu = Menu:new{
            title = _("Jump to volume"),
            subtitle = book.title or "",
            ui = aidoku.ui,
            is_borderless = true,
            is_popout = false,
            single_line = true,
            align_baselines = true,
            items_per_page = items_per_page,
            items_font_size = items_font_size,
            title_bar_fm_style = true,
        }
        local vol_container = CenterContainer:new{
            dimen = Screen:getSize(),
            covers_fullscreen = true,
            vol_menu,
        }
        vol_menu.close_callback = function()
            UIManager:close(vol_container)
        end
        function vol_menu:onCloseWidget()
            OpenWidgets.remove(vol_container)
            Menu.onCloseWidget(self)
        end
        vol_menu.show_parent = vol_container
        OpenWidgets.push(vol_container)
        function vol_menu:onMenuSelect(vitem)
            vol_menu:close_callback()
            if not vitem or not vitem.volume then
                return true
            end
            search_query = nil
            local target_global = vitem.volume.firstGlobalIndex or 1
            toc_menu:switchItemTable(nil, full_items, target_global, nil, default_subtitle)
            return true
        end
        function vol_menu:onMenuHold(vitem)
            vol_menu:close_callback()
            local first_ch = vitem and vitem.volume and vitem.volume.chapters and vitem.volume.chapters[1]
            if first_ch then
                navigateToItem({
                    epub_path = first_ch.epubPath,
                    chapter_key = first_ch.key,
                    frag_index = first_ch.fragIndex,
                })
            end
            return true
        end
        vol_menu:switchItemTable(nil, vol_items, vol_items.current or 1)
        UIManager:show(vol_container)
    end

    local function promptSearch()
        if search_query then
            search_query = nil
            toc_menu:switchItemTable(nil, full_items, full_items.current or -1, nil, default_subtitle)
            return
        end
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("Enter text to search for"),
            buttons = {{
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local str = input_dialog:getInputText()
                        if not str or str == "" then
                            return
                        end
                        UIManager:close(input_dialog)
                        local filtered = buildTocItems(book, norm_cur, cur_vol_pages, cur_vol_xps, current_global_idx, str)
                        if #filtered == 0 then
                            UIManager:show(InfoMessage:new{
                                text = _("No results in table of contents"),
                                timeout = 2,
                            })
                            return
                        end
                        search_query = str
                        toc_menu:switchItemTable(
                            nil,
                            filtered,
                            1,
                            nil,
                            T(_("Query: %1 (%2)"), str, #filtered)
                        )
                    end,
                },
            }},
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end

    local function showTocActions()
        local dialog
        local buttons = {
            {{
                text = search_query and _("Clear TOC search") or _("Search table of contents"),
                callback = function()
                    UIManager:close(dialog)
                    promptSearch()
                end,
            }},
            {{
                text = _("Jump to volume…"),
                callback = function()
                    UIManager:close(dialog)
                    openVolumePicker()
                end,
            }},
        }
        if type(original_on_show_toc) == "function" then
            table.insert(buttons, {{
                text = _("Current volume TOC"),
                callback = function()
                    UIManager:close(dialog)
                    if toc_menu and toc_menu.close_callback then
                        toc_menu:close_callback()
                    end
                    original_on_show_toc(toc_self)
                end,
            }})
        end
        if type(aidoku.openSeriesForFile) == "function" then
            table.insert(buttons, {{
                text = _("Open in Tsundoku"),
                callback = function()
                    UIManager:close(dialog)
                    if toc_menu and toc_menu.close_callback then
                        toc_menu:close_callback()
                    end
                    aidoku:openSeriesForFile(file, true)
                end,
            }})
        end

        dialog = ButtonDialog:new{
            shrink_unneeded_width = true,
            anchor = function()
                return toc_menu and toc_menu.title_bar and toc_menu.title_bar.left_button
                    and toc_menu.title_bar.left_button.image and toc_menu.title_bar.left_button.image.dimen
            end,
            buttons = buttons,
        }
        UIManager:show(dialog)
    end

    toc_menu = Menu:new{
        title = _("Table of contents"),
        subtitle = default_subtitle,
        state_w = 0,
        ui = aidoku.ui,
        is_borderless = true,
        is_popout = false,
        single_line = true,
        align_baselines = true,
        with_dots = items_with_dots,
        items_per_page = items_per_page,
        items_font_size = items_font_size,
        line_color = Blitbuffer.COLOR_WHITE,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = showTocActions,
        on_close_ges = {
            GestureRange:new{
                ges = "two_finger_swipe",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                },
                direction = BD.flipDirectionIfMirroredUILayout("west"),
            },
        },
    }

    menu_container = CenterContainer:new{
        dimen = Screen:getSize(),
        covers_fullscreen = true,
        toc_menu,
    }

    function toc_menu:onMenuSelect(item)
        navigateToItem(item)
        return true
    end

    function toc_menu:onMenuHold(item)
        if not item then
            return true
        end
        local v_start = item.volume_start and item.volume_start > 0 and item.volume_start or 1
        local v_end = item.volume_end and item.volume_end >= v_start and item.volume_end or v_start
        UIManager:show(InfoMessage:new{
            width = Screen:getWidth() - 48,
            alignment = "center",
            show_icon = false,
            text = T(_("%1\n\nVol.%2 (%3–%4)"), item.text, item.volume_index or 1, v_start, v_end),
            face = Font:getFace("infofont", items_font_size),
        })
        return true
    end

    toc_menu.close_callback = function()
        UIManager:close(menu_container)
    end
    function toc_menu:onCloseWidget()
        OpenWidgets.remove(menu_container)
        BD.resetInvert()
        Menu.onCloseWidget(self)
    end

    toc_menu.show_parent = menu_container
    OpenWidgets.push(menu_container)

    toc_menu:switchItemTable(nil, full_items, full_items.current or -1)
    UIManager:show(menu_container)
    return true
end

return BookToc
