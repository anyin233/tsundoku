--[[--
KooboneBrowser: Native Koobone online reader bookshelf integration for Tsundoku.

Capabilities:
- Browse all manga series and individual volumes pushed from Kox.moe / kzo.moe
  to Koobone (`koobone.com`) or uploaded directly to Koobone.
- View real-time local offline status (`✓` downloaded, `▶` downloading/queued)
  and reading progress.
- One-tap "Sync All to Local" (离线同步全部书架) and per-series offline sync,
  plus a toggle for automatic background offline sync (`kox.moe -> Koobone -> KOReader`).
- Tap any volume to either open its local `.cbz` immediately or download & open it.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DownloadQueue = require("downloadqueue")
local InfoMessage = require("ui/widget/infomessage")
local InstalledSources = require("installedsources")
local KooboneSync = require("koobonesync")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local OpenWidgets = require("openwidgets")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local KooboneBrowser = Menu:extend{
    title_bar_left_icon = "appbar.menu",
}

local function formatBytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 * 1024 then
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    elseif bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%d KB", math.floor(bytes / 1024 + 0.5))
    end
    return string.format("%d B", bytes)
end

function KooboneBrowser:init()
    self.title = _("Koobone Bookshelf")
    self.view_mode = self.view_mode or "series" -- "series" | "volumes" | "series_detail"
    self.active_series = nil -- { seriesid = ..., series = ... }
    self.all_volumes = {}
    self.series_groups = {}
    self.kox_status = nil
    self.item_table = {}
    self.refresh_pending = false
    Menu.init(self)
    OpenWidgets.push(self)

    self.listener_key = tostring(self)
    DownloadQueue:subscribe(self.listener_key, function(_event_kind)
        if self.closed then
            return
        end
        self:scheduleRefresh()
    end)

    UIManager:nextTick(function() self:reload() end)
end

function KooboneBrowser:onCloseWidget()
    self.closed = true
    if self.listener_key then
        DownloadQueue:unsubscribe(self.listener_key)
    end
    Menu.onCloseWidget(self)
    OpenWidgets.remove(self)
end

function KooboneBrowser:scheduleRefresh()
    if self.refresh_pending then
        return
    end
    self.refresh_pending = true
    UIManager:scheduleIn(0.4, function()
        self.refresh_pending = false
        if not self.closed then
            self:rebuildUI()
        end
    end)
end

function KooboneBrowser:resolveKoxPath()
    if self.source_path and self.source_path ~= "" then
        return self.source_path
    end
    if self.sources_dir then
        local found = InstalledSources.findByKey(self.sources_dir, self.engine, "kox")
        if found and found.path then
            self.source_path = found.path
            return found.path
        end
    end
    return ""
end

function KooboneBrowser:groupVolumesBySeries(vols)
    local groups = {}
    local by_key = {}
    for _idx, v in ipairs(vols) do
        if type(v) == "table" then
            local mkey = (type(v.manga_key) == "string" and v.manga_key ~= "") and v.manga_key or "koob:uploads"
            local mtitle = (type(v.manga_title) == "string" and v.manga_title ~= "") and v.manga_title
                or (type(v.vol_series) == "string" and v.vol_series ~= "" and v.vol_series)
                or _("Standalone Volumes")
            local g = by_key[mkey]
            if not g then
                g = {
                    manga_key = mkey,
                    title = mtitle,
                    series_id = v.vol_seriesid or "",
                    series_name = v.vol_series or "",
                    cover_url = v.cover_url,
                    volumes = {},
                    total_bytes = 0,
                }
                by_key[mkey] = g
                table.insert(groups, g)
            end
            table.insert(g.volumes, v)
            g.total_bytes = g.total_bytes + (tonumber(v.file_size) or 0)
        end
    end
    return groups
end

function KooboneBrowser:reload()
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            self:resolveKoxPath()
            local st = self.engine:koxStatus(true)
            if type(st) == "table" then
                self.kox_status = st
            end

            local res, err = self.engine:kooboneAllVolumes("", "", false, false)
            if not res or type(res.data) ~= "table" then
                self.all_volumes = {}
                self.series_groups = {}
                self:rebuildUI(err)
                return
            end

            self.all_volumes = res.data
            self.series_groups = self:groupVolumesBySeries(self.all_volumes)

            -- If auto-sync is enabled, automatically enqueue any new volumes right away!
            if self.store and self.store:kooboneAutoSync() and not self.store:isEphemeralMode() and #self.all_volumes > 0 then
                local sync_stats = KooboneSync.processVolumes(self.all_volumes, {
                    engine = self.engine,
                    store = self.store,
                    downloads_engine = self.downloads_engine,
                    sources_dir = self.sources_dir,
                    downloads_dir = self.downloads_dir,
                    source_path = self.source_path,
                })
                if sync_stats.newly_queued > 0 and self.refresh_callback then
                    self.refresh_callback()
                end
            end

            self:rebuildUI()
        end)
    end)
end

function KooboneBrowser:countOfflineStats(vols)
    local dl_count, queued_count = 0, 0
    for _idx, v in ipairs(vols) do
        local is_dl = KooboneSync.isVolumeDownloaded(self.downloads_engine, v)
        if is_dl then
            dl_count = dl_count + 1
        else
            local ckey = (type(v.chapter_key) == "string" and v.chapter_key ~= "") and v.chapter_key or ("koobvol:" .. tostring(v.file_md5 or ""))
            local task = DownloadQueue:getChapterTask("kox", v.manga_key or "", ckey)
            if task and (task.status == "downloading" or task.status == "queued") then
                queued_count = queued_count + 1
            end
        end
    end
    return dl_count, queued_count
end

function KooboneBrowser:computeSubtitle()
    local total = #self.all_volumes
    local dl, queued = self:countOfflineStats(self.all_volumes)
    local parts = {}
    if total > 0 then
        table.insert(parts, T(_("%1/%2 offline"), dl, total))
    end
    if queued > 0 then
        table.insert(parts, T(_("Syncing %1"), queued))
    end
    local auto_on = (not self.store) or self.store:kooboneAutoSync()
    table.insert(parts, auto_on and _("Auto-sync: On") or _("Auto-sync: Off"))
    return table.concat(parts, " · ")
end

function KooboneBrowser:buildVolumeRow(v)
    local is_dl, local_path = KooboneSync.isVolumeDownloaded(self.downloads_engine, v)
    local ckey = (type(v.chapter_key) == "string" and v.chapter_key ~= "") and v.chapter_key or ("koobvol:" .. tostring(v.file_md5 or ""))
    local task = DownloadQueue:getChapterTask("kox", v.manga_key or "", ckey)

    local prefix = ""
    local right_parts = {}
    if tonumber(v.file_size) and tonumber(v.file_size) > 0 then
        table.insert(right_parts, formatBytes(v.file_size))
    end
    if tonumber(v.count_page) and tonumber(v.count_page) > 0 then
        table.insert(right_parts, T(_("%1p"), tonumber(v.count_page)))
    end

    if is_dl and not (task and task.status == "downloading") then
        prefix = "✓ "
        if self.store and self.store:isChapterRead("kox", v.manga_key or "", ckey) then
            table.insert(right_parts, _("Read"))
        else
            table.insert(right_parts, _("Offline ✓"))
        end
    elseif task then
        if task.status == "downloading" then
            prefix = "▶ "
            if task.total_pages and task.total_pages > 0 then
                table.insert(right_parts, string.format("%d/%d", task.current_page, task.total_pages))
            else
                table.insert(right_parts, _("DL…"))
            end
        elseif task.status == "queued" then
            prefix = "[…] "
            table.insert(right_parts, _("Queued"))
        elseif task.status == "failed" then
            prefix = "✗ "
            table.insert(right_parts, _("Failed"))
        end
    end

    local display_name
    if self.view_mode == "series_detail" then
        display_name = (type(v.chapter_title) == "string" and v.chapter_title ~= "") and v.chapter_title or tostring(v.vol_name or "")
    else
        display_name = tostring(v.vol_name or v.chapter_title or "")
    end

    return {
        text = prefix .. display_name,
        mandatory = table.concat(right_parts, " · "),
        koobone_vol = v,
        local_path = local_path,
    }
end

function KooboneBrowser:rebuildUI(load_err)
    local items = {}

    if self.title_bar then
        if self.view_mode == "series_detail" and self.active_series then
            self.title_bar:setTitle(self.active_series.title)
        else
            self.title_bar:setTitle(_("Koobone Bookshelf"))
        end
        self.title_bar:setSubTitle(self:computeSubtitle(), true)
    else
        self.subtitle = self:computeSubtitle()
    end

    if load_err then
        table.insert(items, {
            text = _("Log in to Kox.moe / Koobone…"),
            mandatory = ">",
            bold = true,
            is_login_row = true,
        })
        table.insert(items, {
            text = T(_("Could not load Koobone bookshelf: %1"), tostring(load_err)),
            dim = true,
            is_placeholder = true,
        })
        self.item_table = items
        self:updateItems(1)
        return
    end

    if self.view_mode == "series_detail" and self.active_series then
        local g = self.active_series
        local dl, queued = self:countOfflineStats(g.volumes)
        table.insert(items, {
            text = _("« Back to all Koobone series"),
            mandatory = T(_("%1 vol"), #g.volumes),
            bold = true,
            is_back_to_series = true,
        })
        if dl < #g.volumes and not (self.store and self.store:isEphemeralMode()) then
            table.insert(items, {
                text = queued > 0
                    and T(_("▶ Syncing %1 volume(s) to local…"), queued)
                    or T(_("» Offline download remaining %1 volume(s)"), #g.volumes - dl),
                mandatory = _("Sync >"),
                bold = true,
                series_sync_group = g,
            })
        end
        -- Show volumes in chronological reading order (oldest/vol 1 first)
        for i = #g.volumes, 1, -1 do
            table.insert(items, self:buildVolumeRow(g.volumes[i]))
        end
    elseif #self.all_volumes == 0 then
        table.insert(items, {
            text = _("Koobone bookshelf is empty. Push manga from kzo.moe / kox.moe to Koobone to auto-sync here."),
            dim = true,
            is_placeholder = true,
        })
        table.insert(items, {
            text = _("Refresh Koobone Bookshelf"),
            mandatory = "↻",
            is_refresh_row = true,
        })
    else
        local dl, queued = self:countOfflineStats(self.all_volumes)
        local remaining = #self.all_volumes - dl
        if remaining > 0 and not (self.store and self.store:isEphemeralMode()) then
            table.insert(items, {
                text = queued > 0
                    and T(_("▶ Syncing %1/%2 volume(s) to KOReader…"), queued, remaining)
                    or T(_("» Sync all %1 un-downloaded volume(s) to local"), remaining),
                mandatory = _("Offline Sync >"),
                bold = true,
                is_sync_all_row = true,
            })
        else
            table.insert(items, {
                text = T(_("✓ All %1 Koobone volume(s) are saved offline"), #self.all_volumes),
                mandatory = _("Refresh ↻"),
                bold = true,
                is_refresh_row = true,
            })
        end

        if self.view_mode == "series" then
            for _idx, g in ipairs(self.series_groups) do
                local g_dl, g_q = self:countOfflineStats(g.volumes)
                local prefix = ""
                local right_str
                if g_q > 0 then
                    prefix = "▶ "
                    right_str = T(_("DL %1 · %2/%3 vol"), g_q, g_dl, #g.volumes)
                elseif g_dl >= #g.volumes then
                    prefix = "✓ "
                    right_str = T(_("All %1 vol · %2"), #g.volumes, formatBytes(g.total_bytes))
                else
                    if g_dl > 0 then prefix = "✓ " end
                    right_str = T(_("%1/%2 vol · %3"), g_dl, #g.volumes, formatBytes(g.total_bytes))
                end
                table.insert(items, {
                    text = prefix .. g.title,
                    mandatory = right_str,
                    series_group = g,
                })
            end
        else
            for _idx, v in ipairs(self.all_volumes) do
                table.insert(items, self:buildVolumeRow(v))
            end
        end
    end

    local saved_page = self.page
    self.item_table = items
    self:updateItems(saved_page)
end

function KooboneBrowser:syncVolumesList(vols, label)
    if type(vols) ~= "table" or #vols == 0 then
        return
    end
    local stats = KooboneSync.processVolumes(vols, {
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        sources_dir = self.sources_dir,
        downloads_dir = self.downloads_dir,
        source_path = self:resolveKoxPath(),
    })
    if self.refresh_callback then
        self.refresh_callback()
    end
    self:rebuildUI()
    if stats.newly_queued == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All volumes are already downloaded or in the download queue."),
            timeout = 2,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Queued %1 volume(s) of '%2' from Koobone for offline reading."),
            stats.newly_queued, label or _("Koobone Bookshelf")),
        ok_text = _("Download Manager"),
        cancel_text = _("Stay Here"),
        ok_callback = function()
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
    })
end

function KooboneBrowser:promptLogin()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Log in to Kox.moe / Koobone"),
        fields = {
            { text = "", hint = _("Kmoe email address") },
            { text = "", text_type = "password", hint = _("Password") },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Log In"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local email = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local password = fields[2] or ""
                    UIManager:close(dialog)
                    if email == "" or password == "" then
                        return
                    end
                    Trapper:wrap(function()
                        local st, err = self.engine:koxLogin(email, password)
                        if not st then
                            UIManager:show(InfoMessage:new{ text = T(_("Login failed:\n%1"), err or "") })
                            return
                        end
                        self.kox_status = st
                        self:reload()
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KooboneBrowser:openOrDownloadVolume(vol, redownload)
    local is_dl, existing_path = KooboneSync.isVolumeDownloaded(self.downloads_engine, vol)
    if is_dl and not redownload and existing_path ~= "" and lfs.attributes(existing_path, "mode") == "file" then
        if self.store then
            self.store:markLastRead("kox", vol.manga_key or "")
        end
        UIManager:close(self)
        if self.ui.document then
            self.ui:switchDocument(existing_path)
        else
            self.ui:openFile(existing_path)
        end
        return
    end

    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local spec = KooboneSync.buildSpecFromVolume(vol, self:resolveKoxPath(), self.downloads_dir)
            if self.store and self.store:kooboneAutoBookmark() and spec.source_path ~= "" then
                if not self.store:isBookmarked("kox", spec.manga_key) then
                    self.store:addBookmark("kox", spec.source_path, spec.manga_key, spec.manga_title, vol.cover_url)
                end
            end
            local progress_prefix = T(_("Downloading %1"), spec.chapter_title)
            local path, err = self.engine:download(
                spec.source_path,
                spec.manga_key,
                spec.chapter_key,
                spec.out_path,
                self.downloads_dir,
                nil,
                progress_prefix,
                spec.manga_dir_name,
                redownload,
                nil,
                nil,
                vol
            )
            if not path then
                if err ~= _("Cancelled") then
                    UIManager:show(InfoMessage:new{ text = T(_("Download failed:\n%1"), err) })
                end
                return
            end
            if self.store and not self.store:isEphemeralMode() then
                self.downloads_engine:prune(self.store:downloadLimitBytes(), path)
            end
            if self.refresh_callback then
                self.refresh_callback()
            end
            if self.store then
                self.store:markLastRead("kox", spec.manga_key)
            end
            UIManager:close(self)
            if self.ui.document then
                self.ui:switchDocument(path)
            else
                self.ui:openFile(path)
            end
        end)
    end)
end

function KooboneBrowser:onLeftButtonTap()
    local auto_sync = (not self.store) or self.store:kooboneAutoSync()
    local auto_bm = (not self.store) or self.store:kooboneAutoBookmark()
    local qstats = DownloadQueue:getStats()

    local dialog
    local buttons = {
        {{
            text = _("Sync all Koobone books to local"),
            callback = function()
                UIManager:close(dialog)
                self:syncVolumesList(self.all_volumes, _("Koobone Bookshelf"))
            end,
        }},
        {{
            text = self.view_mode == "volumes"
                and _("View: Grouped by Series")
                or _("View: All Volumes (Latest pushed first)"),
            callback = function()
                UIManager:close(dialog)
                self.active_series = nil
                self.view_mode = (self.view_mode == "volumes") and "series" or "volumes"
                self.page = 1
                self:rebuildUI()
            end,
        }},
        {{
            text = (auto_sync and "✓ " or "") .. _("Auto-offline pushed books to KOReader"),
            callback = function()
                UIManager:close(dialog)
                if self.store then
                    self.store:setKooboneAutoSync(not auto_sync)
                end
                self:rebuildUI()
            end,
        }},
        {{
            text = (auto_bm and "✓ " or "") .. _("Auto-add synced series to Library"),
            callback = function()
                UIManager:close(dialog)
                if self.store then
                    self.store:setKooboneAutoBookmark(not auto_bm)
                end
                self:rebuildUI()
            end,
        }},
        {{
            text = qstats.pending > 0
                and T(_("Download Manager (%1 active)"), qstats.pending)
                or _("Download Manager"),
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
        }},
        {{
            text = _("Kox.moe Account & Settings…"),
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
                    source_path = self:resolveKoxPath(),
                    source_key = "kox",
                    source_text = "Kox.moe",
                    is_popout = false,
                    is_borderless = true,
                    title_bar_fm_style = true,
                    refresh_callback = function() self:reload() end,
                })
            end,
        }},
        {{
            text = _("Refresh Koobone Bookshelf"),
            callback = function()
                UIManager:close(dialog)
                self:reload()
            end,
        }},
    }

    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function() return self.title_bar.left_button.image.dimen end,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function KooboneBrowser:onMenuSelect(item)
    if item.is_placeholder then
        return true
    end
    if item.is_login_row then
        self:promptLogin()
        return true
    elseif item.is_refresh_row then
        self:reload()
        return true
    elseif item.is_back_to_series then
        self.active_series = nil
        self.view_mode = "series"
        self.page = 1
        self:rebuildUI()
        return true
    elseif item.is_sync_all_row then
        self:syncVolumesList(self.all_volumes, _("Koobone Bookshelf"))
        return true
    elseif item.series_sync_group then
        self:syncVolumesList(item.series_sync_group.volumes, item.series_sync_group.title)
        return true
    elseif item.series_group then
        self.active_series = item.series_group
        self.view_mode = "series_detail"
        self.page = 1
        self:rebuildUI()
        return true
    elseif item.koobone_vol then
        self:openOrDownloadVolume(item.koobone_vol, false)
        return true
    end
    return true
end

function KooboneBrowser:onMenuHold(item)
    if item.is_placeholder then
        return true
    end
    if item.series_group then
        local g = item.series_group
        local dialog
        local buttons = {
            {{
                text = _("View volumes in Koobone"),
                callback = function()
                    UIManager:close(dialog)
                    self.active_series = g
                    self.view_mode = "series_detail"
                    self.page = 1
                    self:rebuildUI()
                end,
            }},
            {{
                text = _("Offline download all volumes"),
                callback = function()
                    UIManager:close(dialog)
                    self:syncVolumesList(g.volumes, g.title)
                end,
            }},
        }
        if not g.manga_key:match("^koob:") then
            table.insert(buttons, {{
                text = _("Open full manga page on Kox.moe"),
                callback = function()
                    UIManager:close(dialog)
                    local kox_path = self:resolveKoxPath()
                    if kox_path == "" then
                        return
                    end
                    local MangaBrowser = require("mangabrowser")
                    UIManager:show(MangaBrowser:new{
                        engine = self.engine,
                        store = self.store,
                        downloads_engine = self.downloads_engine,
                        ui = self.ui,
                        sources_dir = self.sources_dir,
                        source_path = kox_path,
                        source_key = "kox",
                        source_name = "Kox.moe",
                        downloads_dir = self.downloads_dir,
                        manga = { Key = g.manga_key, Title = g.title, Cover = g.cover_url },
                        is_popout = false,
                        is_borderless = true,
                        title_bar_fm_style = true,
                        refresh_callback = self.refresh_callback,
                    })
                end,
            }})
        end
        dialog = ButtonDialog:new{
            title = g.title,
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    if item.koobone_vol then
        local v = item.koobone_vol
        local is_dl = KooboneSync.isVolumeDownloaded(self.downloads_engine, v)
        local dialog
        local buttons = {
            {{
                text = is_dl and _("Read now") or _("Download & Read now"),
                callback = function()
                    UIManager:close(dialog)
                    self:openOrDownloadVolume(v, false)
                end,
            }},
        }
        if not is_dl then
            table.insert(buttons, {{
                text = _("Offline download in background"),
                callback = function()
                    UIManager:close(dialog)
                    self:syncVolumesList({ v }, v.vol_name)
                end,
            }})
        else
            table.insert(buttons, {{
                text = _("Re-download volume"),
                callback = function()
                    UIManager:close(dialog)
                    self:openOrDownloadVolume(v, true)
                end,
            }})
            table.insert(buttons, {{
                text = _("Remove local offline file"),
                callback = function()
                    UIManager:close(dialog)
                    local ckey = (type(v.chapter_key) == "string" and v.chapter_key ~= "") and v.chapter_key or ("koobvol:" .. tostring(v.file_md5 or ""))
                    self.downloads_engine:remove("kox", v.manga_key or "", ckey)
                    if self.refresh_callback then
                        self.refresh_callback()
                    end
                    self:rebuildUI()
                end,
            }})
        end
        dialog = ButtonDialog:new{
            title = v.vol_name or v.chapter_title or "",
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    return true
end

return KooboneBrowser
