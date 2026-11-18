--[[--
DownloadQueue is a process-wide (require()-cached singleton) background
download manager for Aidoku chapters.

Features:
- Non-blocking background execution via Engine:spawnDownload + UIManager:scheduleIn,
  so users can browse manga, search sources, read chapters, or inspect the
  Download Manager while single or batch downloads run.
- Real-time page-by-page progress ("[download] page N/M") parsed incrementally
  from aidoku-run's stderr, plus overall queue progress.
- Full task lifecycle controls: enqueue, enqueueBatch, pause, resume,
  prioritize, cancelTask, cancelAll, retryTask, retryFailed, clearFinished.
- UIManager:preventStandby / allowStandby lifecycle management so e-readers
  don't suspend mid-batch.
]]

local DownloadsEngine = require("downloadsengine")
local EpubHelper = require("epubhelper")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local util = require("util")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local DownloadQueue = {
    tasks = {},            -- ordered array of task tables
    by_id = {},            -- task.id -> task table
    active_task = nil,     -- lead task for the active subprocess
    active_batch = nil,    -- array of tasks owned by active_handle
    active_old_keys = nil, -- pre-update EPUB keys for post-batch SDR remapping
    active_handle = nil,   -- Runner async handle for active_task
    paused = false,
    standby_prevented = false,
    poll_scheduled = false,
    listeners = {},        -- key -> fn(event_kind, task)
    next_seq = 1,
}

local POLL_INTERVAL = 0.45
local NOVEL_BATCH_SIZE = 25

local function makeId(source_key, manga_key, chapter_key)
    return tostring(source_key or "") .. "\0" .. tostring(manga_key or "") .. "\0" .. tostring(chapter_key or "")
end

function DownloadQueue.progressBar(current, total, width)
    width = width or 8
    if not total or total <= 0 then
        return "[" .. string.rep("·", width) .. "]"
    end
    local ratio = math.max(0, math.min(1, (current or 0) / total))
    local filled = math.floor(ratio * width + 0.5)
    return "[" .. string.rep("■", filled) .. string.rep("□", width - filled) .. "]"
end

function DownloadQueue:setContext(ctx)
    if not ctx then
        return
    end
    if ctx.engine then self.engine = ctx.engine end
    if ctx.store then self.store = ctx.store end
    if ctx.downloads_engine then self.downloads_engine = ctx.downloads_engine end
    if ctx.downloads_dir then self.downloads_dir = ctx.downloads_dir end
end

function DownloadQueue:subscribe(key, fn)
    self.listeners[key] = fn
end

function DownloadQueue:unsubscribe(key)
    self.listeners[key] = nil
end

function DownloadQueue:notify(event_kind, task)
    for _key, fn in pairs(self.listeners) do
        pcall(fn, event_kind, task)
    end
end

function DownloadQueue:updateStandbyGuard()
    local should_hold = (self.active_task ~= nil)
    if should_hold and not self.standby_prevented then
        self.standby_prevented = true
        UIManager:preventStandby()
    elseif not should_hold and self.standby_prevented then
        self.standby_prevented = false
        UIManager:allowStandby()
    end
end

local function reactivateTask(existing, spec)
    existing.status = "queued"
    existing.current_page = 0
    existing.total_pages = 0
    existing.error_msg = nil
    existing.result_path = nil
    existing.redownload = spec.redownload and true or false
    existing.source_path = spec.source_path or existing.source_path
    existing.manga = spec.manga or existing.manga
    existing.chapter = spec.chapter or existing.chapter
    existing.koobone_vol = spec.koobone_vol or existing.koobone_vol
    existing.out_path = spec.out_path or existing.out_path
    existing.downloads_dir = spec.downloads_dir or existing.downloads_dir
    existing.manga_dir_name = spec.manga_dir_name or existing.manga_dir_name
    if spec.is_novel ~= nil then
        existing.is_novel = spec.is_novel and true or false
    end
    if spec.canonical_keys ~= nil then
        existing.canonical_keys = spec.canonical_keys
    end
end

local function buildTask(self, id, spec)
    local chapter_label = spec.chapter_title or spec.chapter_key
    local downloads_dir = spec.downloads_dir or self.downloads_dir
    local out_path = spec.out_path
    if not out_path and downloads_dir then
        local safe = util.getSafeFilename(chapter_label .. ".cbz", downloads_dir)
        out_path = downloads_dir .. "/" .. safe
    end
    local manga_dir_name = spec.manga_dir_name
    if not manga_dir_name and spec.manga_title and spec.source_key then
        manga_dir_name = spec.manga_title .. " [" .. spec.source_key .. "]"
    end

    local task = {
        seq = self.next_seq,
        id = id,
        source_key = spec.source_key,
        source_path = spec.source_path,
        source_name = spec.source_name or spec.source_key,
        manga_key = spec.manga_key,
        manga_title = spec.manga_title or spec.manga_key,
        manga = spec.manga,
        chapter_key = spec.chapter_key,
        chapter_title = chapter_label,
        chapter = spec.chapter,
        koobone_vol = spec.koobone_vol,
        out_path = out_path,
        downloads_dir = downloads_dir,
        manga_dir_name = manga_dir_name,
        is_novel = spec.is_novel and true or false,
        canonical_keys = spec.canonical_keys,
        redownload = spec.redownload and true or false,
        status = "queued", -- "queued" | "downloading" | "completed" | "failed" | "cancelled"
        current_page = 0,
        total_pages = 0,
        error_msg = nil,
        result_path = nil,
        added_at = os.time(),
        finished_at = nil,
    }
    self.next_seq = self.next_seq + 1
    table.insert(self.tasks, task)
    self.by_id[id] = task
    return task
end

local function isCompletedStillOnDisk(self, existing, spec)
    if self.downloads_engine and self.downloads_engine.path then
        return self.downloads_engine:path(spec.source_key, spec.manga_key, spec.chapter_key) ~= ""
    end
    if type(existing.result_path) == "string" and existing.result_path ~= "" then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok and lfs then
            return lfs.attributes(existing.result_path, "mode") == "file"
        end
    end
    return false
end

-- enqueue adds one chapter download task (or re-queues a failed/cancelled one).
-- Returns (task, was_added).
function DownloadQueue:enqueue(spec)
    local id = makeId(spec.source_key, spec.manga_key, spec.chapter_key)
    local existing = self.by_id[id]
    if existing then
        if existing.status == "downloading" or existing.status == "queued" then
            return existing, false
        end
        -- Re-activate a previously failed/cancelled/completed entry if explicitly requested
        -- or if the previously recorded file is no longer indexed/present on disk.
        if existing.status == "completed" and not spec.redownload and isCompletedStillOnDisk(self, existing, spec) then
            return existing, false
        end
        reactivateTask(existing, spec)
        self:notify("enqueued", existing)
        self:pump()
        return existing, true
    end

    local task = buildTask(self, id, spec)
    self:notify("enqueued", task)
    self:pump()
    return task, true
end

-- enqueueBatch adds an array of specs without pumping/notifying per item, then
-- triggers one notify + pump at the end. Returns count of newly queued tasks.
function DownloadQueue:enqueueBatch(specs, ctx)
    self:setContext(ctx)
    local added = 0
    for _idx, spec in ipairs(specs) do
        local id = makeId(spec.source_key, spec.manga_key, spec.chapter_key)
        local existing = self.by_id[id]
        if existing then
            if existing.status == "failed"
                or existing.status == "cancelled"
                or (existing.status == "completed" and (spec.redownload or not isCompletedStillOnDisk(self, existing, spec)))
            then
                reactivateTask(existing, spec)
                added = added + 1
            end
        else
            buildTask(self, id, spec)
            added = added + 1
        end
    end
    if added > 0 then
        self.paused = false
        self:notify("batch_enqueued")
        self:pump()
    end
    return added
end

function DownloadQueue:schedulePoll()
    if self.poll_scheduled or not self.active_task then
        return
    end
    self.poll_scheduled = true
    UIManager:scheduleIn(POLL_INTERVAL, function()
        self.poll_scheduled = false
        self:onPollTick()
    end)
end

function DownloadQueue:isNovelTask(task)
    if type(task) ~= "table" then
        return false
    end
    if task.is_novel == true or task.source_key == "zh.biquge" then
        return true
    end
    if self.downloads_engine and self.downloads_engine.mangaEpubPath then
        return self.downloads_engine:mangaEpubPath(task.source_key, task.manga_key) ~= ""
    end
    return false
end

function DownloadQueue:pump()
    if self.active_task or self.paused or not self.engine then
        self:updateStandbyGuard()
        return
    end

    local next_task
    for _idx, t in ipairs(self.tasks) do
        if t.status == "queued" then
            next_task = t
            break
        end
    end
    if not next_task then
        self:updateStandbyGuard()
        return
    end

    if self:isNovelTask(next_task)
        and type(next_task.manga) == "table"
        and type(next_task.chapter) == "table"
    then
        local dl_map = self.downloads_engine
            and self.downloads_engine:downloadedPathsMap(next_task.source_key, next_task.manga_key, next_task.manga_title)
            or nil
        local batch = {}
        local skipped_any = false
        local now = os.time()
        for _idx, t in ipairs(self.tasks) do
            if #batch >= NOVEL_BATCH_SIZE then
                break
            end
            if t.status == "queued"
                and t.source_key == next_task.source_key
                and t.manga_key == next_task.manga_key
                and (t.redownload and true or false) == (next_task.redownload and true or false)
                and type(t.chapter) == "table"
            then
                local existing = (not t.redownload and dl_map) and (dl_map[t.chapter_key] or "") or ""
                if existing ~= "" then
                    t.status = "completed"
                    t.result_path = existing
                    t.finished_at = now
                    skipped_any = true
                else
                    table.insert(batch, t)
                end
            end
        end

        if #batch == 0 then
            if skipped_any then
                self:notify("completed", next_task)
            end
            self:pump()
            return
        end

        local existing_epub = ""
        if self.downloads_engine and self.downloads_engine.mangaEpubPath then
            existing_epub = self.downloads_engine:mangaEpubPath(next_task.source_key, next_task.manga_key)
        end
        local old_keys
        if existing_epub ~= "" and not EpubHelper.usesAdjacentSidecar(existing_epub) then
            old_keys = EpubHelper.manifestKeys(EpubHelper.readManifest(existing_epub))
        end

        local chapters = {}
        for _idx, t in ipairs(batch) do
            table.insert(chapters, t.chapter)
        end
        local handle, err = self.engine:spawnBatchDownload({
            source_path = next_task.source_path,
            manga = next_task.manga,
            chapters = chapters,
            canonical_keys = next_task.canonical_keys,
            out_path = existing_epub ~= "" and existing_epub or next_task.out_path,
            downloads_dir = next_task.downloads_dir,
            manga_dir_name = next_task.manga_dir_name,
            redownload = next_task.redownload,
        })
        if not handle then
            local fail_ts = os.time()
            for _idx, t in ipairs(batch) do
                t.status = "failed"
                t.error_msg = err or _("command failed")
                t.finished_at = fail_ts
            end
            self:notify("failed", batch[1])
            self:pump()
            return
        end

        local start_ts = os.time()
        for _idx, t in ipairs(batch) do
            t.status = "downloading"
            t.current_page = 0
            t.total_pages = #batch
            t.started_at = start_ts
        end
        self.active_task = batch[1]
        self.active_batch = batch
        self.active_old_keys = old_keys
        self.active_handle = handle
        self:updateStandbyGuard()
        self:notify("started", batch[1])
        self:schedulePoll()
        return
    end

    -- Skip spawning if chapter was already downloaded in the meantime (unless redownload)
    if not next_task.redownload and self.downloads_engine then
        local existing = self.downloads_engine:path(next_task.source_key, next_task.manga_key, next_task.chapter_key)
        if existing ~= "" then
            next_task.status = "completed"
            next_task.result_path = existing
            next_task.finished_at = os.time()
            self:notify("completed", next_task)
            self:pump()
            return
        end
    end

    local handle, err = self.engine:spawnDownload(next_task)
    if not handle then
        next_task.status = "failed"
        next_task.error_msg = err or _("command failed")
        next_task.finished_at = os.time()
        self:notify("failed", next_task)
        self:pump()
        return
    end

    next_task.status = "downloading"
    next_task.current_page = 0
    next_task.total_pages = 0
    next_task.started_at = os.time()
    self.active_task = next_task
    self.active_batch = { next_task }
    self.active_old_keys = nil
    self.active_handle = handle
    self:updateStandbyGuard()
    self:notify("started", next_task)
    self:schedulePoll()
end

function DownloadQueue:onPollTick()
    local task = self.active_task
    local handle = self.active_handle
    local batch = self.active_batch or (task and { task } or nil)
    if not task or not handle or not batch then
        self:updateStandbyGuard()
        return
    end

    local prev_cur, prev_tot = task.current_page, task.total_pages
    local state, a, b = handle:poll()
    if state == "running" then
        if a and b and (a ~= prev_cur or b ~= prev_tot) then
            for _idx, t in ipairs(batch) do
                t.current_page = a
                t.total_pages = b
            end
            self:notify("progress", task)
        end
        self:schedulePoll()
        return
    end

    local old_keys = self.active_old_keys
    self.active_task = nil
    self.active_batch = nil
    self.active_old_keys = nil
    self.active_handle = nil

    if state == "done" then
        local done_ts = os.time()
        for _idx, t in ipairs(batch) do
            t.status = "completed"
            t.result_path = a
            if t.total_pages > 0 then
                t.current_page = t.total_pages
            end
            t.finished_at = done_ts
        end

        if EpubHelper.isEpub(a) then
            EpubHelper.invalidateCache(a)
            if old_keys and #old_keys > 0 and not EpubHelper.usesAdjacentSidecar(a) then
                local new_keys = EpubHelper.manifestKeys(EpubHelper.readManifest(a))
                EpubHelper.remapDocSettings(a, old_keys, new_keys)
            end
            local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
            if ok_r and ReaderUI and ReaderUI.instance and ReaderUI.instance.document
                and DownloadsEngine.normalizePath(ReaderUI.instance.document.file) == DownloadsEngine.normalizePath(a)
            then
                UIManager:show(Notification:new{
                    text = T(_("Added %1 chapter(s) to current book."), #batch),
                    timeout = 3,
                })
            end
        end

        -- Apply storage limit pruning while protecting all paths completed in
        -- the current session queue so a batch download doesn't prune itself.
        if self.store and self.downloads_engine and not self.store:isEphemeralMode() then
            local limit = self.store:downloadLimitBytes()
            if limit and limit > 0 then
                local keep = {}
                for _idx, t in ipairs(self.tasks) do
                    if t.result_path then
                        keep[t.result_path] = true
                    end
                end
                self.downloads_engine:prune(limit, keep)
            end
        end
        DownloadsEngine.invalidateCache(task.downloads_dir or self.downloads_dir)
        self:notify("completed", task)
    else
        local fail_ts = os.time()
        for _idx, t in ipairs(batch) do
            t.status = "failed"
            t.error_msg = b or _("command failed")
            t.finished_at = fail_ts
        end
        self:notify("failed", task)
    end

    self:pump()
end

function DownloadQueue:pause()
    if self.paused then
        return
    end
    self.paused = true
    if self.active_task and self.active_handle then
        self.active_handle:cancel()
        for _idx, t in ipairs(self.active_batch or { self.active_task }) do
            t.status = "queued"
            t.current_page = 0
            t.total_pages = 0
        end
        self.active_task = nil
        self.active_batch = nil
        self.active_old_keys = nil
        self.active_handle = nil
    end
    self:updateStandbyGuard()
    self:notify("paused")
end

function DownloadQueue:resume()
    if not self.paused then
        return
    end
    self.paused = false
    self:notify("resumed")
    self:pump()
end

function DownloadQueue:prioritize(task_id)
    local idx
    for i, t in ipairs(self.tasks) do
        if t.id == task_id and t.status == "queued" then
            idx = i
            break
        end
    end
    if not idx then
        return false
    end
    local task = table.remove(self.tasks, idx)
    local insert_at = 1
    for i, t in ipairs(self.tasks) do
        if t.status == "downloading" then
            insert_at = i + 1
        end
    end
    table.insert(self.tasks, insert_at, task)
    self:notify("reordered", task)
    return true
end

function DownloadQueue:cancelTask(task_id)
    local task = self.by_id[task_id]
    if not task then
        return false
    end
    local in_active_batch = false
    for _idx, t in ipairs(self.active_batch or (self.active_task and { self.active_task } or {})) do
        if t == task then
            in_active_batch = true
            break
        end
    end
    if in_active_batch then
        local batch = self.active_batch or { self.active_task }
        if self.active_handle then
            self.active_handle:cancel()
        end
        self.active_task = nil
        self.active_batch = nil
        self.active_old_keys = nil
        self.active_handle = nil
        for _idx, t in ipairs(batch) do
            if t == task then
                t.status = "cancelled"
                t.finished_at = os.time()
            else
                t.status = "queued"
                t.current_page = 0
                t.total_pages = 0
            end
        end
        self:notify("cancelled", task)
        self:pump()
        return true
    elseif task.status == "queued" then
        task.status = "cancelled"
        task.finished_at = os.time()
        self:notify("cancelled", task)
        return true
    end
    return false
end

function DownloadQueue:removeTaskRecord(task_id)
    local task = self.by_id[task_id]
    if not task then
        return
    end
    if task.status == "downloading" or task.status == "queued" then
        self:cancelTask(task_id)
    end
    self.by_id[task_id] = nil
    for i = #self.tasks, 1, -1 do
        if self.tasks[i].id == task_id then
            table.remove(self.tasks, i)
            break
        end
    end
    self:notify("removed")
end

function DownloadQueue:cancelAll()
    if self.active_task and self.active_handle then
        self.active_handle:cancel()
        local now = os.time()
        for _idx, t in ipairs(self.active_batch or { self.active_task }) do
            t.status = "cancelled"
            t.finished_at = now
        end
        self.active_task = nil
        self.active_batch = nil
        self.active_old_keys = nil
        self.active_handle = nil
    end
    for _idx, t in ipairs(self.tasks) do
        if t.status == "queued" then
            t.status = "cancelled"
            t.finished_at = os.time()
        end
    end
    self.paused = false
    self:updateStandbyGuard()
    self:notify("cancelled_all")
end

function DownloadQueue:retryTask(task_id)
    local task = self.by_id[task_id]
    if not task or (task.status ~= "failed" and task.status ~= "cancelled") then
        return false
    end
    task.status = "queued"
    task.current_page = 0
    task.total_pages = 0
    task.error_msg = nil
    task.finished_at = nil
    self.paused = false
    self:notify("retried", task)
    self:pump()
    return true
end

function DownloadQueue:retryFailed()
    local count = 0
    for _idx, t in ipairs(self.tasks) do
        if t.status == "failed" or t.status == "cancelled" then
            t.status = "queued"
            t.current_page = 0
            t.total_pages = 0
            t.error_msg = nil
            t.finished_at = nil
            count = count + 1
        end
    end
    if count > 0 then
        self.paused = false
        self:notify("retried_all")
        self:pump()
    end
    return count
end

function DownloadQueue:clearFinished()
    local kept = {}
    for _idx, t in ipairs(self.tasks) do
        if t.status == "downloading" or t.status == "queued" then
            table.insert(kept, t)
        else
            self.by_id[t.id] = nil
        end
    end
    self.tasks = kept
    self:notify("cleared_finished")
end

function DownloadQueue:getStats()
    local s = {
        downloading = 0,
        queued = 0,
        completed = 0,
        failed = 0,
        cancelled = 0,
        total = #self.tasks,
        paused = self.paused,
        active = self.active_task,
    }
    for _idx, t in ipairs(self.tasks) do
        s[t.status] = (s[t.status] or 0) + 1
    end
    s.pending = s.downloading + s.queued
    return s
end

function DownloadQueue:getChapterTask(source_key, manga_key, chapter_key)
    return self.by_id[makeId(source_key, manga_key, chapter_key)]
end

function DownloadQueue:getMangaTaskStats(source_key, manga_key, canonical_key)
    local active, queued, failed = 0, 0, 0
    for _idx, t in ipairs(self.tasks) do
        if t.source_key == source_key and (
            t.manga_key == manga_key
            or (canonical_key and canonical_key ~= "" and t.manga_key == canonical_key)
            or (manga_key and t.manga_key:sub(1, #manga_key + 1) == manga_key .. "/")
        ) then
            if t.status == "downloading" then
                active = active + 1
            elseif t.status == "queued" then
                queued = queued + 1
            elseif t.status == "failed" then
                failed = failed + 1
            end
        end
    end
    return active, queued, failed
end

return DownloadQueue
