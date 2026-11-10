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

local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("aidoku_l10n")

local DownloadQueue = {
    tasks = {},          -- ordered array of task tables
    by_id = {},          -- task.id -> task table
    active_task = nil,   -- currently running task, if any
    active_handle = nil, -- Runner async handle for active_task
    paused = false,
    standby_prevented = false,
    poll_scheduled = false,
    listeners = {},      -- key -> fn(event_kind, task)
    next_seq = 1,
}

local POLL_INTERVAL = 0.45

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
        if existing.status == "completed" and not spec.redownload then
            return existing, false
        end
        existing.status = "queued"
        existing.current_page = 0
        existing.total_pages = 0
        existing.error_msg = nil
        existing.result_path = nil
        existing.redownload = spec.redownload and true or false
        existing.source_path = spec.source_path or existing.source_path
        existing.manga = spec.manga or existing.manga
        existing.chapter = spec.chapter or existing.chapter
        existing.out_path = spec.out_path or existing.out_path
        existing.downloads_dir = spec.downloads_dir or existing.downloads_dir
        existing.manga_dir_name = spec.manga_dir_name or existing.manga_dir_name
        self:notify("enqueued", existing)
        self:pump()
        return existing, true
    end

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
        out_path = out_path,
        downloads_dir = downloads_dir,
        manga_dir_name = manga_dir_name,
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
            if existing.status == "failed" or existing.status == "cancelled" or (existing.status == "completed" and spec.redownload) then
                existing.status = "queued"
                existing.current_page = 0
                existing.total_pages = 0
                existing.error_msg = nil
                existing.result_path = nil
                existing.redownload = spec.redownload and true or false
                added = added + 1
            end
        else
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
                out_path = out_path,
                downloads_dir = downloads_dir,
                manga_dir_name = manga_dir_name,
                redownload = spec.redownload and true or false,
                status = "queued",
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
    self.active_handle = handle
    self:updateStandbyGuard()
    self:notify("started", next_task)
    self:schedulePoll()
end

function DownloadQueue:onPollTick()
    local task = self.active_task
    local handle = self.active_handle
    if not task or not handle then
        self:updateStandbyGuard()
        return
    end

    local prev_cur, prev_tot = task.current_page, task.total_pages
    local state, a, b = handle:poll()
    if state == "running" then
        if a and b and (a ~= prev_cur or b ~= prev_tot) then
            task.current_page = a
            task.total_pages = b
            self:notify("progress", task)
        end
        self:schedulePoll()
        return
    end

    self.active_task = nil
    self.active_handle = nil

    if state == "done" then
        task.status = "completed"
        task.result_path = a
        if task.total_pages > 0 then
            task.current_page = task.total_pages
        end
        task.finished_at = os.time()
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
        self:notify("completed", task)
    else
        task.status = "failed"
        task.error_msg = b or _("command failed")
        task.finished_at = os.time()
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
        self.active_task.status = "queued"
        self.active_task.current_page = 0
        self.active_task.total_pages = 0
        self.active_task = nil
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
            break
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
    if task == self.active_task then
        if self.active_handle then
            self.active_handle:cancel()
        end
        self.active_task = nil
        self.active_handle = nil
        task.status = "cancelled"
        task.finished_at = os.time()
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
        self.active_task.status = "cancelled"
        self.active_task.finished_at = os.time()
        self.active_task = nil
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
