--[[--
Prompts for a search query against one installed source and lists the
results asynchronously without blocking the UI, annotating both bookmarked (★)
and already-downloaded (✓) manga, supporting interruption and dynamic Page 2+.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DownloadsEngine = require("downloadsengine")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local OpenWidgets = require("openwidgets")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local json = require("json")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local POLL_INTERVAL = 0.30
local FILTER_POLL_INTERVAL = 0.25
local VIS_WATCH_INTERVAL = 0.45

local SearchBrowser = Menu:extend{
    name = "tsundoku_single_search",
    title_bar_left_icon = "appbar.menu",
}

local function mangaLabel(manga)
    if type(manga) == "table" and type(manga.Title) == "string" and manga.Title ~= "" then
        return manga.Title
    end
    return type(manga) == "table" and tostring(manga.Key or "") or ""
end

local function mangaCover(manga)
    return type(manga) == "table" and type(manga.Cover) == "string" and manga.Cover or nil
end

local function isCoveredByModalOrScreen(widget)
    local stack = UIManager._window_stack
    if type(stack) ~= "table" or #stack == 0 then
        return false
    end
    local covered_above = false
    for i = #stack, 1, -1 do
        local entry = stack[i]
        local w = entry and entry.widget
        if w == widget then
            return covered_above
        end
        if w and not w.invisible and not w.toast then
            covered_above = true
        end
    end
    return false
end

local function leftButtonAnchor(self)
    local lb = self.title_bar and self.title_bar.left_button
    return lb and (lb.image and lb.image.dimen or lb.dimen) or nil
end

function SearchBrowser:init()
    self.subtitle = _("Hold a result to add/remove from library")
    self.item_table = {}
    self.raw_entries = {}
    self.seen_keys = {}
    self.page = 1
    self.search_page = 1
    self.has_next_page = false
    self.query = nil
    self.active_listing = nil
    self.available_filters = nil
    self.available_listings = nil
    self.filter_values = {}
    self.active_handle = nil
    self.filters_handle = nil
    self.loading_state = nil
    self.poll_cb = nil
    self.filter_poll_cb = nil
    self.vis_watch_cb = nil
    self.pending_ui_sync = false
    self.standby_prevented = false
    Menu.init(self)
    OpenWidgets.push(self)

    UIManager:nextTick(function()
        if self.closed then
            return
        end
        self:startAsyncFilterLoad()
        self:promptQuery()
    end)
end

function SearchBrowser:updateStandbyGuard()
    local should_hold = (self.active_handle ~= nil)
    if should_hold and not self.standby_prevented then
        self.standby_prevented = true
        UIManager:preventStandby()
    elseif not should_hold and self.standby_prevented then
        self.standby_prevented = false
        UIManager:allowStandby()
    end
end

function SearchBrowser:unscheduleTimers()
    if self.poll_cb then
        UIManager:unschedule(self.poll_cb)
        self.poll_cb = nil
    end
    if self.filter_poll_cb then
        UIManager:unschedule(self.filter_poll_cb)
        self.filter_poll_cb = nil
    end
    if self.vis_watch_cb then
        UIManager:unschedule(self.vis_watch_cb)
        self.vis_watch_cb = nil
    end
end

function SearchBrowser:cancelActiveSearch()
    if self.poll_cb then
        UIManager:unschedule(self.poll_cb)
        self.poll_cb = nil
    end
    if self.active_handle then
        self.active_handle:cancel()
        self.active_handle = nil
    end
    self.loading_state = nil
    self:updateStandbyGuard()
end

function SearchBrowser:onCloseWidget()
    self.closed = true
    self:unscheduleTimers()
    self:cancelActiveSearch()
    if self.filters_handle then
        self.filters_handle:cancel()
        self.filters_handle = nil
    end
    Menu.onCloseWidget(self)
    OpenWidgets.remove(self)
end

function SearchBrowser:startAsyncFilterLoad()
    if self.filters_handle or self.available_filters ~= nil or not self.engine.spawnFilters then
        return
    end
    local handle = self.engine:spawnFilters(self.source_path)
    if not handle then
        self.available_filters = {}
        return
    end
    self.filters_handle = handle

    local function scheduleFilterPoll()
        if self.closed or not self.filters_handle then
            return
        end
        self.filter_poll_cb = function()
            self.filter_poll_cb = nil
            if self.closed or not self.filters_handle then
                return
            end
            local st, out = self.filters_handle:poll()
            if st == "running" then
                scheduleFilterPoll()
                return
            end
            self.filters_handle = nil
            if st == "done" and type(out) == "string" and out ~= "" then
                local ok, decoded = pcall(json.decode, out)
                self.available_filters = (ok and type(decoded) == "table") and decoded or {}
            else
                self.available_filters = {}
            end
            if #self.available_filters > 0 and (#self.raw_entries > 0 or self.loading_state ~= nil or self.query ~= nil or self.active_listing ~= nil) then
                self:rebuildList(true)
            end
        end
        UIManager:scheduleIn(FILTER_POLL_INTERVAL, self.filter_poll_cb)
    end
    scheduleFilterPoll()
end

function SearchBrowser:onLeftButtonTap()
    local dialog
    local buttons = {}
    if self.active_handle and self.loading_state then
        table.insert(buttons, {{
            text = _("■ Stop loading"),
            callback = function()
                UIManager:close(dialog)
                self:stopLoading(false)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("New search…"),
        callback = function()
            UIManager:close(dialog)
            self:promptQuery()
        end,
    }})
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
        anchor = function() return leftButtonAnchor(self) end,
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
                local lid = type(l.ID) == "string" and l.ID or (type(l.id) == "string" and l.id or "")
                local lname = type(l.Name) == "string" and l.Name or (type(l.name) == "string" and l.name or lid)
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

function SearchBrowser:reloadFilters()
    local result = self.engine:filters(self.source_path)
    self.available_filters = type(result) == "table" and result or {}
end

function SearchBrowser:openFilters()
    local FilterBrowser = require("filterbrowser")
    UIManager:show(FilterBrowser:new{
        all_filters = self.available_filters or {},
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
        input = self.query or "",
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

function SearchBrowser:buildSubtitle()
    local st = self.loading_state
    if st then
        if st.page > 1 then
            return T(_("Loading Page %1… (Tap status row to stop)"), st.page)
        elseif st.is_listing and st.listing and type(st.listing.name) == "string" and st.listing.name ~= "" then
            return T(_("Loading %1… (Tap status row to stop)"), st.listing.name)
        end
        return _("Searching… (Tap status row to stop)")
    end
    return _("Hold a result to add/remove from library")
end

function SearchBrowser:scheduleVisibilityWatch()
    if self.vis_watch_cb or self.closed then
        return
    end
    self.vis_watch_cb = function()
        self.vis_watch_cb = nil
        if self.closed or not self.pending_ui_sync then
            return
        end
        if isCoveredByModalOrScreen(self) then
            self:scheduleVisibilityWatch()
            return
        end
        self.pending_ui_sync = false
        self:rebuildList(true)
    end
    UIManager:scheduleIn(VIS_WATCH_INTERVAL, self.vis_watch_cb)
end

function SearchBrowser:rebuildList(preserve_page)
    if isCoveredByModalOrScreen(self) then
        self.pending_ui_sync = true
        self:scheduleVisibilityWatch()
        return
    end
    self.pending_ui_sync = false

    local st = self.loading_state
    local dl_stats = self.downloads_engine:mangaDownloadStats()
    local meta_map = self.store:getMangaMetaMap()
    local item_table = {}

    if st and st.page == 1 then
        local loading_text = (st.is_listing and st.listing and type(st.listing.name) == "string" and st.listing.name ~= "")
            and T(_("[···] Loading %1… (Tap to stop)"), st.listing.name)
            or _("[···] Searching… (Tap to stop)")
        table.insert(item_table, {
            text = loading_text,
            bold = true,
            is_stop_loading = true,
        })
    end

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

    if st and st.page > 1 then
        table.insert(item_table, {
            text = T(_("[···] Loading Page %1… (Tap to stop)"), st.page),
            bold = true,
            is_stop_loading = true,
        })
    elseif not st and self.has_next_page then
        table.insert(item_table, {
            text = T(_("» Load next page (Page %1)…"), (self.search_page or 1) + 1),
            bold = true,
            is_next_page_entry = true,
        })
    elseif not st and #self.raw_entries == 0 and (self.query ~= nil or self.active_listing ~= nil) then
        table.insert(item_table, {
            text = _("No results."),
            dim = true,
            is_placeholder = true,
        })
    end

    local subtitle = self:buildSubtitle()
    if not preserve_page then
        self.page = 1
    end
    self:switchItemTable(nil, item_table, preserve_page and -1 or nil, nil, subtitle)
end

function SearchBrowser:stopLoading(silent)
    local st = self.loading_state
    if not self.active_handle or not st then
        return
    end
    local was_page = st.page or 1
    local prev_has_next = st.prev_has_next
    self:cancelActiveSearch()
    if was_page > 1 then
        self.has_next_page = prev_has_next and true or false
        self.search_page = math.max(1, was_page - 1)
    end
    self:rebuildList(was_page > 1)
    if not silent and not self.closed then
        UIManager:show(Notification:new{
            text = _("Search stopped."),
            timeout = 2,
        })
    end
end

function SearchBrowser:schedulePoll()
    if self.poll_cb or not self.active_handle or self.closed then
        return
    end
    self.poll_cb = function()
        self.poll_cb = nil
        self:onPollTick()
    end
    UIManager:scheduleIn(POLL_INTERVAL, self.poll_cb)
end

function SearchBrowser:onPollTick()
    if self.closed then
        return
    end
    local handle = self.active_handle
    local st = self.loading_state
    if not handle or not st then
        self:updateStandbyGuard()
        return
    end

    local proc_state, out, proc_err = handle:poll()
    if proc_state == "running" then
        self:schedulePoll()
        return
    end

    self.active_handle = nil
    self.loading_state = nil
    self:updateStandbyGuard()

    local decoded, err_msg
    if proc_state == "done" and type(out) == "string" and out ~= "" then
        local ok_dec, val = pcall(json.decode, out)
        if ok_dec and type(val) == "table" then
            decoded = val
        else
            err_msg = _("Invalid response from aidoku-run")
        end
    else
        err_msg = type(proc_err) == "string" and proc_err ~= "" and proc_err or _("command failed")
    end

    if not decoded then
        if st.page > 1 then
            self.has_next_page = st.prev_has_next and true or false
            self.search_page = math.max(1, st.page - 1)
        end
        self:rebuildList(st.page > 1)
        if not self.closed then
            UIManager:show(InfoMessage:new{
                text = T(st.is_listing and _("Could not load listing:\n%1") or _("Search failed:\n%1"), tostring(err_msg)),
                timeout = 3,
            })
        end
        return
    end

    local entries = type(decoded.Entries) == "table" and decoded.Entries or {}
    for _idx, m in ipairs(entries) do
        if type(m) == "table" and type(m.Key) == "string" and m.Key ~= "" and not self.seen_keys[m.Key] then
            self.seen_keys[m.Key] = true
            table.insert(self.raw_entries, m)
        end
    end
    self.has_next_page = (decoded.HasNextPage == true)
    self:rebuildList(st.page > 1)
end

function SearchBrowser:startAsyncLoad(opts)
    local page_num = opts.page or 1
    self:cancelActiveSearch()

    local prev_has_next = self.has_next_page
    if page_num == 1 then
        self.raw_entries = {}
        self.seen_keys = {}
        self.has_next_page = false
        self.page = 1
    else
        self.has_next_page = false
    end

    NetworkMgr:runWhenConnected(function()
        if self.closed then
            return
        end
        local handle, spawn_err
        if opts.is_listing then
            handle, spawn_err = self.engine:spawnListingGet(
                self.source_path, opts.listing.id, page_num, opts.listing.name
            )
        else
            handle, spawn_err = self.engine:spawnSearch(
                self.source_path, opts.query, page_num, opts.filters
            )
        end
        if not handle then
            if page_num > 1 then
                self.has_next_page = prev_has_next and true or false
            end
            self:rebuildList(page_num > 1)
            UIManager:show(InfoMessage:new{
                text = T(opts.is_listing and _("Could not load listing:\n%1") or _("Search failed:\n%1"),
                    tostring(spawn_err or _("command failed"))),
                timeout = 3,
            })
            return
        end

        self.active_handle = handle
        self.loading_state = {
            page = page_num,
            is_listing = opts.is_listing and true or false,
            listing = opts.listing,
            prev_has_next = prev_has_next,
        }
        self:updateStandbyGuard()
        self:rebuildList(page_num > 1)
        self:schedulePoll()
    end)
end

function SearchBrowser:runListing(listing, page_num)
    self.active_listing = listing
    self.query = nil
    self.search_page = page_num or 1
    self:startAsyncLoad({
        page = self.search_page,
        is_listing = true,
        listing = listing,
    })
end

function SearchBrowser:runSearch(query, page_num)
    self.query = query or ""
    self.active_listing = nil
    self.search_page = page_num or 1
    local filters = {}
    for _idx, v in pairs(self.filter_values) do
        table.insert(filters, v)
    end
    self:startAsyncLoad({
        page = self.search_page,
        is_listing = false,
        query = self.query,
        filters = filters,
    })
end

function SearchBrowser:onMenuSelect(item)
    if item.is_stop_loading then
        self:stopLoading(false)
        return true
    elseif item.is_placeholder then
        return true
    elseif item.is_filters_entry then
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
    if not item.manga then
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
            self:rebuildList(true)
            if self.refresh_callback then
                self.refresh_callback()
            end
        end,
    })
    return true
end

function SearchBrowser:onMenuHold(item)
    if item.is_filters_entry or item.is_next_page_entry or item.is_stop_loading
        or item.is_placeholder or not item.manga then
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
    self:rebuildList(true)
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