--[[--
Prompts for a search query against one installed source and lists the
results, annotating both bookmarked (★) and already-downloaded (✓) manga.
]]

local ButtonDialog = require("ui/widget/buttondialog")
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

local SearchBrowser = Menu:extend{
    title_bar_left_icon = "appbar.menu",
}

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
    self.search_page = 1
    self.has_next_page = false
    self.query = nil
    self.active_listing = nil
    self.available_filters = nil
    self.available_listings = nil
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

function SearchBrowser:onLeftButtonTap()
    local dialog
    local buttons = {
        {{
            text = _("New search…"),
            callback = function()
                UIManager:close(dialog)
                self:promptQuery()
            end,
        }},
    }
    if self.available_filters and #self.available_filters > 0 then
        table.insert(buttons, {{
            text = _("Search filters…"),
            callback = function()
                UIManager:close(dialog)
                self:openFilters()
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Browse source listings…"),
        callback = function()
            UIManager:close(dialog)
            self:promptListings()
        end,
    }})
    if self.source_key == "kox" then
        table.insert(buttons, {{
            text = _("Koobone Bookshelf…"),
            callback = function()
                UIManager:close(dialog)
                local KooboneBrowser = require("koobonebrowser")
                UIManager:show(KooboneBrowser:new{
                    engine = self.engine,
                    store = self.store,
                    downloads_engine = self.downloads_engine,
                    ui = self.ui,
                    sources_dir = self.sources_dir,
                    downloads_dir = self.downloads_dir,
                    source_path = self.source_path,
                    is_popout = false,
                    is_borderless = true,
                    title_bar_fm_style = true,
                    refresh_callback = self.refresh_callback,
                })
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Source settings…"),
        callback = function()
            UIManager:close(dialog)
            local SourceSettingsBrowser = require("sourcesettingsbrowser")
            UIManager:show(SourceSettingsBrowser:new{
                engine = self.engine,
                store = self.store,
                downloads_engine = self.downloads_engine,
                ui = self.ui,
                sources_dir = self.sources_dir,
                downloads_dir = self.downloads_dir,
                source_path = self.source_path,
                source_key = self.source_key,
                source_text = self.source_name or self.title,
                is_popout = false,
                is_borderless = true,
                title_bar_fm_style = true,
                refresh_callback = self.refresh_callback,
            })
        end,
    }})
    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function() return self.title_bar.left_button.image.dimen end,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function SearchBrowser:promptListings()
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local list = self.engine:listings(self.source_path)
            if type(list) ~= "table" or #list == 0 then
                UIManager:show(InfoMessage:new{ text = _("This source has no listings."), timeout = 2 })
                return
            end
            local dialog
            local buttons = {}
            for _idx, l in ipairs(list) do
                local lid = l.ID or l.id or ""
                local lname = l.Name or l.name or lid
                if lid ~= "" then
                    table.insert(buttons, {{
                        text = lname,
                        callback = function()
                            UIManager:close(dialog)
                            self:runListing({ id = lid, name = lname }, 1)
                        end,
                    }})
                end
            end
            dialog = ButtonDialog:new{
                title = _("Browse listings"),
                buttons = buttons,
            }
            UIManager:show(dialog)
        end)
    end)
end

function SearchBrowser:runListing(listing, page_num)
    self.active_listing = listing
    self.query = nil
    self.search_page = page_num or 1
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local result, err = self.engine:listingGet(self.source_path, listing.id, self.search_page, listing.name)
            if not result then
                UIManager:show(InfoMessage:new{ text = T(_("Could not load listing:\n%1"), err) })
                return
            end
            local entries = type(result.Entries) == "table" and result.Entries or {}
            if self.search_page == 1 then
                self.raw_entries = entries
                self.page = 1
            else
                for _i, m in ipairs(entries) do
                    table.insert(self.raw_entries, m)
                end
            end
            self.has_next_page = (result.HasNextPage == true)
            self:rebuildList()
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
            self:runSearch(self.query or "", 1)
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
                text = _("Browse"),
                callback = function()
                    UIManager:close(dialog)
                    self:runSearch("", 1)
                end,
            },
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
                    self:runSearch(query or "", 1)
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

    if self.has_next_page then
        table.insert(item_table, {
            text = T(_("» Load next page (Page %1)…"), (self.search_page or 1) + 1),
            bold = true,
            is_next_page_entry = true,
        })
    end

    local saved_page = self.page
    self.item_table = item_table
    self:updateItems(saved_page)
end

function SearchBrowser:runSearch(query, page_num)
    self.query = query or ""
    self.active_listing = nil
    self.search_page = page_num or 1
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local filters = {}
            for _idx, v in pairs(self.filter_values) do
                table.insert(filters, v)
            end
            local result, err = self.engine:search(self.source_path, self.query, self.search_page, filters)
            if not result then
                UIManager:show(InfoMessage:new{ text = T(_("Search failed:\n%1"), err) })
                return
            end
            local entries = type(result.Entries) == "table" and result.Entries or {}
            if self.search_page == 1 then
                self.raw_entries = entries
                if #self.raw_entries == 0 then
                    UIManager:show(InfoMessage:new{ text = _("No results."), timeout = 2 })
                end
                self.page = 1
            else
                for _i, m in ipairs(entries) do
                    table.insert(self.raw_entries, m)
                end
            end
            self.has_next_page = (result.HasNextPage == true)
            self:rebuildList()
        end)
    end)
end

function SearchBrowser:onMenuSelect(item)
    if item.is_filters_entry then
        self:openFilters()
        return true
    elseif item.is_next_page_entry then
        if self.active_listing then
            self:runListing(self.active_listing, (self.search_page or 1) + 1)
        else
            self:runSearch(self.query or "", (self.search_page or 1) + 1)
        end
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
    if item.is_filters_entry or item.is_next_page_entry then
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
