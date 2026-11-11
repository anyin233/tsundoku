--[[--
KooboneSync: Background & manual offline synchronization from Koobone's online
bookshelf (`koobone.com`) into Tsundoku / KOReader's local CBZ library.

Workflow:
1. User pushes manga volumes on `kzo.moe` / `kox.moe` to Koobone ("推到 KOOBONE").
2. KooboneSync queries Koobone's bookshelf (`koobone all-vols`), optionally
   bookmarks newly discovered series into Tsundoku's local `library.db` under
   source `kox`, and enqueues any un-downloaded volumes into `DownloadQueue`.
3. `DownloadQueue` runs `aidoku-run - koobone download-payload` in the
   background (`nice -n 19`), streaming each EPUB and converting it to a
   zero-overhead uncompressed `.cbz` with `ComicInfo.xml` registered in `index.db`.
]]

local DownloadQueue = require("downloadqueue")
local InstalledSources = require("installedsources")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local KooboneSync = {
    running_handle = nil,
    poll_scheduled = false,
    last_auto_sync_at = 0,
}

local AUTO_SYNC_COOLDOWN_SEC = 45

function KooboneSync.buildSpecFromVolume(vol, kox_source_path, downloads_dir)
    local manga_key = (type(vol.manga_key) == "string" and vol.manga_key ~= "") and vol.manga_key or "koob:uploads"
    local manga_title = (type(vol.manga_title) == "string" and vol.manga_title ~= "") and vol.manga_title
        or (type(vol.vol_series) == "string" and vol.vol_series ~= "" and vol.vol_series)
        or tostring(vol.vol_name or "Koobone")
    local chapter_key = (type(vol.chapter_key) == "string" and vol.chapter_key ~= "") and vol.chapter_key
        or ("koobvol:" .. tostring(vol.file_md5 or ""))
    local chapter_title = (type(vol.chapter_title) == "string" and vol.chapter_title ~= "") and vol.chapter_title
        or (type(vol.vol_snumber) == "string" and vol.vol_snumber ~= "" and vol.vol_snumber)
        or tostring(vol.vol_name or chapter_key)

    local safe_name = util.getSafeFilename(chapter_title .. ".cbz", downloads_dir)
    return {
        source_key = "kox",
        source_path = kox_source_path or "",
        source_name = "Kox.moe (Koobone)",
        manga_key = manga_key,
        manga_title = manga_title,
        chapter_key = chapter_key,
        chapter_title = chapter_title,
        koobone_vol = vol,
        out_path = downloads_dir .. "/" .. safe_name,
        downloads_dir = downloads_dir,
        manga_dir_name = manga_title .. " [kox]",
    }
end

function KooboneSync.isVolumeDownloaded(downloads_engine, vol)
    if not downloads_engine or type(vol) ~= "table" then
        return false, ""
    end
    local mkey = (type(vol.manga_key) == "string" and vol.manga_key ~= "") and vol.manga_key or ""
    local ckey = (type(vol.chapter_key) == "string" and vol.chapter_key ~= "") and vol.chapter_key
        or ("koobvol:" .. tostring(vol.file_md5 or ""))
    if mkey ~= "" then
        local p = downloads_engine:path("kox", mkey, ckey)
        if p ~= "" then
            return true, p
        end
    end
    return false, ""
end

-- processVolumes bookmarks series (if enabled) and queues un-downloaded volumes.
-- Returns { total = N, already_downloaded = D, newly_queued = Q, bookmarked = B }.
function KooboneSync.processVolumes(vols, ctx)
    local stats = { total = 0, already_downloaded = 0, newly_queued = 0, bookmarked = 0 }
    if type(vols) ~= "table" or #vols == 0 then
        return stats
    end

    local kox_src = ctx.sources_dir and InstalledSources.findByKey(ctx.sources_dir, ctx.engine, "kox") or nil
    local kox_path = (kox_src and kox_src.path) or ctx.source_path or ""
    local auto_bm = (not ctx.store) or ctx.store:kooboneAutoBookmark()

    local series_counts = {}
    local series_meta = {}
    local specs = {}

    -- Enqueue in ascending chronological/volume order (Koobone returns newest-added first, so iterate backwards)
    for i = #vols, 1, -1 do
        local v = vols[i]
        if type(v) == "table" and type(v.file_md5) == "string" and v.file_md5 ~= "" then
            stats.total = stats.total + 1
            local spec = KooboneSync.buildSpecFromVolume(v, kox_path, ctx.downloads_dir)

            series_counts[spec.manga_key] = (series_counts[spec.manga_key] or 0) + 1
            if not series_meta[spec.manga_key] then
                series_meta[spec.manga_key] = {
                    title = spec.manga_title,
                    cover = (type(v.cover_url) == "string" and v.cover_url ~= "") and v.cover_url or nil,
                }
            end

            local is_dl = KooboneSync.isVolumeDownloaded(ctx.downloads_engine, v)
            if is_dl then
                stats.already_downloaded = stats.already_downloaded + 1
            else
                table.insert(specs, spec)
            end
        end
    end

    if ctx.store then
        for mkey, count in pairs(series_counts) do
            local meta = series_meta[mkey]
            if auto_bm and kox_path ~= "" and not ctx.store:isBookmarked("kox", mkey) then
                if ctx.store:addBookmark("kox", kox_path, mkey, meta.title, meta.cover) then
                    stats.bookmarked = stats.bookmarked + 1
                end
            end
            ctx.store:recordMangaMeta("kox", mkey, mkey, count)
        end
    end

    if #specs > 0 then
        stats.newly_queued = DownloadQueue:enqueueBatch(specs, {
            engine = ctx.engine,
            store = ctx.store,
            downloads_engine = ctx.downloads_engine,
            downloads_dir = ctx.downloads_dir,
        })
    end

    return stats
end

-- maybeAutoSync runs a non-blocking background check of Koobone's bookshelf
-- when online, auto-sync is enabled, Ephemeral Mode is off, and a Kox account
-- is logged in. Never blocks UI rendering.
function KooboneSync:maybeAutoSync(ctx, on_complete)
    if not ctx or not ctx.engine or not ctx.store or not ctx.downloads_engine then
        return
    end
    if ctx.store:isEphemeralMode() or not ctx.store:kooboneAutoSync() then
        return
    end
    if not NetworkMgr:isConnected() then
        return
    end
    local now = os.time()
    if self.running_handle or (now - self.last_auto_sync_at) < AUTO_SYNC_COOLDOWN_SEC then
        return
    end

    -- Fast local check (~0ms if settings.json lacks kox login): avoid spawning
    -- network sync if the user hasn't configured a Kox account yet.
    local settings_json = ctx.settings_dir and (ctx.settings_dir .. "/settings.json") or nil
    if settings_json then
        if lfs.attributes(settings_json, "mode") ~= "file" then
            return
        end
        local f = io.open(settings_json, "r")
        if f then
            local content = f:read("*a") or ""
            f:close()
            if not content:find("kox.login.username", 1, true)
                and not content:find("kox.auth.cookie", 1, true)
                and not content:find("kox.koob.skey", 1, true)
            then
                return
            end
        end
    end

    self.last_auto_sync_at = now
    local handle = ctx.engine:spawnKooboneSyncCheck()
    if not handle then
        return
    end
    self.running_handle = handle
    self:pollHandle(ctx, on_complete)
end

function KooboneSync:pollHandle(ctx, on_complete)
    if self.poll_scheduled or not self.running_handle then
        return
    end
    self.poll_scheduled = true
    UIManager:scheduleIn(0.6, function()
        self.poll_scheduled = false
        local h = self.running_handle
        if not h then
            return
        end
        local state, stdout_text = h:poll()
        if state == "running" then
            self:pollHandle(ctx, on_complete)
            return
        end
        self.running_handle = nil
        if state == "done" and type(stdout_text) == "string" and stdout_text ~= "" then
            local json = require("json")
            local ok, decoded = pcall(json.decode, stdout_text)
            if ok and type(decoded) == "table" and type(decoded.data) == "table" then
                local stats = KooboneSync.processVolumes(decoded.data, ctx)
                if on_complete then
                    pcall(on_complete, stats)
                end
            end
        end
    end)
end

return KooboneSync
