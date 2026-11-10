--[[--
DownloadsBrowser (Download Manager):
- Displays live download queue progress (page-by-page progress bar, percentage,
  queued tasks, pause/resume, cancel, prioritize, retry) in real time.
- Displays locally downloaded manga & chapters (grouped by manga or flat chapter
  list, with storage size, tap to open/read, hold to manage/delete).
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DownloadQueue = require("downloadqueue")
local InfoMessage = require("ui/widget/infomessage")
local InstalledSources = require("installedsources")
local Menu = require("ui/widget/menu")
local OpenWidgets = require("openwidgets")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local MB = 1024 * 1024

local function formatSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= MB then
        return string.format("%.1f MB", bytes / MB)
    elseif bytes >= 1024 then
        return string.format("%d KB", math.floor(bytes / 1024 + 0.5))
    end
    return string.format("%d B", bytes)
end

-- shortenUTF8 caps a long manga title at max_chars UTF-8 codepoints before
-- appending " · <chapterTitle>", so KOReader's Menu row truncation never cuts
-- off the chapter number on the right when a light-novel-style title is 30+ chars.
local function shortenUTF8(s, max_chars)
    s = tostring(s or "")
    local count = 0
    local pos = 1
    local len = #s
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

local function formatChapterRowTitle(manga_title, chapter_title, max_manga_chars)
    return shortenUTF8(manga_title, max_manga_chars or 13) .. " · " .. tostring(chapter_title or "")
end

local DownloadsBrowser = Menu:extend{
    title_bar_left_icon = "appbar.menu",
}

function DownloadsBrowser:init()
    self.title = _("Download Manager")
    self.view_mode = self.view_mode or "all" -- "all" | "by_manga" | "queue_only"
    self.cached_entries = {}
    self.item_table = {}
    self.refresh_pending = false
    Menu.init(self)
    OpenWidgets.push(self)

    self.listener_key = tostring(self)
    DownloadQueue:subscribe(self.listener_key, function(event_kind)
        if self.closed then
            return
        end
        -- Reload SQLite index when a download finishes so newly completed CBZs
        -- appear in the downloaded section with exact file size immediately.
        if event_kind == "completed" then
            self:scheduleRefresh(true)
        else
            self:scheduleRefresh(false)
        end
    end)

    UIManager:nextTick(function() self:reload() end)
end

function DownloadsBrowser:onCloseWidget()
    self.closed = true
    if self.listener_key then
        DownloadQueue:unsubscribe(self.listener_key)
    end
    Menu.onCloseWidget(self)
    OpenWidgets.remove(self)
end

-- Throttle UI refreshes slightly so rapid page downloads on E-Ink repaint
-- smoothly using partial UI refresh without flickering.
function DownloadsBrowser:scheduleRefresh(reload_db)
    if reload_db then
        self.needs_db_reload = true
    end
    if self.refresh_pending then
        return
    end
    self.refresh_pending = true
    UIManager:scheduleIn(0.35, function()
        self.refresh_pending = false
        if self.closed then
            return
        end
        if self.needs_db_reload then
            self.needs_db_reload = false
            local entries = self.downloads_engine:list()
            if entries then
                self.cached_entries = entries
            end
        end
        self:rebuildUI()
    end)
end

function DownloadsBrowser:buildSubtitle(qstats, mstats)
    local total_dl_chapters = 0
    local total_dl_bytes = 0
    for _idx, g in ipairs(mstats.groups) do
        total_dl_chapters = total_dl_chapters + g.count
        total_dl_bytes = total_dl_bytes + g.sizeBytes
    end

    if qstats.active then
        local t = qstats.active
        local page_str
        if t.total_pages and t.total_pages > 0 then
            local pct = math.floor((t.current_page * 100) / t.total_pages)
            page_str = T(_("%1/%2p (%3%)"), t.current_page, t.total_pages, pct)
        else
            page_str = _("Preparing…")
        end
        return T(_("Active: %1 · Queue: %2 · Saved: %3 ch (%4)"),
            page_str, qstats.pending, total_dl_chapters, formatSize(total_dl_bytes))
    elseif qstats.paused and qstats.queued > 0 then
        return T(_("Paused (%1 queued) · Saved: %2 ch (%3)"),
            qstats.queued, total_dl_chapters, formatSize(total_dl_bytes))
    elseif qstats.failed > 0 then
        return T(_("%1 failed · Saved: %2 manga / %3 ch (%4)"),
            qstats.failed, #mstats.groups, total_dl_chapters, formatSize(total_dl_bytes))
    end
    return T(_("Idle · Saved: %1 manga / %2 ch (%3)"),
        #mstats.groups, total_dl_chapters, formatSize(total_dl_bytes))
end

local function formatTaskMandatory(task, queue_pos)
    if task.status == "downloading" then
        if task.total_pages and task.total_pages > 0 then
            local pct = math.floor((task.current_page * 100) / task.total_pages)
            local bar = DownloadQueue.progressBar(task.current_page, task.total_pages, 6)
            return string.format("%s %d/%d (%d%%)", bar, task.current_page, task.total_pages, pct)
        end
        return _("Preparing…")
    elseif task.status == "queued" then
        if DownloadQueue.paused then
            return T(_("Paused #%1"), queue_pos)
        end
        return T(_("Queued #%1"), queue_pos)
    elseif task.status == "failed" then
        return _("Failed")
    elseif task.status == "cancelled" then
        return _("Cancelled")
    elseif task.status == "completed" then
        return _("Done ✓")
    end
    return task.status
end

local function taskPrefix(task)
    if task.status == "downloading" then
        return "▶ "
    elseif task.status == "queued" then
        return "[…] "
    elseif task.status == "failed" then
        return "✗ "
    elseif task.status == "cancelled" then
        return "– "
    elseif task.status == "completed" then
        return "✓ "
    end
    return ""
end

function DownloadsBrowser:genItemTable()
    local item_table = {}
    local qstats = DownloadQueue:getStats()
    local mstats = self.downloads_engine:mangaDownloadStats(self.cached_entries)

    if self.title_bar then
        self.title_bar:setSubTitle(self:buildSubtitle(qstats, mstats), true)
    else
        self.subtitle = self:buildSubtitle(qstats, mstats)
    end

    -- 1. Active / Queued / Recent Queue Tasks section
    if self.view_mode ~= "by_manga" or qstats.pending > 0 or qstats.failed > 0 then
        local shown_tasks = {}
        for _idx, t in ipairs(DownloadQueue.tasks) do
            -- In "all" or "by_manga" mode, show active/queued/failed tasks cleanly
            -- (completed ones already appear in Downloaded section below unless in queue_only mode)
            if self.view_mode == "queue_only" or t.status ~= "completed" then
                table.insert(shown_tasks, t)
            end
        end

        if #shown_tasks > 0 then
            local header_right = qstats.paused and _("Paused")
                or (qstats.pending > 0 and T(_("%1 remaining"), qstats.pending) or "")
            table.insert(item_table, {
                text = T(_("── Download Queue (%1) ──"), #shown_tasks),
                mandatory = header_right,
                bold = true,
                dim = true,
                is_placeholder = true,
            })
            local qpos = 0
            for _idx, t in ipairs(shown_tasks) do
                if t.status == "queued" then
                    qpos = qpos + 1
                end
                table.insert(item_table, {
                    text = taskPrefix(t) .. formatChapterRowTitle(t.manga_title, t.chapter_title, 12),
                    mandatory = formatTaskMandatory(t, qpos),
                    queue_task = t,
                    bold = (t.status == "downloading"),
                })
            end
        elseif self.view_mode == "queue_only" then
            table.insert(item_table, {
                text = _("No active download tasks in queue."),
                dim = true,
                is_placeholder = true,
            })
        end
    end

    -- 2. Downloaded Manga / Chapters section
    if self.view_mode == "by_manga" then
        if #mstats.groups > 0 then
            table.insert(item_table, {
                text = T(_("── Downloaded Books (%1) ──"), #mstats.groups),
                bold = true,
                dim = true,
                is_placeholder = true,
            })
            local meta_map = self.store and self.store:getMangaMetaMap() or {}
            for _idx, g in ipairs(mstats.groups) do
                local meta = meta_map[g.sourceKey .. "\0" .. g.mangaKey]
                local total_ch = meta and meta.chapter_count or 0
                local count_str
                if total_ch > 0 and g.count >= total_ch then
                    count_str = T(_("All %1 ch · %2"), g.count, formatSize(g.sizeBytes))
                elseif total_ch > 0 then
                    count_str = T(_("%1/%2 ch · %3"), g.count, total_ch, formatSize(g.sizeBytes))
                else
                    count_str = T(_("%1 ch · %2"), g.count, formatSize(g.sizeBytes))
                end
                table.insert(item_table, {
                    text = "✓ " .. g.mangaTitle,
                    mandatory = count_str,
                    manga_group = g,
                })
            end
        elseif #item_table == 0 then
            table.insert(item_table, {
                text = _("No downloaded chapters yet."),
                dim = true,
                is_placeholder = true,
            })
        end
    elseif self.view_mode == "all" then
        local valid_entries = {}
        for _idx, entry in ipairs(self.cached_entries) do
            if entry.path ~= "" and lfs.attributes(entry.path, "mode") == "file" then
                table.insert(valid_entries, entry)
            end
        end
        if #valid_entries > 0 then
            table.insert(item_table, {
                text = T(_("── Downloaded Chapters (%1) ──"), #valid_entries),
                bold = true,
                dim = true,
                is_placeholder = true,
            })
            for _idx, entry in ipairs(valid_entries) do
                local is_read = self.store and self.store:isChapterRead(entry.sourceKey, entry.mangaKey, entry.chapterKey)
                local right = formatSize(entry.sizeBytes)
                if is_read then
                    right = _("Read") .. " · " .. right
                end
                table.insert(item_table, {
                    text = formatChapterRowTitle(entry.mangaTitle, entry.chapterTitle, 15),
                    mandatory = right,
                    download_entry = entry,
                })
            end
        elseif #item_table == 0 then
            table.insert(item_table, {
                text = _("No downloaded chapters yet."),
                dim = true,
                is_placeholder = true,
            })
        end
    end

    return item_table
end

function DownloadsBrowser:rebuildUI()
    local saved_page = self.page
    self.item_table = self:genItemTable()
    self:updateItems(saved_page)
end

function DownloadsBrowser:loadAndRefresh()
    local entries, err = self.downloads_engine:list()
    if not entries then
        UIManager:show(InfoMessage:new{ text = T(_("Could not load downloads:\n%1"), err) })
        return
    end
    self.cached_entries = entries
    self:rebuildUI()
end

function DownloadsBrowser:reload()
    Trapper:wrap(function() self:loadAndRefresh() end)
end

function DownloadsBrowser:onLeftButtonTap()
    local qstats = DownloadQueue:getStats()
    local view_labels = {
        all = _("View: Queue + Chapters"),
        by_manga = _("View: Grouped by Book"),
        queue_only = _("View: Queue Only"),
    }
    local next_view = {
        all = "by_manga",
        by_manga = "queue_only",
        queue_only = "all",
    }

    local dialog
    local buttons = {
        {{
            text = view_labels[self.view_mode] or view_labels.all,
            callback = function()
                UIManager:close(dialog)
                self.view_mode = next_view[self.view_mode] or "all"
                self:rebuildUI()
            end,
        }},
    }

    if qstats.pending > 0 or qstats.paused then
        table.insert(buttons, {{
            text = qstats.paused and _("Resume download queue") or _("Pause download queue"),
            callback = function()
                UIManager:close(dialog)
                if qstats.paused then
                    DownloadQueue:resume()
                else
                    DownloadQueue:pause()
                end
                self:rebuildUI()
            end,
        }})
    end

    if qstats.failed > 0 or qstats.cancelled > 0 then
        table.insert(buttons, {{
            text = T(_("Retry failed/cancelled (%1)"), qstats.failed + qstats.cancelled),
            callback = function()
                UIManager:close(dialog)
                DownloadQueue:retryFailed()
                self:rebuildUI()
            end,
        }})
    end

    if qstats.pending > 0 then
        table.insert(buttons, {{
            text = T(_("Cancel all pending (%1)"), qstats.pending),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Cancel %1 active/queued download(s)?"), qstats.pending),
                    ok_text = _("Cancel downloads"),
                    ok_callback = function()
                        DownloadQueue:cancelAll()
                        self:rebuildUI()
                    end,
                })
            end,
        }})
    end

    if (qstats.completed + qstats.failed + qstats.cancelled) > 0 then
        table.insert(buttons, {{
            text = _("Clear finished queue history"),
            callback = function()
                UIManager:close(dialog)
                DownloadQueue:clearFinished()
                self:rebuildUI()
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Refresh status"),
        callback = function()
            UIManager:close(dialog)
            self:reload()
        end,
    }})

    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function() return self.title_bar.left_button.image.dimen end,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function DownloadsBrowser:showTaskActions(task)
    local dialog
    local subtitle = task.error_msg and ("\n" .. tostring(task.error_msg)) or ""
    local buttons = {}

    if task.status == "queued" then
        table.insert(buttons, {{
            text = _("Download next (prioritize)"),
            callback = function()
                UIManager:close(dialog)
                DownloadQueue:prioritize(task.id)
                self:rebuildUI()
            end,
        }})
    end

    if task.status == "downloading" or task.status == "queued" then
        table.insert(buttons, {{
            text = _("Cancel this download"),
            callback = function()
                UIManager:close(dialog)
                DownloadQueue:cancelTask(task.id)
                self:rebuildUI()
            end,
        }})
    end

    if task.status == "failed" or task.status == "cancelled" then
        table.insert(buttons, {{
            text = _("Retry download"),
            callback = function()
                UIManager:close(dialog)
                DownloadQueue:retryTask(task.id)
                self:rebuildUI()
            end,
        }})
    end

    if task.status == "completed" and task.result_path and lfs.attributes(task.result_path, "mode") == "file" then
        table.insert(buttons, {{
            text = _("Open chapter"),
            callback = function()
                UIManager:close(dialog)
                self:openChapterFile(task.source_key, task.manga_key, task.result_path)
            end,
        }})
    end

    if task.status ~= "downloading" then
        table.insert(buttons, {{
            text = _("Remove from queue list"),
            callback = function()
                UIManager:close(dialog)
                DownloadQueue:removeTaskRecord(task.id)
                self:rebuildUI()
            end,
        }})
    end

    dialog = ButtonDialog:new{
        title = task.manga_title .. " - " .. task.chapter_title .. subtitle,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function DownloadsBrowser:openChapterFile(source_key, manga_key, path)
    if lfs.attributes(path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{ text = _("Download no longer available."), timeout = 2 })
        self:reload()
        return
    end
    self.store:markLastRead(source_key, manga_key)
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
    if self.store:isEphemeralMode() then
        self.downloads_engine:removeAllExcept(path)
    end
end

function DownloadsBrowser:openMangaGroupChapters(group)
    local rows = {}
    -- Order chapters by chapter number ascending if possible for clean reading
    local sorted = {}
    for i, e in ipairs(group.chapters) do
        sorted[i] = e
    end
    table.sort(sorted, function(a, b)
        if a.chapterNumber and b.chapterNumber and a.chapterNumber ~= b.chapterNumber then
            return a.chapterNumber < b.chapterNumber
        end
        return (a.downloadedAt or 0) < (b.downloadedAt or 0)
    end)

    for _idx, entry in ipairs(sorted) do
        local is_read = self.store and self.store:isChapterRead(entry.sourceKey, entry.mangaKey, entry.chapterKey)
        local right = formatSize(entry.sizeBytes)
        if is_read then
            right = _("Read") .. " · " .. right
        end
        table.insert(rows, {
            text = entry.chapterTitle,
            mandatory = right,
            download_entry = entry,
        })
    end

    local sub_menu
    sub_menu = Menu:new{
        title = group.mangaTitle,
        subtitle = T(_("%1 downloaded chapters (%2)"), group.count, formatSize(group.sizeBytes)),
        item_table = rows,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        onMenuSelect = function(_m, item)
            local e = item.download_entry
            UIManager:close(sub_menu)
            self:openChapterFile(e.sourceKey, e.mangaKey, e.path)
            return true
        end,
        onMenuHold = function(_m, item)
            local e = item.download_entry
            UIManager:show(ConfirmBox:new{
                text = T(_("Remove download?\n\n%1 - %2"), e.mangaTitle, e.chapterTitle),
                ok_text = _("Remove"),
                ok_callback = function()
                    self.downloads_engine:remove(e.sourceKey, e.mangaKey, e.chapterKey)
                    UIManager:close(sub_menu)
                    self:reload()
                end,
            })
            return true
        end,
        onCloseWidget = function(self_sub)
            Menu.onCloseWidget(self_sub)
            OpenWidgets.remove(self_sub)
        end,
    }
    OpenWidgets.push(sub_menu)
    UIManager:show(sub_menu)
end

function DownloadsBrowser:onMenuSelect(item)
    if item.is_placeholder then
        return true
    end
    if item.queue_task then
        self:showTaskActions(item.queue_task)
        return true
    end
    if item.manga_group then
        self:openMangaGroupChapters(item.manga_group)
        return true
    end
    local entry = item.download_entry
    if entry then
        self:openChapterFile(entry.sourceKey, entry.mangaKey, entry.path)
    end
    return true
end

function DownloadsBrowser:onMenuHold(item)
    if item.is_placeholder then
        return true
    end
    if item.queue_task then
        self:showTaskActions(item.queue_task)
        return true
    end
    if item.manga_group then
        local g = item.manga_group
        local dialog
        local buttons = {
            {{
                text = _("View downloaded chapters"),
                callback = function()
                    UIManager:close(dialog)
                    self:openMangaGroupChapters(g)
                end,
            }},
        }
        if self.engine and self.sources_dir then
            table.insert(buttons, {{
                text = _("Open manga detail page"),
                callback = function()
                    UIManager:close(dialog)
                    Trapper:wrap(function()
                        local found = InstalledSources.findByKey(self.sources_dir, self.engine, g.sourceKey)
                        if not found then
                            UIManager:show(InfoMessage:new{ text = _("Source no longer installed."), timeout = 2 })
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
                            source_key = g.sourceKey,
                            source_name = found.name,
                            downloads_dir = self.downloads_dir or self.downloads_engine.downloads_dir,
                            manga = { Key = g.mangaKey, Title = g.mangaTitle },
                            is_popout = false,
                            is_borderless = true,
                            title_bar_fm_style = true,
                        })
                    end)
                end,
            }})
        end
        table.insert(buttons, {{
            text = T(_("Remove all %1 downloaded chapters"), g.count),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove all %1 downloaded chapters of '%2'?"), g.count, g.mangaTitle),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        Trapper:wrap(function()
                            self.downloads_engine:removeManga(g.sourceKey, g.mangaKey, g.mangaTitle)
                            self:loadAndRefresh()
                        end)
                    end,
                })
            end,
        }})
        dialog = ButtonDialog:new{
            title = g.mangaTitle,
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end
    local entry = item.download_entry
    UIManager:show(ConfirmBox:new{
        text = T(_("Remove download?\n\n%1"), item.text),
        ok_text = _("Remove"),
        ok_callback = function()
            Trapper:wrap(function()
                self.downloads_engine:remove(entry.sourceKey, entry.mangaKey, entry.chapterKey)
                self:loadAndRefresh()
            end)
        end,
    })
    return true
end

return DownloadsBrowser
