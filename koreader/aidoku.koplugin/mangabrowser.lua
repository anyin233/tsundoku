--[[--
MangaBrowser: shows one manga's chapter list with:
- Multi-mode chapter sorting:
  * Source default order (newest-first / oldest-first)
  * Chapter name order (A->Z / Z->A, natural alphanumeric/UTF-8 aware)
  * Update time order (DateUploaded newest-first / oldest-first)
- One-click Batch Download All Chapters (plus Download Next N Chapters and
  Download From Here Onward) backed by non-blocking DownloadQueue.
- Live per-chapter download/queue progress indicators + jump to Download Manager.
- Bookmark toggle & canonical manga metadata persistence for downloaded-book badges.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ChapterCache = require("chaptercache")
local ChapterOrder = require("chapterorder")
local ConfirmBox = require("ui/widget/confirmbox")
local DownloadQueue = require("downloadqueue")
local DownloadsEngine = require("downloadsengine")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local OpenWidgets = require("openwidgets")
local Prefetch = require("prefetch")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local MangaBrowser = Menu:extend{}

local mangaLabel = Prefetch.mangaLabel
local chapterLabel = Prefetch.chapterLabel

local function mangaCover(manga)
    return manga and type(manga.Cover) == "string" and manga.Cover or nil
end

local SORT_OPTIONS = {
    { id = "source_desc", label = function() return _("Default (Newest chapter first)") end, short = function() return _("Newest") end },
    { id = "source_asc",  label = function() return _("Default (Oldest chapter first)") end, short = function() return _("Oldest") end },
    { id = "name_asc",    label = function() return _("By Name (A → Z)") end,                short = function() return _("Name ↑") end },
    { id = "name_desc",   label = function() return _("By Name (Z → A)") end,                short = function() return _("Name ↓") end },
    { id = "date_desc",   label = function() return _("By Update Time (Latest first)") end,  short = function() return _("Updated ↓") end },
    { id = "date_asc",    label = function() return _("By Update Time (Earliest first)") end,short = function() return _("Updated ↑") end },
}

local function sortShortLabel(mode)
    for _idx, opt in ipairs(SORT_OPTIONS) do
        if opt.id == mode then
            return opt.short()
        end
    end
    return _("Newest")
end

function MangaBrowser:init()
    self.initial_manga_key = self.manga and self.manga.Key or ""
    self.title = mangaLabel(self.manga)
    self.subtitle = self.source_name
    self.chapters = {}
    self.network_loaded = false
    self.downloaded_keys = {}
    self.item_table = {}
    self.refresh_pending = false
    self.title_bar_left_icon = "appbar.menu"
    Menu.init(self)
    OpenWidgets.push(self)

    self.listener_key = tostring(self)
    DownloadQueue:subscribe(self.listener_key, function(event_kind, task)
        if self.closed then
            return
        end
        if task and task.status == "completed" and task.source_key == self.source_key and (
            task.manga_key == self.manga.Key or task.manga_key == self.initial_manga_key
        ) then
            if task.result_path and task.result_path ~= "" then
                self.downloaded_keys[task.chapter_key] = task.result_path
            end
            if self.refresh_callback then
                self.refresh_callback()
            end
        end
        self:scheduleRefresh(event_kind == "completed")
    end)

    UIManager:nextTick(function() self:reload() end)
end

function MangaBrowser:onCloseWidget()
    self.closed = true
    if self.listener_key then
        DownloadQueue:unsubscribe(self.listener_key)
    end
    Menu.onCloseWidget(self)
    OpenWidgets.remove(self)
end

function MangaBrowser:scheduleRefresh(reload_keys)
    if reload_keys then
        self.needs_key_reload = true
    end
    if self.refresh_pending then
        return
    end
    self.refresh_pending = true
    UIManager:scheduleIn(0.4, function()
        self.refresh_pending = false
        if self.closed then
            return
        end
        if self.needs_key_reload then
            self.needs_key_reload = false
            self:reloadDownloadedKeys()
        end
        self:refresh()
    end)
end

function MangaBrowser:downloadedCount()
    local n = 0
    for _idx, c in ipairs(self.chapters) do
        if self:downloadedPath(c.Key) ~= "" then
            n = n + 1
        end
    end
    return n
end

function MangaBrowser:updateHeaderSubtitle()
    local sort_mode = self.store:chapterSortMode()
    local total = #self.chapters
    local dl = self:downloadedCount()
    local active, queued = DownloadQueue:getMangaTaskStats(self.source_key, self.initial_manga_key, self.manga.Key)
    local parts = { self.source_name or self.source_key }
    if total > 0 then
        if self.network_loaded and dl >= total then
            table.insert(parts, T(_("✓ All %1 ch downloaded"), total))
        elseif self.network_loaded and dl > 0 then
            table.insert(parts, T(_("Downloaded %1/%2 ch"), dl, total))
        elseif dl > 0 then
            table.insert(parts, T(_("Downloaded %1 ch"), dl))
        else
            table.insert(parts, T(_("%1 ch"), total))
        end
    end
    if (active + queued) > 0 then
        table.insert(parts, T(_("Queue %1"), active + queued))
    end
    table.insert(parts, T(_("Sort: %1"), sortShortLabel(sort_mode)))
    local sub = table.concat(parts, " · ")
    if self.title_bar then
        local bookmarked = self.store:isBookmarked(self.source_key, self.manga.Key)
            or self.store:isBookmarked(self.source_key, self.initial_manga_key)
        local display_title = (bookmarked and "★ " or "") .. mangaLabel(self.manga)
        self.title_bar:setTitle(display_title)
        self.title_bar:setSubTitle(sub, true)
    else
        self.subtitle = sub
    end
end

function MangaBrowser:promptSortMenu()
    local current = self.store:chapterSortMode()
    local dialog
    local buttons = {}
    for _idx, opt in ipairs(SORT_OPTIONS) do
        local is_cur = (opt.id == current)
        local mode_id = opt.id
        table.insert(buttons, {{
            text = (is_cur and "✓ " or "") .. opt.label(),
            callback = function()
                UIManager:close(dialog)
                self.store:setChapterSortMode(mode_id)
                self.page = 1
                self:refresh()
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("Sort chapters by"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function MangaBrowser:openDownloadManager()
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

function MangaBrowser:toggleBookmark()
    local label = mangaLabel(self.manga)
    local is_bm = self.store:isBookmarked(self.source_key, self.manga.Key)
        or self.store:isBookmarked(self.source_key, self.initial_manga_key)
    local ok
    if is_bm then
        ok = self.store:removeBookmark(self.source_key, self.manga.Key)
        if self.initial_manga_key ~= "" and self.initial_manga_key ~= self.manga.Key then
            self.store:removeBookmark(self.source_key, self.initial_manga_key)
        end
    else
        ok = self.store:addBookmark(self.source_key, self.source_path, self.manga.Key, label, mangaCover(self.manga))
    end
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not update library."), timeout = 2 })
        return
    end
    self:updateHeaderSubtitle()
    if self.refresh_callback then
        self.refresh_callback()
    end
    UIManager:show(InfoMessage:new{
        text = (not is_bm) and T(_("Added '%1' to library"), label) or T(_("Removed '%1' from library"), label),
        timeout = 1.5,
    })
end

function MangaBrowser:onLeftButtonTap()
    local sort_mode = self.store:chapterSortMode()
    local qstats = DownloadQueue:getStats()
    local is_bm = self.store:isBookmarked(self.source_key, self.manga.Key)
        or self.store:isBookmarked(self.source_key, self.initial_manga_key)

    local dialog
    local buttons = {
        {{
            text = T(_("Sort chapters: %1…"), sortShortLabel(sort_mode)),
            callback = function()
                UIManager:close(dialog)
                self:promptSortMenu()
            end,
        }},
    }

    if not self.store:isEphemeralMode() then
        local dl_count = self:downloadedCount()
        local total_count = #self.chapters
        local all_btn_text = (total_count > 0 and dl_count < total_count)
            and T(_("Download all chapters (%1 remaining)…"), total_count - dl_count)
            or _("Download all chapters…")
        table.insert(buttons, {{
            text = all_btn_text,
            callback = function()
                UIManager:close(dialog)
                self:promptDownloadAllChapters()
            end,
        }})
        table.insert(buttons, {{
            text = _("Download next chapters…"),
            callback = function()
                UIManager:close(dialog)
                self:promptBulkDownload()
            end,
        }})
    end

    local dm_label = qstats.pending > 0
        and T(_("Download Manager (%1 active)"), qstats.pending)
        or _("Download Manager")
    table.insert(buttons, {{
        text = dm_label,
        callback = function()
            UIManager:close(dialog)
            self:openDownloadManager()
        end,
    }})

    table.insert(buttons, {{
        text = is_bm and _("Remove from library") or _("Add to library"),
        callback = function()
            UIManager:close(dialog)
            self:toggleBookmark()
        end,
    }})

    table.insert(buttons, {{
        text = _("Reset reading progress…"),
        callback = function()
            UIManager:close(dialog)
            self:promptResetProgress()
        end,
    }})

    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function() return self.title_bar.left_button.image.dimen end,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function MangaBrowser:promptResetProgress()
    UIManager:show(ConfirmBox:new{
        text = T(_("Reset progress for %1?\n\nClears read marks and page positions."),
            mangaLabel(self.manga)),
        ok_text = _("Reset"),
        ok_callback = function()
            self.store:resetReadChapters(self.source_key, self.manga.Key)
            self.downloads_engine:resetProgress(self.source_key, self.manga.Key)
            self:refresh()
        end,
    })
end

function MangaBrowser:downloadedPath(chapter_key)
    local path = self.downloaded_keys[chapter_key]
    if not path or path == "" then
        return ""
    end
    if lfs.attributes(path, "mode") ~= "file" then
        return ""
    end
    return path
end

function MangaBrowser:findChapterTask(chapter_key)
    return DownloadQueue:getChapterTask(self.source_key, self.manga.Key, chapter_key)
        or (self.initial_manga_key ~= "" and DownloadQueue:getChapterTask(self.source_key, self.initial_manga_key, chapter_key))
end

function MangaBrowser:genItemTable()
    local item_table = {}
    local sort_mode = self.store:chapterSortMode()
    local ordered = ChapterOrder.sortForDisplay(self.chapters, sort_mode, chapterLabel)
    local is_date_sort = (sort_mode == "date_desc" or sort_mode == "date_asc")

    if #ordered > 0 then
        local dl = self:downloadedCount()
        local active, queued = DownloadQueue:getMangaTaskStats(self.source_key, self.initial_manga_key, self.manga.Key)
        local left_action
        if (active + queued) > 0 then
            left_action = T(_("▶ Downloading (%1 in queue) · Tap for options"), active + queued)
        elseif self.network_loaded and dl >= #ordered then
            left_action = T(_("✓ All %1 chapters downloaded · Options"), #ordered)
        elseif self.network_loaded and not self.store:isEphemeralMode() then
            left_action = T(_("» Batch Download (%1/%2 left) & Sort…"), #ordered - dl, #ordered)
        else
            left_action = _("» Chapter Sort & Options…")
        end
        table.insert(item_table, {
            text = left_action,
            mandatory = T(_("Sort: %1 >"), sortShortLabel(sort_mode)),
            bold = true,
            is_toolbar_row = true,
        })
    end

    for _idx, chapter in ipairs(ordered) do
        local mandatory_parts = {}
        local ts = ChapterOrder.chapterTimestamp(chapter)
        if ts then
            local formatted_date = ChapterOrder.formatTimestamp(ts, is_date_sort)
            if formatted_date then
                table.insert(mandatory_parts, formatted_date)
            end
        end
        if self.store:isChapterRead(self.source_key, self.manga.Key, chapter.Key) then
            table.insert(mandatory_parts, _("Read"))
        end

        local task = self:findChapterTask(chapter.Key)
        if self:downloadedPath(chapter.Key) ~= "" and not (task and task.status == "downloading") then
            table.insert(mandatory_parts, "✓")
        elseif task then
            if task.status == "downloading" then
                if task.total_pages and task.total_pages > 0 then
                    table.insert(mandatory_parts, string.format("▶ %d/%d", task.current_page, task.total_pages))
                else
                    table.insert(mandatory_parts, _("▶ DL…"))
                end
            elseif task.status == "queued" then
                table.insert(mandatory_parts, _("Queued"))
            elseif task.status == "failed" then
                table.insert(mandatory_parts, _("✗ Failed"))
            end
        end

        table.insert(item_table, {
            text = chapterLabel(chapter),
            mandatory = table.concat(mandatory_parts, " · "),
            chapter = chapter,
        })
    end
    return item_table
end

function MangaBrowser:refresh()
    self:updateHeaderSubtitle()
    local saved_page = self.page
    self.item_table = self:genItemTable()
    self:updateItems(saved_page)
end

function MangaBrowser:reloadDownloadedKeys(all)
    all = all or self.downloads_engine:list()
    self.downloaded_keys = {}
    if not all then
        return all
    end
    local mtitle = mangaLabel(self.manga)
    for _idx, entry in ipairs(all) do
        if DownloadsEngine.entryMatchesManga(entry, self.source_key, self.manga.Key, mtitle)
            or (self.initial_manga_key ~= "" and DownloadsEngine.entryMatchesManga(entry, self.source_key, self.initial_manga_key, mtitle))
        then
            self.downloaded_keys[entry.chapterKey] = entry.path
        end
    end
    return all
end

function MangaBrowser:reload()
    Trapper:wrap(function()
        local all = self:reloadDownloadedKeys()
        if #self.chapters == 0 then
            self.chapters = ChapterOrder.fromEntries(all, self.source_key, self.manga.Key)
        end
        self:refresh()

        local updated = ChapterCache.get(self.source_key, self.manga.Key)
        if not updated then
            if not NetworkMgr:isConnected() then
                self:promptResume()
                return
            end

            local err
            updated, err = self.engine:mangaUpdate(self.source_path, self.manga.Key)
            if not updated then
                if #self.chapters == 0 then
                    UIManager:show(InfoMessage:new{ text = T(_("Could not load chapters:\n%1"), err) })
                end
                self:promptResume()
                return
            end
            ChapterCache.set(self.source_key, self.manga.Key, updated)
            if updated.Key and updated.Key ~= self.manga.Key then
                ChapterCache.set(self.source_key, updated.Key, updated)
            end
        end
        self.manga = updated
        self.chapters = type(updated.Chapters) == "table" and updated.Chapters or {}
        self.network_loaded = true
        self.store:recordMangaMeta(self.source_key, self.initial_manga_key, self.manga.Key, #self.chapters)
        local fresh_cover = mangaCover(updated)
        if fresh_cover and fresh_cover ~= "" then
            if self.store:isBookmarked(self.source_key, self.manga.Key)
                or self.store:isBookmarked(self.source_key, self.initial_manga_key)
            then
                self.store:updateBookmarkCover(self.source_key, self.initial_manga_key, fresh_cover)
                if self.manga.Key ~= self.initial_manga_key then
                    self.store:updateBookmarkCover(self.source_key, self.manga.Key, fresh_cover)
                end
            end
        end
        self:reloadDownloadedKeys()
        self:refresh()
        if self.refresh_callback then
            self.refresh_callback()
        end
        self:promptResume()
    end)
end

function MangaBrowser:resumeChapter()
    local ordered = ChapterOrder.orderedByReading(self.chapters)
    if #ordered == 0 then
        return nil
    end
    local last_key = self:findLastReadChapter(ordered)
    if not last_key then
        return nil
    end
    local upcoming = ChapterOrder.after(self.chapters, last_key, 1, function(c)
        return self:downloadedPath(c.Key) ~= ""
    end)
    return upcoming[1]
end

function MangaBrowser:promptResume()
    local chapter = self:resumeChapter()
    if not chapter then
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Resume reading from %1?"), chapterLabel(chapter)),
        ok_text = _("Resume"),
        cancel_text = _("Not now"),
        ok_callback = function()
            self:onMenuSelect({ chapter = chapter })
        end,
    })
end

function MangaBrowser:prefetchAhead(chapter)
    Prefetch.ahead({
        engine = self.engine,
        downloads_engine = self.downloads_engine,
        store = self.store,
        downloads_dir = self.downloads_dir,
        source_path = self.source_path,
        source_key = self.source_key,
        manga = self.manga,
    }, self.chapters, chapter.Key,
    function(c, path)
        self.downloaded_keys[c.Key] = path
    end,
    function(any_new)
        if any_new and not self.closed then
            self:refresh()
        end
    end)
end

function MangaBrowser:findLastReadChapter(ordered)
    local last_key
    for _idx, c in ipairs(ordered) do
        if self.store:isChapterRead(self.source_key, self.manga.Key, c.Key) then
            last_key = c.Key
        end
    end
    return last_key
end

function MangaBrowser:buildQueueSpec(chapter, redownload)
    local mtitle = mangaLabel(self.manga)
    local clabel = chapterLabel(chapter)
    local chapter_filename = util.getSafeFilename(clabel .. ".cbz", self.downloads_dir)
    return {
        source_key = self.source_key,
        source_path = self.source_path,
        source_name = self.source_name,
        manga_key = self.manga.Key,
        manga_title = mtitle,
        manga = self.manga,
        chapter_key = chapter.Key,
        chapter_title = clabel,
        chapter = chapter,
        out_path = self.downloads_dir .. "/" .. chapter_filename,
        downloads_dir = self.downloads_dir,
        manga_dir_name = mtitle .. " [" .. self.source_key .. "]",
        redownload = redownload and true or false,
    }
end

function MangaBrowser:enqueueChaptersList(chapters_list)
    local to_queue = {}
    for _idx, c in ipairs(chapters_list) do
        if self:downloadedPath(c.Key) == "" then
            table.insert(to_queue, self:buildQueueSpec(c, false))
        end
    end
    if #to_queue == 0 then
        UIManager:show(InfoMessage:new{ text = _("All selected chapters are already downloaded."), timeout = 2 })
        return
    end

    NetworkMgr:runWhenConnected(function()
        local added = DownloadQueue:enqueueBatch(to_queue, {
            engine = self.engine,
            store = self.store,
            downloads_engine = self.downloads_engine,
            downloads_dir = self.downloads_dir,
        })
        self:refresh()
        if added == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Chapters are already in the download queue."),
                timeout = 2,
            })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Queued %1 chapter(s) for background download.\n\nYou can keep browsing or open Download Manager to watch live progress."), added),
            ok_text = _("View Progress"),
            cancel_text = _("Stay Here"),
            ok_callback = function()
                self:openDownloadManager()
            end,
        })
    end)
end

-- promptDownloadAllChapters queues every un-downloaded chapter of this manga
-- (in ascending reading order, deduplicating multi-scanlator duplicates of the
-- same chapter number when numbered, or every distinct chapter entry).
function MangaBrowser:promptDownloadAllChapters()
    if #self.chapters == 0 then
        UIManager:show(InfoMessage:new{ text = _("Chapters still loading. Try again shortly."), timeout = 2 })
        return
    end

    local ordered = ChapterOrder.orderedByReading(self.chapters)
    local pending = {}
    for _idx, c in ipairs(ordered) do
        if self:downloadedPath(c.Key) == "" then
            table.insert(pending, c)
        end
    end

    if #pending == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("All %1 chapters are already downloaded locally."), #ordered),
            timeout = 2,
        })
        return
    end

    local already_dl = #ordered - #pending
    UIManager:show(ConfirmBox:new{
        text = T(_("Download all chapters of '%1'?\n\nTotal: %2 chapters\nAlready downloaded: %3\nTo download: %4"),
            mangaLabel(self.manga), #ordered, already_dl, #pending),
        ok_text = T(_("Download %1 ch"), #pending),
        ok_callback = function()
            self:enqueueChaptersList(pending)
        end,
    })
end

function MangaBrowser:downloadNext(n)
    local ordered = ChapterOrder.orderedByReading(self.chapters)
    if #ordered == 0 then
        UIManager:show(InfoMessage:new{ text = _("No chapters to download."), timeout = 2 })
        return
    end

    local last_key = self:findLastReadChapter(ordered)
    local function is_local(c)
        return self:downloadedPath(c.Key) ~= ""
    end
    local upcoming
    if last_key then
        upcoming = ChapterOrder.after(self.chapters, last_key, n, is_local)
    else
        upcoming = { ordered[1] }
        for _idx, c in ipairs(ChapterOrder.after(self.chapters, ordered[1].Key, n - 1, is_local)) do
            table.insert(upcoming, c)
        end
    end
    if #upcoming == 0 then
        UIManager:show(InfoMessage:new{ text = _("No next chapter yet."), timeout = 2 })
        return
    end

    self:enqueueChaptersList(upcoming)
end

function MangaBrowser:promptBulkDownload()
    if #self.chapters == 0 then
        UIManager:show(InfoMessage:new{ text = _("Chapters still loading. Try again shortly."), timeout = 2 })
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Download next chapters"),
        description = _("Chapters to queue in background, starting after the last one read."),
        input = "5",
        input_type = "number",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Download"),
                is_enter_default = true,
                callback = function()
                    local n = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if n and n >= 1 then
                        self:downloadNext(math.floor(n))
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MangaBrowser:openLocal(path)
    self.store:markLastRead(self.source_key, self.manga.Key)
    UIManager:close(self)
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function MangaBrowser:downloadAndOpen(chapter, redownload)
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local clabel = chapterLabel(chapter)
            local chapter_filename = util.getSafeFilename(clabel .. ".cbz", self.downloads_dir)
            local out_path = self.downloads_dir .. "/" .. chapter_filename
            local manga_dir_name = mangaLabel(self.manga) .. " [" .. self.source_key .. "]"
            local progress_prefix = T(_("Downloading %1"), clabel)

            local path, err = self.engine:download(
                self.source_path, self.manga.Key, chapter.Key, out_path,
                self.downloads_dir, nil, progress_prefix, manga_dir_name,
                redownload, self.manga, chapter
            )
            if not path then
                if err ~= _("Cancelled") then
                    UIManager:show(InfoMessage:new{ text = T(_("Download failed:\n%1"), err) })
                end
                return
            end
            self.downloaded_keys[chapter.Key] = path
            if not self.store:isEphemeralMode() then
                self.downloads_engine:prune(self.store:downloadLimitBytes(), path)
            end
            if self.refresh_callback then
                self.refresh_callback()
            end
            self:refresh()
            self:openLocal(path)
            if self.store:isEphemeralMode() then
                self.downloads_engine:removeAllExcept(path)
            end
            UIManager:nextTick(function() self:prefetchAhead(chapter) end)
        end)
    end)
end

function MangaBrowser:onMenuSelect(item)
    if item.is_toolbar_row then
        self:onLeftButtonTap()
        return true
    end
    local existing = self:downloadedPath(item.chapter.Key)
    if existing ~= "" then
        self:openLocal(existing)
        if self.store:isEphemeralMode() then
            self.downloads_engine:removeAllExcept(existing)
        end
        UIManager:nextTick(function() self:prefetchAhead(item.chapter) end)
        return true
    end

    self:downloadAndOpen(item.chapter)
    return true
end

function MangaBrowser:onMenuHold(item)
    if item.is_toolbar_row then
        self:promptSortMenu()
        return true
    end
    local chapter = item.chapter
    local chapter_key = chapter.Key
    local is_read = self.store:isChapterRead(self.source_key, self.manga.Key, chapter_key)
    local is_downloaded = self:downloadedPath(chapter_key) ~= ""
    local task = self:findChapterTask(chapter_key)

    local dialog
    local buttons = {
        {{
            text = is_read and _("Mark as unread") or _("Mark as read"),
            callback = function()
                UIManager:close(dialog)
                if is_read then
                    self.store:markChapterUnread(self.source_key, self.manga.Key, chapter_key)
                else
                    self.store:markChapterRead(self.source_key, self.manga.Key, chapter_key)
                end
                self:refresh()
            end,
        }},
    }

    if not self.store:isEphemeralMode() then
        if task and (task.status == "downloading" or task.status == "queued") then
            table.insert(buttons, {{
                text = _("Cancel background download"),
                callback = function()
                    UIManager:close(dialog)
                    DownloadQueue:cancelTask(task.id)
                    self:refresh()
                end,
            }})
        elseif not is_downloaded then
            table.insert(buttons, {{
                text = _("Download in background"),
                callback = function()
                    UIManager:close(dialog)
                    NetworkMgr:runWhenConnected(function()
                        DownloadQueue:setContext({
                            engine = self.engine,
                            store = self.store,
                            downloads_engine = self.downloads_engine,
                            downloads_dir = self.downloads_dir,
                        })
                        DownloadQueue:enqueue(self:buildQueueSpec(chapter, false))
                        self:refresh()
                    end)
                end,
            }})
        end

        table.insert(buttons, {{
            text = _("Download from this chapter onward"),
            callback = function()
                UIManager:close(dialog)
                local ordered = ChapterOrder.orderedByReading(self.chapters)
                local slice = {}
                local started = false
                for _idx, c in ipairs(ordered) do
                    if c.Key == chapter_key then
                        started = true
                    end
                    if started and self:downloadedPath(c.Key) == "" then
                        table.insert(slice, c)
                    end
                end
                self:enqueueChaptersList(slice)
            end,
        }})
    end

    if is_downloaded then
        table.insert(buttons, {{
            text = _("Re-download"),
            callback = function()
                UIManager:close(dialog)
                self:downloadAndOpen(chapter, true)
            end,
        }})
        table.insert(buttons, {{
            text = _("Remove download"),
            callback = function()
                UIManager:close(dialog)
                Trapper:wrap(function()
                    self.downloads_engine:remove(self.source_key, self.manga.Key, chapter_key)
                    if self.initial_manga_key ~= "" and self.initial_manga_key ~= self.manga.Key then
                        self.downloads_engine:remove(self.source_key, self.initial_manga_key, chapter_key)
                    end
                    self.downloaded_keys[chapter_key] = nil
                    if self.refresh_callback then
                        self.refresh_callback()
                    end
                    self:refresh()
                end)
            end,
        }})
    end

    dialog = ButtonDialog:new{
        title = chapterLabel(chapter),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return true
end

return MangaBrowser
