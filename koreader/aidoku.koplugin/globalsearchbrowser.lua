--[[--
GlobalSearchBrowser (Multi-source Search Plus / 多书源搜索 Plus):
1. Source Selection step first: lets the user pick which installed sources to
   include in the upcoming batch search (with Select All / Deselect All / Invert
   and persistent selection across sessions).
2. Batch Search step: searches ONLY the user-selected sources, showing per-source
   progress ("Searching (2/5): <source>…"), annotating both bookmarked (★) and
   already-downloaded (✓) manga, with quick menu access to re-query or adjust
   selected sources anytime.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DownloadsEngine = require("downloadsengine")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local InstalledSources = require("installedsources")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local OpenWidgets = require("openwidgets")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local GlobalSearchBrowser = Menu:extend{
    title = _("Multi-source Search"),
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

function GlobalSearchBrowser:init()
    self.mode = "select_sources" -- "select_sources" | "results"
    self.sources = {}
    self.selected_map = {} -- source_key -> boolean
    self.last_query = ""
    self.results_items = {}
    self.item_table = {}
    Menu.init(self)
    OpenWidgets.push(self)

    UIManager:nextTick(function()
        self:loadSourcesAndShowSelector()
    end)
end

function GlobalSearchBrowser:onCloseWidget()
    Menu.onCloseWidget(self)
    OpenWidgets.remove(self)
end

function GlobalSearchBrowser:selectedCount()
    local n, valid_total = 0, 0
    for _idx, src in ipairs(self.sources) do
        if src.key then
            valid_total = valid_total + 1
            if self.selected_map[src.key] then
                n = n + 1
            end
        end
    end
    return n, valid_total
end

function GlobalSearchBrowser:persistSelection()
    local copy = {}
    for _idx, src in ipairs(self.sources) do
        if src.key then
            copy[src.key] = self.selected_map[src.key] and true or false
        end
    end
    self.store:setSelectedSearchSources(copy)
end

function GlobalSearchBrowser:loadSourcesAndShowSelector()
    Trapper:wrap(function()
        self.sources = InstalledSources.list(self.sources_dir, self.engine)
        local saved = self.store:selectedSearchSources()
        self.selected_map = {}
        for _idx, src in ipairs(self.sources) do
            if src.key then
                if saved == nil then
                    self.selected_map[src.key] = true
                elseif saved[src.key] == nil then
                    -- Newly installed source defaults to enabled unless user cleared all
                    self.selected_map[src.key] = false
                else
                    self.selected_map[src.key] = saved[src.key] and true or false
                end
            end
        end
        self:showSourceSelector()
    end)
end

function GlobalSearchBrowser:showSourceSelector()
    self.mode = "select_sources"
    local sel_count, valid_total = self:selectedCount()

    if self.title_bar then
        self.title_bar:setTitle(_("Select Search Sources"))
        self.title_bar:setSubTitle(
            T(_("Tap sources to toggle (%1/%2 selected), then tap Start Search"), sel_count, valid_total),
            true
        )
    end

    local items = {}
    if valid_total == 0 then
        table.insert(items, {
            text = _("No sources installed. Install sources in Settings → Sources first."),
            dim = true,
            is_placeholder = true,
        })
    else
        table.insert(items, {
            text = T(_("» Start Search (%1/%2 sources selected)…"), sel_count, valid_total),
            mandatory = _("Search >"),
            bold = true,
            is_start_search = true,
        })
        if sel_count < valid_total then
            table.insert(items, {
                text = _("[✓] Select all sources"),
                mandatory = sel_count > 0 and _("Invert on hold") or "",
                is_toggle_all = true,
                select_all = true,
            })
        else
            table.insert(items, {
                text = _("[ ] Deselect all sources"),
                mandatory = _("Invert on hold"),
                is_toggle_all = true,
                select_all = false,
            })
        end

        for _idx, src in ipairs(self.sources) do
            if src.key then
                local checked = self.selected_map[src.key] and true or false
                table.insert(items, {
                    text = (checked and "[✓] " or "[ ] ") .. src.text,
                    mandatory = checked and _("Selected") or "",
                    source_entry = src,
                })
            end
        end
    end

    local saved_page = self.mode == "select_sources" and self.page or 1
    self.item_table = items
    self:updateItems(saved_page)
end

function GlobalSearchBrowser:formatResultRow(entry, dl_stats, meta_map)
    local manga = entry.manga
    local title = mangaLabel(manga)
    local prefixes = {}
    if self.store:isBookmarked(entry.source_key, manga.Key) then
        table.insert(prefixes, "★")
    end

    local dl_group = DownloadsEngine.lookupMangaGroup(dl_stats, entry.source_key, manga.Key, title)
    local dl_badge = nil
    if dl_group and dl_group.count > 0 then
        table.insert(prefixes, "✓")
        local meta = meta_map[entry.source_key .. "\0" .. manga.Key]
            or meta_map[entry.source_key .. "\0" .. dl_group.mangaKey]
        local total_ch = meta and meta.chapter_count or 0
        if total_ch > 0 and dl_group.count >= total_ch then
            dl_badge = T(_("Downloaded all %1 ch"), dl_group.count)
        else
            dl_badge = T(_("Downloaded %1 ch"), dl_group.count)
        end
    end

    local prefix_str = #prefixes > 0 and (table.concat(prefixes, " ") .. " ") or ""
    local right_str = entry.source_name
    if dl_badge then
        right_str = dl_badge .. " · " .. entry.source_name
    end

    entry.text = prefix_str .. title
    entry.mandatory = right_str
    return entry
end

function GlobalSearchBrowser:refreshResultsMarkers()
    if self.mode ~= "results" then
        return
    end
    local dl_stats = self.downloads_engine:mangaDownloadStats()
    local meta_map = self.store:getMangaMetaMap()
    local items = {
        {
            text = T(_("» Change sources (%1/%2) or search again…"), self:selectedCount()),
            mandatory = self.last_query ~= "" and T(_("Query: %1"), self.last_query) or "",
            bold = true,
            is_search_header = true,
        },
    }
    for _idx, r in ipairs(self.results_items) do
        table.insert(items, self:formatResultRow(r, dl_stats, meta_map))
    end
    local saved_page = self.page
    self.item_table = items
    self:updateItems(saved_page)
end

function GlobalSearchBrowser:showResultsView(searched_count, failed_names)
    self.mode = "results"
    if self.title_bar then
        self.title_bar:setTitle(T(_("Search: %1"), self.last_query))
        local sub = T(_("%1 results from %2 selected sources · Hold to bookmark"),
            #self.results_items, searched_count)
        if failed_names and #failed_names > 0 then
            sub = sub .. T(_(" (%1 failed)"), #failed_names)
        end
        self.title_bar:setSubTitle(sub, true)
    end
    self.page = 1
    self:refreshResultsMarkers()
end

function GlobalSearchBrowser:promptQuery()
    local sel_count = self:selectedCount()
    if sel_count == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Please select at least one source before searching."),
            timeout = 2,
        })
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = T(_("Search in %1 selected source(s)"), sel_count),
        input = self.last_query,
        input_hint = _("Title…"),
        buttons = {{
            {
                text = _("Sources…"),
                callback = function()
                    UIManager:close(dialog)
                    self:showSourceSelector()
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

function GlobalSearchBrowser:runSearch(query)
    local target_sources = {}
    for _idx, src in ipairs(self.sources) do
        if src.key and self.selected_map[src.key] then
            table.insert(target_sources, src)
        end
    end
    if #target_sources == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Please select at least one source before searching."),
            timeout = 2,
        })
        return
    end

    self.last_query = query
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local raw_results = {}
            local failed = {}
            local stopped_early = false

            for idx, src in ipairs(target_sources) do
                local progress_msg = T(_("Searching (%1/%2): %3…"), idx, #target_sources, src.name)
                local result, err = self.engine:search(src.path, query, 1, nil, progress_msg)
                if not result and err == _("Cancelled") then
                    stopped_early = true
                    break
                end
                local entries = result and type(result.Entries) == "table" and result.Entries or nil
                if entries then
                    for _i, manga in ipairs(entries) do
                        table.insert(raw_results, {
                            manga = manga,
                            source_path = src.path,
                            source_key = src.key,
                            source_name = src.name,
                        })
                    end
                else
                    table.insert(failed, src.name or src.text)
                end
            end

            self.results_items = raw_results
            self:showResultsView(#target_sources, failed)

            if stopped_early then
                UIManager:show(InfoMessage:new{
                    text = T(_("Search stopped early (%1 results kept)."), #raw_results),
                    timeout = 2,
                })
            elseif #raw_results == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("No results in the selected sources."),
                    timeout = 2,
                })
            elseif #failed > 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_("Some sources failed: %1"), table.concat(failed, ", ")),
                    timeout = 3,
                })
            end
        end)
    end)
end

function GlobalSearchBrowser:invertSelection()
    for _idx, src in ipairs(self.sources) do
        if src.key then
            self.selected_map[src.key] = not self.selected_map[src.key]
        end
    end
    self:persistSelection()
    self:showSourceSelector()
end

function GlobalSearchBrowser:onLeftButtonTap()
    local sel_count, valid_total = self:selectedCount()
    local dialog
    local buttons = {
        {{
            text = T(_("Search keyword (%1/%2 sources)…"), sel_count, valid_total),
            callback = function()
                UIManager:close(dialog)
                self:promptQuery()
            end,
        }},
    }

    if self.mode == "results" then
        table.insert(buttons, {{
            text = T(_("Select search sources (%1/%2)…"), sel_count, valid_total),
            callback = function()
                UIManager:close(dialog)
                self.page = 1
                self:showSourceSelector()
            end,
        }})
    else
        table.insert(buttons, {{
            text = _("Select all sources"),
            callback = function()
                UIManager:close(dialog)
                for _idx, src in ipairs(self.sources) do
                    if src.key then self.selected_map[src.key] = true end
                end
                self:persistSelection()
                self:showSourceSelector()
            end,
        }})
        table.insert(buttons, {{
            text = _("Deselect all sources"),
            callback = function()
                UIManager:close(dialog)
                for _idx, src in ipairs(self.sources) do
                    if src.key then self.selected_map[src.key] = false end
                end
                self:persistSelection()
                self:showSourceSelector()
            end,
        }})
        table.insert(buttons, {{
            text = _("Invert selection"),
            callback = function()
                UIManager:close(dialog)
                self:invertSelection()
            end,
        }})
        if #self.results_items > 0 then
            table.insert(buttons, {{
                text = T(_("Back to last results (%1)"), #self.results_items),
                callback = function()
                    UIManager:close(dialog)
                    self:showResultsView(sel_count, nil)
                end,
            }})
        end
    end

    table.insert(buttons, {{
        text = _("Download Manager"),
        callback = function()
            UIManager:close(dialog)
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
        end,
    }})

    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function() return self.title_bar.left_button.image.dimen end,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function GlobalSearchBrowser:onMenuSelect(item)
    if item.is_placeholder then
        return true
    end
    if self.mode == "select_sources" then
        if item.is_start_search then
            self:promptQuery()
            return true
        elseif item.is_toggle_all then
            for _idx, src in ipairs(self.sources) do
                if src.key then
                    self.selected_map[src.key] = item.select_all
                end
            end
            self:persistSelection()
            self:showSourceSelector()
            return true
        elseif item.source_entry and item.source_entry.key then
            local k = item.source_entry.key
            self.selected_map[k] = not self.selected_map[k]
            self:persistSelection()
            self:showSourceSelector()
            return true
        end
        return true
    end

    -- Results mode
    if item.is_search_header then
        local dialog
        dialog = ButtonDialog:new{
            title = _("Multi-source Search"),
            buttons = {
                {{
                    text = _("New search with current sources…"),
                    callback = function()
                        UIManager:close(dialog)
                        self:promptQuery()
                    end,
                }},
                {{
                    text = T(_("Change selected sources (%1/%2)…"), self:selectedCount()),
                    callback = function()
                        UIManager:close(dialog)
                        self.page = 1
                        self:showSourceSelector()
                    end,
                }},
            },
        }
        UIManager:show(dialog)
        return true
    end

    local MangaBrowser = require("mangabrowser")
    UIManager:show(MangaBrowser:new{
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        source_path = item.source_path,
        source_key = item.source_key,
        source_name = item.source_name,
        downloads_dir = self.downloads_dir,
        manga = item.manga,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        refresh_callback = function()
            self:refreshResultsMarkers()
            if self.refresh_callback then
                self.refresh_callback()
            end
        end,
    })
    return true
end

function GlobalSearchBrowser:onMenuHold(item)
    if item.is_placeholder then
        return true
    end
    if self.mode == "select_sources" then
        if item.is_toggle_all then
            self:invertSelection()
            return true
        elseif item.source_entry and item.source_entry.key then
            -- Holding a single source offers "Search ONLY this source right now"
            local src = item.source_entry
            local dialog
            dialog = ButtonDialog:new{
                title = src.text,
                buttons = {
                    {{
                        text = _("Select ONLY this source & search…"),
                        callback = function()
                            UIManager:close(dialog)
                            for _idx, s in ipairs(self.sources) do
                                if s.key then
                                    self.selected_map[s.key] = (s.key == src.key)
                                end
                            end
                            self:persistSelection()
                            self:showSourceSelector()
                            self:promptQuery()
                        end,
                    }},
                    {{
                        text = _("Invert all selections"),
                        callback = function()
                            UIManager:close(dialog)
                            self:invertSelection()
                        end,
                    }},
                },
            }
            UIManager:show(dialog)
            return true
        end
        return true
    end

    if item.is_search_header or not item.manga then
        return true
    end

    local manga = item.manga
    local label = mangaLabel(manga)
    local now_bookmarked, ok
    if self.store:isBookmarked(item.source_key, manga.Key) then
        ok = self.store:removeBookmark(item.source_key, manga.Key)
        now_bookmarked = false
    else
        ok = self.store:addBookmark(item.source_key, item.source_path, manga.Key, label, mangaCover(manga))
        now_bookmarked = true
    end
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not update library."), timeout = 2 })
        return true
    end
    self:refreshResultsMarkers()
    if self.refresh_callback then
        self.refresh_callback()
    end
    UIManager:show(InfoMessage:new{
        text = now_bookmarked and T(_("Added '%1' to library"), label) or T(_("Removed '%1' from library"), label),
        timeout = 1.5,
    })
    return true
end

return GlobalSearchBrowser
