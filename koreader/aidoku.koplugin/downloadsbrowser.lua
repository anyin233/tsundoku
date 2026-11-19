--[[--
DownloadsBrowser (Download Manager):
- Displays live download queue progress (page-by-page / chapter progress bar,
  percentage, queued tasks, pause/resume, cancel, prioritize, retry) in real time.
- Completed downloads are automatically removed from the queue so only active,
  queued, failed, and cancelled tasks remain listed.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DownloadQueue = require("downloadqueue")
local Menu = require("ui/widget/menu")
local OpenWidgets = require("openwidgets")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

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
    name = "tsundoku_downloads",
    title_bar_left_icon = "appbar.menu",
}

function DownloadsBrowser:init()
    self.title = _("Download Manager")
    self.refresh_pending = false
    self.item_table = self:genItemTable()
    Menu.init(self)
    OpenWidgets.push(self)

    self.listener_key = tostring(self)
    DownloadQueue:subscribe(self.listener_key, function()
        if not self.closed then
            self:scheduleRefresh()
        end
    end)
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
function DownloadsBrowser:scheduleRefresh()
    if self.refresh_pending then
        return
    end
    self.refresh_pending = true
    UIManager:scheduleIn(0.35, function()
        self.refresh_pending = false
        if not self.closed then
            self:rebuildUI()
        end
    end)
end

function DownloadsBrowser:buildSubtitle(qstats)
    if qstats.active then
        local t = qstats.active
        local page_str
        if t.total_pages and t.total_pages > 0 then
            local pct = math.floor((t.current_page * 100) / t.total_pages)
            if #(DownloadQueue.active_batch or {}) > 1 or DownloadQueue:isNovelTask(t) then
                page_str = string.format("%d/%d (%d%%)", t.current_page, t.total_pages, pct)
            else
                page_str = T(_("%1/%2p (%3%)"), t.current_page, t.total_pages, pct)
            end
        else
            page_str = _("Preparing…")
        end
        return T(_("Active: %1 · Queue: %2"), page_str, qstats.pending)
    elseif qstats.paused and qstats.queued > 0 then
        return T(_("Paused (%1 queued)"), qstats.queued)
    elseif qstats.failed > 0 then
        return T(_("%1 failed"), qstats.failed)
    end
    return _("No active downloads")
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
    end
    return ""
end

function DownloadsBrowser:genItemTable()
    local item_table = {}
    local qstats = DownloadQueue:getStats()
    local subtitle = self:buildSubtitle(qstats)

    if self.title_bar then
        self.title_bar:setSubTitle(subtitle, true)
    else
        self.subtitle = subtitle
    end

    local shown_tasks = {}
    for _idx, t in ipairs(DownloadQueue.tasks) do
        if t.status ~= "completed" then
            table.insert(shown_tasks, t)
        end
    end

    if #shown_tasks > 0 then
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
    else
        table.insert(item_table, {
            text = _("No active download tasks in queue."),
            dim = true,
            is_placeholder = true,
        })
    end

    return item_table
end

function DownloadsBrowser:rebuildUI()
    self.item_table = self:genItemTable()
    if self.perpage and self.perpage > 0 then
        local max_page = math.max(1, math.ceil(#self.item_table / self.perpage))
        if self.page and self.page > max_page then
            self.page = max_page
        end
    end
    self:updateItems(1)
end

function DownloadsBrowser:reload()
    self:rebuildUI()
end

function DownloadsBrowser:onLeftButtonTap()
    local qstats = DownloadQueue:getStats()
    local dialog
    local buttons = {}

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

    if (qstats.failed + qstats.cancelled) > 0 then
        table.insert(buttons, {{
            text = _("Clear failed/cancelled tasks"),
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

function DownloadsBrowser:onMenuSelect(item)
    if item.is_placeholder then
        return true
    end
    if item.queue_task then
        self:showTaskActions(item.queue_task)
    end
    return true
end

function DownloadsBrowser:onMenuHold(item)
    if item.is_placeholder then
        return true
    end
    if item.queue_task then
        self:showTaskActions(item.queue_task)
    end
    return true
end

return DownloadsBrowser
