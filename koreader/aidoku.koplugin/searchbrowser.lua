--[[--
Prompts for a search query against one installed source and lists the
results, annotating both bookmarked (★) and already-downloaded (✓) manga.
]]

local DownloadsEngine = require("downloadsengine")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local OpenWidgets = require("openwidgets")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local SearchBrowser = Menu:extend{}

local function mangaLabel(manga)
    if type(manga.Title) == "string" and manga.Title ~= "" then
        return manga.Title
    end
    return manga.Key
end

local function mangaCover(manga)
    return type(manga.Cover) == "string" and manga.Cover or nil
end

function SearchBrowser:init()
    self.subtitle = _("Hold a result to add/remove from library")
    self.item_table = {}
    self.raw_entries = {}
    self.page = 1
    self.query = nil
    self.available_filters = nil
    self.filter_values = {}
    Menu.init(self)
    OpenWidgets.push(self)

    UIManager:nextTick(function()
        Trapper:wrap(function()
            self:reloadFilters()
            self:promptQuery()
        end)
    end)
end

function SearchBrowser:onCloseWidget()
    Menu.onCloseWidget(self)
    OpenWidgets.remove(self)
end

function SearchBrowser:reloadFilters()
    local result = self.engine:filters(self.source_path)
    self.available_filters = type(result) == "table" and result or {}
end

function SearchBrowser:openFilters()
    local FilterBrowser = require("filterbrowser")
    UIManager:show(FilterBrowser:new{
        all_filters = self.available_filters,
        initial_values = self.filter_values,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        on_apply = function(values)
            self.filter_values = values
            if self.query then
                self:runSearch(self.query)
            end
        end,
    })
end

function SearchBrowser:promptQuery()
    local dialog
    dialog = InputDialog:new{
        title = _("Search manga"),
        input_hint = _("Title…"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    if query and query ~= "" then
                        self:runSearch(query)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SearchBrowser:rebuildList()
    local dl_stats = self.downloads_engine:mangaDownloadStats()
    local meta_map = self.store:getMangaMetaMap()
    local item_table = {}
    if self.available_filters and #self.available_filters > 0 then
        local n = 0
        for _idx in pairs(self.filter_values) do n = n + 1 end
        local label = n > 0 and T(_("Filters (%1 set)…"), n) or _("Filters…")
        table.insert(item_table, { text = label, is_filters_entry = true })
    end

    for _idx, manga in ipairs(self.raw_entries) do
        local title = mangaLabel(manga)
        local prefixes = {}
        if self.store:isBookmarked(self.source_key, manga.Key) then
            table.insert(prefixes, "★")
        end
        local dl_group = DownloadsEngine.lookupMangaGroup(dl_stats, self.source_key, manga.Key, title)
        local mandatory = ""
        if dl_group and dl_group.count > 0 then
            table.insert(prefixes, "✓")
            local meta = meta_map[self.source_key .. "\0" .. manga.Key]
                or meta_map[self.source_key .. "\0" .. dl_group.mangaKey]
            local total_ch = meta and meta.chapter_count or 0
            if total_ch > 0 and dl_group.count >= total_ch then
                mandatory = T(_("Downloaded all %1 ch"), dl_group.count)
            else
                mandatory = T(_("Downloaded %1 ch"), dl_group.count)
            end
        end
        local prefix_str = #prefixes > 0 and (table.concat(prefixes, " ") .. " ") or ""
        table.insert(item_table, {
            text = prefix_str .. title,
            mandatory = mandatory,
            manga = manga,
        })
    end

    local saved_page = self.page
    self.item_table = item_table
    self:updateItems(saved_page)
end

function SearchBrowser:runSearch(query)
    self.query = query
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local filters = {}
            for _idx, v in pairs(self.filter_values) do
                table.insert(filters, v)
            end
            local result, err = self.engine:search(self.source_path, query, self.page, filters)
            if not result then
                UIManager:show(InfoMessage:new{ text = T(_("Search failed:\n%1"), err) })
                return
            end
            self.raw_entries = type(result.Entries) == "table" and result.Entries or {}
            if #self.raw_entries == 0 then
                UIManager:show(InfoMessage:new{ text = _("No results."), timeout = 2 })
            end
            self.page = 1
            self:rebuildList()
        end)
    end)
end

function SearchBrowser:onMenuSelect(item)
    if item.is_filters_entry then
        self:openFilters()
        return true
    end
    local MangaBrowser = require("mangabrowser")
    UIManager:show(MangaBrowser:new{
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        source_path = self.source_path,
        source_key = self.source_key,
        source_name = self.source_name,
        downloads_dir = self.downloads_dir,
        manga = item.manga,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        refresh_callback = function()
            self:rebuildList()
            if self.refresh_callback then
                self.refresh_callback()
            end
        end,
    })
    return true
end

function SearchBrowser:onMenuHold(item)
    if item.is_filters_entry then
        return true
    end
    local manga = item.manga
    local label = mangaLabel(manga)
    local now_bookmarked, ok
    if self.store:isBookmarked(self.source_key, manga.Key) then
        ok = self.store:removeBookmark(self.source_key, manga.Key)
        now_bookmarked = false
    else
        ok = self.store:addBookmark(self.source_key, self.source_path, manga.Key, label, mangaCover(manga))
        now_bookmarked = true
    end
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not update library."), timeout = 2 })
        return true
    end
    self:rebuildList()
    if self.refresh_callback then
        self.refresh_callback()
    end
    UIManager:show(InfoMessage:new{
        text = now_bookmarked and T(_("Added '%1' to library"), label) or T(_("Removed '%1' from library"), label),
        timeout = 1.5,
    })
    return true
end

return SearchBrowser
