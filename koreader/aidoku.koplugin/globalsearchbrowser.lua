--[[--
GlobalSearchBrowser (Multi-source Search Plus / 多书源搜索 Plus):
1. Source Selection step first: lets the user pick which installed sources to
   include in the upcoming search (with Select All / Deselect All / Invert
   and persistent selection across sessions).
2. Non-blocking Parallel Streaming Search: queries selected sources via a
   hardware-bounded worker pool in aidoku-run, streaming each source's results
   into the live list as soon as it responds, displaying real-time progress and
   active sources, allowing 1-tap interruption while keeping found results (with
   Continue / Retry failed recovery), and supporting dynamic Page 2+ loading.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DownloadQueue = require("downloadqueue")
local DownloadsEngine = require("downloadsengine")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local InstalledSources = require("installedsources")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local OpenWidgets = require("openwidgets")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local POLL_INTERVAL = 0.35
local VIS_WATCH_INTERVAL = 0.45

local GlobalSearchBrowser = Menu:extend{
    name = "tsundoku_search",
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

local function shortenUTF8(s, max_chars)
    s = tostring(s or ""):gsub("[\r\n\t]+", " ")
    local count, pos, len = 0, 1, #s
    while pos <= len do
        count = count + 1
        if count > max_chars then
            return s:sub(1, pos - 1) .. "…"
        end
        local b = s:byte(pos)
        if b < 0x80 then
            pos = pos + 1
        elseif b < 0xE0 then
            pos = pos + 2
        elseif b < 0xF0 then
            pos = pos + 3
        else
            pos = pos + 4
        end
    end
    return s
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

function GlobalSearchBrowser:init()
    self.title = _("Multi-source Search")
    self.mode = "select_sources" -- "select_sources" | "results"
    self.sources = {}
    self.selected_map = {} -- source_key -> boolean
    self.last_query = ""
    self.results_items = {}
    self.seen_result_keys = {}
    self.failed_sources = {}
    self.remaining_sources = {}
    self.next_page_sources = {}
    self.search_page = 1
    self.last_searched_total = 0
    self.search_state = nil
    self.active_handle = nil
    self.poll_scheduled = false
    self.poll_cb = nil
    self.vis_watch_scheduled = false
    self.vis_watch_cb = nil
    self.pending_ui_sync = false
    self.standby_prevented = false
    self.item_table = {}
    Menu.init(self)
    OpenWidgets.push(self)

    UIManager:nextTick(function()
        if not self.closed then
            self:loadSourcesAndShowSelector()
        end
    end)
end

function GlobalSearchBrowser:updateStandbyGuard()
    local should_hold = (self.active_handle ~= nil)
    if should_hold and not self.standby_prevented then
        self.standby_prevented = true
        UIManager:preventStandby()
    elseif not should_hold and self.standby_prevented then
        self.standby_prevented = false
        UIManager:allowStandby()
    end
end

function GlobalSearchBrowser:unschedulePoll()
    if self.poll_cb then
        UIManager:unschedule(self.poll_cb)
        self.poll_cb = nil
    end
    self.poll_scheduled = false
end

function GlobalSearchBrowser:unscheduleTimers()
    self:unschedulePoll()
    if self.vis_watch_cb then
        UIManager:unschedule(self.vis_watch_cb)
        self.vis_watch_cb = nil
    end
    self.vis_watch_scheduled = false
end

function GlobalSearchBrowser:cancelActiveSearch(silent)
    self:unschedulePoll()
    if self.active_handle then
        if silent then
            self.active_handle:cancel()
            self:consumeStreamEvents(self.active_handle:drainStreamEvents())
            self.active_handle = nil
            if self.search_state then
                self.search_state.running = false
                self.search_state.active_by_idx = {}
            end
            self:updateStandbyGuard()
        else
            self:stopSearch(false)
        end
    else
        self:updateStandbyGuard()
    end
end

function GlobalSearchBrowser:onCloseWidget()
    self.closed = true
    self:unscheduleTimers()
    self:cancelActiveSearch(true)
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
                    self.selected_map[src.key] = false
                else
                    self.selected_map[src.key] = saved[src.key] and true or false
                end
            end
        end
        if self.closed then
            return
        end
        self:showSourceSelector()
        if self.prompt_immediately and self:selectedCount() > 0 then
            self.prompt_immediately = false
            UIManager:nextTick(function()
                if not self.closed then
                    self:promptQuery()
                end
            end)
        end
    end)
end

function GlobalSearchBrowser:showSourceSelector()
    if self.active_handle then
        self:stopSearch(true)
    end
    local was_selector = (self.mode == "select_sources")
    self.mode = "select_sources"
    local sel_count, valid_total = self:selectedCount()

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

    local saved_page = was_selector and self.page or 1
    if not was_selector then
        self.page = 1
    end
    self:switchItemTable(
        _("Select Search Sources"),
        items,
        was_selector and -1 or nil,
        nil,
        T(_("Tap sources to toggle (%1/%2 selected), then tap Start Search"), sel_count, valid_total)
    )
    if was_selector and saved_page and saved_page >= 1 and saved_page <= (self.page_num or 1) and self.page ~= saved_page then
        self.page = saved_page
        self:updateItems(1, true)
    end
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

function GlobalSearchBrowser:formatActiveSummary(st)
    if not st or not st.active_by_idx then
        return ""
    end
    local indices = {}
    for idx, name in pairs(st.active_by_idx) do
        if type(name) == "string" and name ~= "" then
            table.insert(indices, idx)
        end
    end
    if #indices == 0 then
        return ""
    end
    table.sort(indices)
    local shown = {}
    for i = 1, math.min(2, #indices) do
        table.insert(shown, st.active_by_idx[indices[i]])
    end
    local text = table.concat(shown, ", ")
    if #indices > 2 then
        text = text .. " +" .. tostring(#indices - 2)
    end
    return text
end

function GlobalSearchBrowser:buildResultsSubtitle()
    local st = self.search_state
    local count = #self.results_items
    if st and st.running then
        local active_summary = self:formatActiveSummary(st)
        if st.mode_kind == "load_more" then
            if active_summary ~= "" then
                return T(_("Loading Page %1 (%2/%3) · %4 results · Active: %5"),
                    st.page, st.done, st.total, count, active_summary)
            end
            return T(_("Loading Page %1 (%2/%3) · %4 results…"),
                st.page, st.done, st.total, count)
        end
        if active_summary ~= "" then
            return T(_("Searching %1/%2 · %3 results · Active: %4"),
                st.done, st.total, count, active_summary)
        end
        return T(_("Searching %1/%2 · %3 results…"), st.done, st.total, count)
    end

    local sub
    if st and st.stopped_early then
        sub = T(_("Stopped (%1/%2 sources) · %3 results · Hold to bookmark"),
            st.done, st.total, count)
    else
        sub = T(_("%1 results from %2 selected sources · Hold to bookmark"),
            count, self.last_searched_total)
    end
    if #self.failed_sources > 0 then
        sub = sub .. T(_(" (%1 failed)"), #self.failed_sources)
    end
    return sub
end

function GlobalSearchBrowser:buildResultsItems()
    local st = self.search_state
    local running = st and st.running
    local dl_stats = self.downloads_engine:mangaDownloadStats()
    local meta_map = self.store:getMangaMetaMap()
    local items = {}

    if running then
        local bar = DownloadQueue.progressBar(st.done, st.total, 8)
        table.insert(items, {
            text = T(_("%1 Searching %2/%3 · Tap to stop"), bar, st.done, st.total),
            mandatory = T(_("%1 results"), #self.results_items),
            bold = true,
            is_stop_search = true,
        })
    else
        table.insert(items, {
            text = T(_("» Change sources (%1/%2) or search again…"), self:selectedCount()),
            mandatory = self.last_query ~= "" and T(_("Query: %1"), self.last_query) or "",
            bold = true,
            is_search_header = true,
        })
        if #self.remaining_sources > 0 then
            table.insert(items, {
                text = T(_("▶ Continue searching remaining %1 source(s)…"), #self.remaining_sources),
                mandatory = _("Resume >"),
                bold = true,
                is_continue_search = true,
            })
        end
        if #self.failed_sources > 0 then
            table.insert(items, {
                text = T(_("✗ %1 source(s) failed · Tap to retry or disable"), #self.failed_sources),
                mandatory = _("Details >"),
                is_failed_sources = true,
            })
        end
    end

    for _idx, r in ipairs(self.results_items) do
        table.insert(items, self:formatResultRow(r, dl_stats, meta_map))
    end

    if #self.results_items == 0 then
        local empty_text
        if running then
            empty_text = _("Waiting for first source results… (Results appear here live)")
        elseif st and st.stopped_early then
            empty_text = _("Search stopped before any results arrived.")
        else
            empty_text = _("No results in the selected sources.")
        end
        table.insert(items, {
            text = empty_text,
            dim = true,
            is_placeholder = true,
        })
    elseif not running and #self.next_page_sources > 0 then
        table.insert(items, {
            text = T(_("» Load more results (Page %1 · %2 sources)…"),
                (self.search_page or 1) + 1, #self.next_page_sources),
            bold = true,
            is_load_more = true,
        })
    end

    return items
end

function GlobalSearchBrowser:scheduleVisibilityWatch()
    if self.vis_watch_scheduled or self.closed then
        return
    end
    self.vis_watch_scheduled = true
    self.vis_watch_cb = function()
        self.vis_watch_scheduled = false
        self.vis_watch_cb = nil
        if self.closed or not self.pending_ui_sync then
            return
        end
        if self.mode ~= "results" then
            self.pending_ui_sync = false
            return
        end
        if isCoveredByModalOrScreen(self) then
            self:scheduleVisibilityWatch()
            return
        end
        self.pending_ui_sync = false
        self:renderResultsView(true)
    end
    UIManager:scheduleIn(VIS_WATCH_INTERVAL, self.vis_watch_cb)
end

function GlobalSearchBrowser:renderResultsView(preserve_page)
    self.mode = "results"
    if isCoveredByModalOrScreen(self) then
        self.pending_ui_sync = true
        self:scheduleVisibilityWatch()
        return
    end
    self.pending_ui_sync = false
    local title = self.last_query ~= "" and T(_("Search: %1"), self.last_query) or _("Multi-source Search")
    local subtitle = self:buildResultsSubtitle()
    local items = self:buildResultsItems()
    if not preserve_page then
        self.page = 1
    end
    self:switchItemTable(title, items, preserve_page and -1 or nil, nil, subtitle)
end

function GlobalSearchBrowser:refreshResultsMarkers()
    if self.mode ~= "results" then
        return
    end
    self:renderResultsView(true)
end

function GlobalSearchBrowser:showResultsView(_searched_count, _failed_names)
    self:renderResultsView(false)
end

function GlobalSearchBrowser:consumeStreamEvents(events)
    if type(events) ~= "table" or #events == 0 or not self.search_state then
        return false
    end
    local st = self.search_state
    local changed = false
    for _idx, ev in ipairs(events) do
        if type(ev) == "table" then
            local ev_type = type(ev.type) == "string" and ev.type or ""
            local idx = type(ev.index) == "number" and math.floor(ev.index) or 0
            local src = idx > 0 and st.sources[idx] or nil
            local skey = type(ev.sourceKey) == "string" and ev.sourceKey ~= ""
                and ev.sourceKey or (src and src.key or "")
            local sname = type(ev.sourceName) == "string" and ev.sourceName ~= ""
                and ev.sourceName or (src and (src.name or src.text) or skey)
            local spath = type(ev.sourcePath) == "string" and ev.sourcePath ~= ""
                and ev.sourcePath or (src and src.path or "")

            if ev_type == "start" then
                if idx > 0 and not st.completed_by_idx[idx] then
                    st.active_by_idx[idx] = sname
                    changed = true
                end
            elseif ev_type == "result" then
                if idx > 0 then
                    st.active_by_idx[idx] = nil
                    if not st.completed_by_idx[idx] then
                        st.completed_by_idx[idx] = true
                        st.done = st.done + 1
                    end
                else
                    st.done = st.done + 1
                end

                local err_str = type(ev.error) == "string" and ev.error or ""
                if err_str ~= "" then
                    table.insert(self.failed_sources, {
                        key = skey,
                        name = sname,
                        path = spath,
                        error = err_str,
                    })
                else
                    local entries = type(ev.entries) == "table" and ev.entries or {}
                    for _eidx, manga in ipairs(entries) do
                        if type(manga) == "table" and type(manga.Key) == "string" and manga.Key ~= "" then
                            local dedup_key = tostring(skey) .. "\0" .. manga.Key
                            if not self.seen_result_keys[dedup_key] then
                                self.seen_result_keys[dedup_key] = true
                                table.insert(self.results_items, {
                                    manga = manga,
                                    source_path = spath,
                                    source_key = skey,
                                    source_name = sname,
                                })
                            end
                        end
                    end
                    if ev.hasNext == true and spath ~= "" then
                        table.insert(self.next_page_sources, {
                            key = skey,
                            name = sname,
                            path = spath,
                        })
                    end
                end
                changed = true
            end
        end
    end
    return changed
end

function GlobalSearchBrowser:schedulePoll()
    if self.poll_scheduled or not self.active_handle or self.closed then
        return
    end
    self.poll_scheduled = true
    self.poll_cb = function()
        self.poll_scheduled = false
        self.poll_cb = nil
        self:onPollTick()
    end
    UIManager:scheduleIn(POLL_INTERVAL, self.poll_cb)
end

function GlobalSearchBrowser:onPollTick()
    if self.closed then
        return
    end
    local handle = self.active_handle
    local st = self.search_state
    if not handle or not st then
        self:updateStandbyGuard()
        return
    end

    local proc_state, _out, proc_err = handle:poll()
    local changed = self:consumeStreamEvents(handle:drainStreamEvents())

    if proc_state == "running" then
        if changed and self.mode == "results" then
            self:renderResultsView(true)
        end
        self:schedulePoll()
        return
    end

    self.active_handle = nil
    st.running = false
    st.active_by_idx = {}
    self:updateStandbyGuard()

    if proc_state == "error" and st.done == 0 then
        local err_msg = type(proc_err) == "string" and proc_err ~= "" and proc_err or _("command failed")
        for idx, src in ipairs(st.sources) do
            if not st.completed_by_idx[idx] then
                table.insert(self.failed_sources, {
                    key = src.key or "",
                    name = src.name or src.text or "",
                    path = src.path or "",
                    error = err_msg,
                })
            end
        end
    end

    if self.mode == "results" then
        self:renderResultsView(true)
    end
end

function GlobalSearchBrowser:stopSearch(silent)
    self:unschedulePoll()
    local handle = self.active_handle
    local st = self.search_state
    if not handle or not st then
        return
    end

    handle:cancel()
    self:consumeStreamEvents(handle:drainStreamEvents())
    self.active_handle = nil
    st.running = false
    st.stopped_early = true
    st.active_by_idx = {}
    self:updateStandbyGuard()

    local remaining = {}
    for idx, src in ipairs(st.sources) do
        if not st.completed_by_idx[idx] then
            table.insert(remaining, src)
        end
    end
    self.remaining_sources = remaining

    if self.mode == "results" then
        self:renderResultsView(true)
    end

    if not silent and not self.closed then
        UIManager:show(Notification:new{
            text = T(_("Search stopped (%1/%2 sources, %3 results kept)"),
                st.done, st.total, #self.results_items),
            timeout = 2.5,
        })
    end
end

function GlobalSearchBrowser:startBatchStream(sources_list, page_num, mode_kind)
    if type(sources_list) ~= "table" or #sources_list == 0 then
        return
    end
    self:cancelActiveSearch(true)

    if mode_kind == "fresh" then
        self.search_page = 1
        self.results_items = {}
        self.seen_result_keys = {}
        self.failed_sources = {}
        self.remaining_sources = {}
        self.next_page_sources = {}
        self.last_searched_total = #sources_list
        self.page = 1
    elseif mode_kind == "load_more" then
        self.search_page = page_num
        self.next_page_sources = {}
    elseif mode_kind == "retry_failed" then
        self.failed_sources = {}
    elseif mode_kind == "continue" then
        self.remaining_sources = {}
    end

    NetworkMgr:runWhenConnected(function()
        if self.closed then
            return
        end
        local workers = self.store and self.store.searchConcurrency and self.store:searchConcurrency() or 0
        local handle, err = self.engine:spawnSearchBatch(sources_list, self.last_query, page_num, {
            workers = workers,
        })
        if not handle then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not start search:\n%1"), tostring(err or _("command failed"))),
                timeout = 3,
            })
            return
        end

        self.active_handle = handle
        self.search_state = {
            running = true,
            mode_kind = mode_kind,
            page = page_num,
            done = 0,
            total = #sources_list,
            sources = sources_list,
            active_by_idx = {},
            completed_by_idx = {},
            stopped_early = false,
        }
        self:updateStandbyGuard()
        self:renderResultsView(mode_kind ~= "fresh")
        self:schedulePoll()
    end)
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
    self:startBatchStream(target_sources, 1, "fresh")
end

function GlobalSearchBrowser:showFailedSourcesDialog()
    if #self.failed_sources == 0 then
        return
    end
    local lines = {}
    local max_show = math.min(8, #self.failed_sources)
    for i = 1, max_show do
        local f = self.failed_sources[i]
        local name = shortenUTF8(f.name ~= "" and f.name or f.key, 20)
        local err = shortenUTF8(f.error or _("failed"), 42)
        table.insert(lines, "• " .. name .. ": " .. err)
    end
    if #self.failed_sources > max_show then
        table.insert(lines, T(_("…and %1 more"), #self.failed_sources - max_show))
    end

    local retry_list = {}
    local seen_retry = {}
    for _idx, f in ipairs(self.failed_sources) do
        if type(f.path) == "string" and f.path ~= "" then
            local rk = f.key ~= "" and f.key or f.path
            if not seen_retry[rk] then
                seen_retry[rk] = true
                table.insert(retry_list, {
                    key = f.key,
                    name = f.name,
                    path = f.path,
                })
            end
        end
    end

    local dialog
    local buttons = {}
    if #retry_list > 0 then
        table.insert(buttons, {{
            text = T(_("Retry failed sources (%1)"), #retry_list),
            callback = function()
                UIManager:close(dialog)
                self:startBatchStream(retry_list, self.search_page or 1, "retry_failed")
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Deselect failed sources"),
        callback = function()
            UIManager:close(dialog)
            local disabled = 0
            for _idx, f in ipairs(self.failed_sources) do
                if f.key and f.key ~= "" and self.selected_map[f.key] then
                    self.selected_map[f.key] = false
                    disabled = disabled + 1
                end
            end
            self:persistSelection()
            self.failed_sources = {}
            self:renderResultsView(true)
            if disabled > 0 then
                UIManager:show(Notification:new{
                    text = T(_("Disabled %1 failed source(s) for future searches."), disabled),
                    timeout = 2.5,
                })
            end
        end,
    }})
    table.insert(buttons, {{
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }})

    dialog = ButtonDialog:new{
        title = T(_("Failed Sources (%1)"), #self.failed_sources) .. "\n\n" .. table.concat(lines, "\n"),
        use_info_style = true,
        buttons = buttons,
    }
    UIManager:show(dialog)
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
    local buttons = {}

    if self.active_handle and self.search_state and self.search_state.running then
        table.insert(buttons, {{
            text = T(_("■ Stop current search (%1/%2)"), self.search_state.done, self.search_state.total),
            callback = function()
                UIManager:close(dialog)
                self:stopSearch(false)
            end,
        }})
    end

    table.insert(buttons, {{
        text = T(_("Search keyword (%1/%2 sources)…"), sel_count, valid_total),
        callback = function()
            UIManager:close(dialog)
            self:promptQuery()
        end,
    }})

    if self.mode == "results" then
        table.insert(buttons, {{
            text = T(_("Select search sources (%1/%2)…"), sel_count, valid_total),
            callback = function()
                UIManager:close(dialog)
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
        if #self.results_items > 0 or #self.remaining_sources > 0 or #self.failed_sources > 0 then
            table.insert(buttons, {{
                text = T(_("Back to last results (%1)"), #self.results_items),
                callback = function()
                    UIManager:close(dialog)
                    self:renderResultsView(false)
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
        anchor = function() return leftButtonAnchor(self) end,
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
    if item.is_stop_search then
        self:stopSearch(false)
        return true
    elseif item.is_continue_search then
        if #self.remaining_sources > 0 then
            self:startBatchStream(self.remaining_sources, self.search_page or 1, "continue")
        end
        return true
    elseif item.is_failed_sources then
        self:showFailedSourcesDialog()
        return true
    elseif item.is_load_more then
        if #self.next_page_sources > 0 then
            local next_page = (self.search_page or 1) + 1
            self:startBatchStream(self.next_page_sources, next_page, "load_more")
        end
        return true
    elseif item.is_search_header then
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
                        self:showSourceSelector()
                    end,
                }},
            },
        }
        UIManager:show(dialog)
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

    if item.is_search_header or item.is_stop_search or item.is_continue_search
        or item.is_failed_sources or item.is_load_more or not item.manga then
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