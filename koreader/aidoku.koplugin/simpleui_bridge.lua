--[[--
SimpleUIBridge: Deep, self-contained integration between Tsundoku (積読) and
Simple UI (`simpleui.koplugin`) without modifying any file inside Simple UI.

Capabilities:
  1. Series Aggregation across SimpleUI Home Screen built-in modules
     (`Currently Reading`, `Recent Books`, `New Books`, `Cover Deck`):
     collapses scattered single-chapter `.cbz` files into their canonical manga
     series with official series covers, series/chapter progress, and configurable
     tap behavior (open series chapter browser offline-first, or resume directly).
  2. Home Screen Bento Modules (`sui_module_tsundoku.lua`):
     - `tsundoku_hub`: seeded once beside Clock (`clock` span 2 + `tsundoku_hub`
       span 4) for 1-tap Library, Global Search, and Koobone Refresh.
     - `tsundoku_series`: optional swipeable GroupCell series shelf, plus the
       `tsundoku` group source for SimpleUI Tabbed Grids.
  3. Quick Actions & Navigation Integration:
     - Registers 5 SimpleUI Quick Actions (`tsundoku_library`, `tsundoku_search`,
       `tsundoku_koobone_sync`, `tsundoku_koobone`, `tsundoku_downloads`) with
       monochrome SVG icons.
     - Registers `UI.BarInjection` for all `tsundoku_*` screens and sizes
       `Menu.init` to `UI.getContentHeight()` so lists, grids, and page footers
       fit cleanly between SimpleUI's top and bottom bars.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ChapterOrder = require("chapterorder")
local CoverCache = require("covercache")
local DataStorage = require("datastorage")
local Device = require("device")
local DownloadQueue = require("downloadqueue")
local DownloadsEngine = require("downloadsengine")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local InstalledSources = require("installedsources")
local KooboneSync = require("koobonesync")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local OpenWidgets = require("openwidgets")
local ReadHistory = require("readhistory")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local Screen = Device.screen

local SimpleUIBridge = {
    _initialized = false,
    _patched = false,
    _registered = false,
    _active = false,
    _aidoku_path = nil,
    _fm_host = nil,
    _latest_host = nil,
    _revision = 1,
    _index = nil,
    _index_fp = nil,
    _pending_cover_fetch = {},
    _crop_cache = {},
    _crop_order = {},
}

local MAX_CROP_CACHE = 32

-- Keep references to original SimpleUI functions so cleanup or passthrough works.
local Orig = {}

local function safeRequire(name)
    local ok, mod = pcall(require, name)
    if ok then
        return mod
    end
    return nil
end

local function isSimpleUIDisabled()
    local disabled = G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled["simpleui"] then
        return true
    end
    return false
end

local function copyFile(src, dst)
    if not src or not dst or src == dst then
        return false
    end
    local f_in = io.open(src, "rb")
    if not f_in then
        return false
    end
    local data = f_in:read("*a")
    f_in:close()
    if not data or data == "" then
        return false
    end
    local tmp = dst .. ".tmp"
    local f_out = io.open(tmp, "wb")
    if not f_out then
        return false
    end
    local ok = f_out:write(data)
    ok = f_out:close() and ok
    if ok and os.rename(tmp, dst) then
        return true
    end
    os.remove(tmp)
    return false
end

local function chapterEntrySortLess(a, b)
    local va, vb = tonumber(a.volumeNumber), tonumber(b.volumeNumber)
    if va and vb and va ~= vb then
        return va < vb
    end
    local ca, cb = tonumber(a.chapterNumber), tonumber(b.chapterNumber)
    if ca and cb and ca ~= cb then
        return ca < cb
    end
    local ta = tostring(a.chapterTitle or "")
    local tb = tostring(b.chapterTitle or "")
    if ta ~= tb then
        local cmp = ChapterOrder.naturalCompare(ta, tb)
        if cmp ~= 0 then
            return cmp < 0
        end
    end
    return (a.downloadedAt or 0) < (b.downloadedAt or 0)
end

local function chapterStem(fp)
    if type(fp) ~= "string" then
        return ""
    end
    return fp:match("([^/]+)%.[^%.]+$") or fp:match("([^/]+)$") or fp
end

local function findSeriesDiskCover(covers_dir, source_key, manga_key, dl_group, manga_dir)
    if covers_dir and covers_dir ~= "" then
        if source_key and source_key ~= "" and manga_key and manga_key ~= "" then
            local cc = CoverCache.diskPath(covers_dir, source_key, manga_key)
            if lfs.attributes(cc, "mode") == "file" then
                if manga_dir and lfs.attributes(manga_dir, "mode") == "directory" then
                    local folder_cov = manga_dir .. "/.cover.jpg"
                    if lfs.attributes(folder_cov, "mode") ~= "file" then
                        copyFile(cc, folder_cov)
                    end
                end
                return cc
            end
        end
        if dl_group and dl_group.sourceKey and dl_group.mangaKey then
            local cc2 = CoverCache.diskPath(covers_dir, dl_group.sourceKey, dl_group.mangaKey)
            if lfs.attributes(cc2, "mode") == "file" then
                if manga_dir and lfs.attributes(manga_dir, "mode") == "directory" then
                    local folder_cov = manga_dir .. "/.cover.jpg"
                    if lfs.attributes(folder_cov, "mode") ~= "file" then
                        copyFile(cc2, folder_cov)
                    end
                end
                return cc2
            end
        end
    end
    if manga_dir then
        local folder_cov = manga_dir .. "/.cover.jpg"
        if lfs.attributes(folder_cov, "mode") == "file" then
            return folder_cov
        end
    end
    return nil
end

local function makeCropKey(cover_path, w, h, align)
    return cover_path .. "\0" .. tostring(w) .. "x" .. tostring(h) .. (align or "")
end

local function putCropCache(key, bb)
    local cache = SimpleUIBridge._crop_cache
    local order = SimpleUIBridge._crop_order
    if not cache[key] then
        table.insert(order, key)
        if #order > MAX_CROP_CACHE then
            local oldest = table.remove(order, 1)
            cache[oldest] = nil -- Dereference only; ImageWidgets set image_disposable = false.
        end
    end
    cache[key] = bb
end

local function buildCroppedCoverBB(cover_path, w, h, align)
    local key = makeCropKey(cover_path, w, h, align)
    local cached = SimpleUIBridge._crop_cache[key]
    if cached then
        return cached
    end

    local raw_bb = RenderImage:renderImageFile(cover_path, false, nil, nil)
    if not raw_bb then
        return nil
    end

    local src_w, src_h = raw_bb:getWidth(), raw_bb:getHeight()
    if src_w <= 0 or src_h <= 0 then
        pcall(raw_bb.free, raw_bb)
        return nil
    end

    local scale = math.max(w / src_w, h / src_h)
    local scaled_w = math.max(w, math.floor(src_w * scale + 0.5))
    local scaled_h = math.max(h, math.floor(src_h * scale + 0.5))

    local ok_cp, work_bb = pcall(Blitbuffer.new, src_w, src_h, raw_bb:getType())
    if not (ok_cp and work_bb) then
        pcall(raw_bb.free, raw_bb)
        return nil
    end
    pcall(work_bb.blitFrom, work_bb, raw_bb, 0, 0, 0, 0, src_w, src_h)
    pcall(raw_bb.free, raw_bb)

    local ok_sc, scaled_bb = pcall(RenderImage.scaleBlitBuffer, RenderImage, work_bb, scaled_w, scaled_h)
    if scaled_bb ~= work_bb then
        pcall(work_bb.free, work_bb)
    end
    if not (ok_sc and scaled_bb) then
        return nil
    end

    local final_bb = scaled_bb
    if scaled_w ~= w or scaled_h ~= h then
        local ok_slot, slot_bb = pcall(Blitbuffer.new, w, h, scaled_bb:getType())
        if ok_slot and slot_bb then
            local src_x = align == "left" and 0
                or (align == "right" and (scaled_w - w) or math.floor((scaled_w - w) / 2))
            local src_y = math.floor((scaled_h - h) / 2)
            src_x = math.max(0, src_x)
            src_y = math.max(0, src_y)
            pcall(slot_bb.blitFrom, slot_bb, scaled_bb, 0, 0, src_x, src_y, w, h)
            pcall(scaled_bb.free, scaled_bb)
            final_bb = slot_bb
        end
    end

    putCropCache(key, final_bb)
    return final_bb
end

function SimpleUIBridge.isActive()
    return SimpleUIBridge._active == true
end

function SimpleUIBridge.getHost()
    local fm = FileManager and FileManager.instance
    if fm and fm.aidoku then
        return fm.aidoku
    end
    if SimpleUIBridge._fm_host and not SimpleUIBridge._fm_host.closed then
        return SimpleUIBridge._fm_host
    end
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_r and ReaderUI and ReaderUI.instance and ReaderUI.instance.aidoku then
        return ReaderUI.instance.aidoku
    end
    return SimpleUIBridge._latest_host
end

function SimpleUIBridge.iconPath(filename)
    local base = SimpleUIBridge._aidoku_path
    if not base or base == "" then
        return filename
    end
    return base .. "/icons/" .. filename
end

function SimpleUIBridge.invalidate()
    SimpleUIBridge._revision = SimpleUIBridge._revision + 1
    SimpleUIBridge._index = nil
    SimpleUIBridge._index_fp = nil
end

function SimpleUIBridge.refreshSimpleUIScreens(keep_cache)
    if not SimpleUIBridge._active then
        return
    end
    local ScreenEngine = safeRequire("engines/sui_screen_engine")
    if ScreenEngine and type(ScreenEngine.refreshAllLiveImmediate) == "function" then
        pcall(ScreenEngine.refreshAllLiveImmediate, keep_cache and true or false)
    end
end

function SimpleUIBridge.getSeriesTapMode()
    local host = SimpleUIBridge.getHost()
    if host and host.store then
        return host.store:suiSeriesTapMode()
    end
    return "series_view"
end

function SimpleUIBridge.setSeriesTapMode(mode)
    local host = SimpleUIBridge.getHost()
    if host and host.store then
        host.store:setSuiSeriesTapMode(mode)
    end
end

function SimpleUIBridge._buildIndex()
    local host = SimpleUIBridge.getHost()
    if not host or not host.store or not host.downloads_engine then
        return {
            list = {},
            by_key = {},
            by_fp = {},
            by_entry_fp = {},
        }
    end

    local downloads_dir = DownloadsEngine.normalizePath(host.downloads_dir or "")
    local covers_dir = host.covers_dir or ""
    local dl_entries = host.downloads_engine:list() or {}
    local dl_stats = host.downloads_engine:mangaDownloadStats(dl_entries)
    local meta_map = host.store:getMangaMetaMap() or {}
    local bookmarks = host.store:libraryEntries() or {}

    local SH = safeRequire("modules/module_books_shared")

    local hist_list = ReadHistory and ReadHistory.hist or {}
    local hist_info = {}
    for rank, hitem in ipairs(hist_list) do
        local nfp = DownloadsEngine.normalizePath(hitem.file or "")
        if nfp ~= "" and not hist_info[nfp] then
            hist_info[nfp] = { rank = rank, time = tonumber(hitem.time) or 0 }
        end
    end

    local list = {}
    local by_key = {}
    local by_fp = {}
    local by_entry_fp = {}
    local claimed_groups = {}

    local function registerSeriesPath(fp, series, entry)
        if type(fp) ~= "string" or fp == "" then
            return
        end
        local norm = DownloadsEngine.normalizePath(fp)
        local rel = DownloadsEngine.relativeDataPath(fp)
        by_fp[norm] = series
        if rel ~= "" and rel ~= norm then
            by_fp[rel] = series
        end
        if entry then
            by_entry_fp[norm] = entry
            if rel ~= "" and rel ~= norm then
                by_entry_fp[rel] = entry
            end
        end
    end

    local function attachSeriesData(s, entries)
        local sorted = {}
        local manga_dir
        for _idx, e in ipairs(entries or {}) do
            local nfp = DownloadsEngine.normalizePath(e.path or "")
            if nfp ~= "" and lfs.attributes(nfp, "mode") == "file" then
                e.path = nfp
                table.insert(sorted, e)
                if not manga_dir and DownloadsEngine.isUnder(nfp, downloads_dir) then
                    manga_dir = nfp:match("^(.*)/[^/]+$")
                end
            end
        end
        table.sort(sorted, chapterEntrySortLess)

        s.chapters = sorted
        s.all_paths = {}
        s.total_count = #sorted

        local read_count = 0
        local latest_hist_rank = nil
        local latest_hist_time = 0
        local latest_dl_at = s.added_at or 0
        local active_fp
        local active_entry

        local read_flags = {}
        for idx, e in ipairs(sorted) do
            table.insert(s.all_paths, e.path)
            registerSeriesPath(e.path, s, e)

            local is_read = host.store:isChapterRead(e.sourceKey, e.mangaKey, e.chapterKey)
            if not is_read and s.source_key ~= "" and s.manga_key ~= "" then
                is_read = host.store:isChapterRead(s.source_key, s.manga_key, e.chapterKey)
            end
            if not is_read and SH and Orig.isFinished then
                is_read = Orig.isFinished(e.path)
            end
            read_flags[idx] = is_read and true or false
            if is_read then
                read_count = read_count + 1
            end

            if (e.downloadedAt or 0) > latest_dl_at then
                latest_dl_at = e.downloadedAt
            end

            local hi = hist_info[e.path]
            if hi and (not latest_hist_rank or hi.rank < latest_hist_rank) then
                latest_hist_rank = hi.rank
                latest_hist_time = hi.time
                active_fp = e.path
                active_entry = e
            end
        end

        if not active_fp and #sorted > 0 then
            -- Default to first unread chapter if any, else newest downloaded.
            for idx, e in ipairs(sorted) do
                if not read_flags[idx] then
                    active_entry = e
                    active_fp = e.path
                    break
                end
            end
            if not active_fp then
                active_entry = sorted[#sorted]
                active_fp = active_entry.path
            end
        end

        -- Partial progress inside active chapter if it is not yet completed.
        local partial = 0
        if active_fp and SH and SH.sidecarData then
            local active_is_read = false
            for idx, e in ipairs(sorted) do
                if e.path == active_fp then
                    active_is_read = read_flags[idx]
                    break
                end
            end
            if not active_is_read then
                local sc = SH.sidecarData(active_fp, false)
                if sc and type(sc.percent) == "number" and sc.percent > 0 and sc.percent < 1 then
                    partial = sc.percent
                end
            end
        end

        local total = s.total_count
        if total > 0 then
            s.series_percent = math.min(1.0, math.max(0.0, (read_count + partial) / total))
        else
            s.series_percent = 0
        end

        s.read_count = read_count
        s.latest_hist_rank = latest_hist_rank
        s.latest_hist_time = latest_hist_time
        s.latest_activity = math.max(latest_hist_time or 0, latest_dl_at or 0, s.added_at or 0)
        s.active_fp = active_fp
        s.active_entry = active_entry
        if active_entry and type(active_entry.chapterTitle) == "string" and active_entry.chapterTitle ~= "" then
            s.active_chapter_label = active_entry.chapterTitle
        elseif active_fp then
            s.active_chapter_label = chapterStem(active_fp)
        else
            s.active_chapter_label = ""
        end

        if total > 1 then
            s.recent_label = string.format("%d/%d · %s", read_count, total, s.title)
        elseif total == 1 and s.series_percent > 0 and s.series_percent < 0.999 then
            s.recent_label = string.format("%d%% · %s", math.floor(s.series_percent * 100 + 0.5), s.title)
        else
            s.recent_label = s.title
        end

        s.manga_dir = manga_dir
        s.cover_disk_path = findSeriesDiskCover(covers_dir, s.source_key, s.manga_key, s.dl_group, manga_dir)
    end

    -- 1. All bookmarked series (unified with any local download group).
    for _idx, bm in ipairs(bookmarks) do
        local meta = meta_map[bm.source_key .. "\0" .. bm.manga_key]
        local canonical = meta and meta.canonical_key or nil
        local group = DownloadsEngine.lookupMangaGroup(dl_stats, bm.source_key, bm.manga_key, bm.title, canonical)
        if group then
            claimed_groups[group] = true
        end
        local key = (bm.source_key or "") .. "\t" .. (canonical or bm.manga_key or bm.title or "")
        if not by_key[key] then
            local title = (type(bm.title) == "string" and bm.title ~= "") and bm.title
                or (group and group.mangaTitle) or bm.manga_key or "?"
            local s = {
                key = key,
                source_key = bm.source_key or "",
                source_path = bm.source_path or "",
                manga_key = bm.manga_key or "",
                canonical_key = canonical,
                title = title,
                cover_url = type(bm.cover) == "string" and bm.cover or "",
                bookmarked = true,
                added_at = bm.added_at or 0,
                dl_group = group,
            }
            attachSeriesData(s, group and group.chapters or {})
            by_key[key] = s
            table.insert(list, s)
        end
    end

    -- 2. Downloaded series that aren't currently bookmarked.
    for _idx, group in ipairs(dl_stats.groups or {}) do
        if not claimed_groups[group] then
            local key = (group.sourceKey or "") .. "\t" .. (group.mangaKey or group.mangaTitle or "")
            if not by_key[key] then
                local s = {
                    key = key,
                    source_key = group.sourceKey or "",
                    source_path = group.sourcePath or "",
                    manga_key = group.mangaKey or "",
                    title = (type(group.mangaTitle) == "string" and group.mangaTitle ~= "")
                        and group.mangaTitle or group.mangaKey or "?",
                    cover_url = "",
                    bookmarked = false,
                    added_at = group.latestAt or 0,
                    dl_group = group,
                }
                attachSeriesData(s, group.chapters or {})
                by_key[key] = s
                table.insert(list, s)
            end
        end
    end

    -- 3. Fallback: unindexed `.cbz` files directly under `downloads_dir` present in ReadHistory.
    local unindexed_folders = {}
    for _idx, hitem in ipairs(hist_list) do
        local nfp = DownloadsEngine.normalizePath(hitem.file or "")
        if nfp ~= "" and DownloadsEngine.isUnder(nfp, downloads_dir) and not by_fp[nfp] then
            if lfs.attributes(nfp, "mode") == "file" then
                local folder = nfp:match("^(.*)/[^/]+$")
                if folder and folder ~= "" and folder ~= downloads_dir then
                    if not unindexed_folders[folder] then
                        local fname = folder:match("([^/]+)$") or folder
                        local clean_title = fname:gsub("%s*%[[^%]]+%]%s*$", "")
                        local src_tag = fname:match("%[([^%]]+)%]%s*$") or ""
                        unindexed_folders[folder] = {
                            folder = folder,
                            title = clean_title ~= "" and clean_title or fname,
                            source_key = src_tag,
                            entries = {},
                        }
                    end
                    table.insert(unindexed_folders[folder].entries, {
                        sourceKey = unindexed_folders[folder].source_key,
                        sourcePath = "",
                        mangaKey = folder,
                        chapterKey = nfp,
                        path = nfp,
                        mangaTitle = unindexed_folders[folder].title,
                        chapterTitle = chapterStem(nfp),
                        downloadedAt = tonumber(hitem.time) or 0,
                    })
                end
            end
        end
    end
    for folder, uf in pairs(unindexed_folders) do
        local key = "folder\t" .. folder
        local s = {
            key = key,
            source_key = uf.source_key,
            source_path = "",
            manga_key = "",
            title = uf.title,
            cover_url = "",
            bookmarked = false,
            added_at = 0,
        }
        attachSeriesData(s, uf.entries)
        by_key[key] = s
        table.insert(list, s)
    end

    table.sort(list, function(a, b)
        local ra, rb = a.latest_hist_rank, b.latest_hist_rank
        if ra and rb and ra ~= rb then
            return ra < rb
        elseif ra or rb then
            return ra ~= nil
        end
        if a.latest_activity ~= b.latest_activity then
            return a.latest_activity > b.latest_activity
        end
        return ChapterOrder.naturalCompare(a.title, b.title) < 0
    end)

    return {
        list = list,
        by_key = by_key,
        by_fp = by_fp,
        by_entry_fp = by_entry_fp,
    }
end

function SimpleUIBridge._ensureIndex()
    local host = SimpleUIBridge.getHost()
    local hist = ReadHistory and ReadHistory.hist or {}
    local top = hist[1]
    local dl_dir = (host and host.downloads_dir) or ""
    local rev = SimpleUIBridge._revision
    local n_hist = #hist
    local top_fp = top and top.file or ""
    local top_t = top and top.time or 0

    local fp = SimpleUIBridge._index_fp
    if SimpleUIBridge._index and fp
            and fp.rev == rev
            and fp.dl_dir == dl_dir
            and fp.n_hist == n_hist
            and fp.top_fp == top_fp
            and fp.top_t == top_t then
        return SimpleUIBridge._index
    end

    local idx = SimpleUIBridge._buildIndex()
    SimpleUIBridge._index = idx
    SimpleUIBridge._index_fp = {
        rev = rev,
        dl_dir = dl_dir,
        n_hist = n_hist,
        top_fp = top_fp,
        top_t = top_t,
    }
    return idx
end

function SimpleUIBridge.findSeriesByPath(filepath)
    if type(filepath) ~= "string" or filepath == "" then
        return nil
    end
    local idx = SimpleUIBridge._ensureIndex()
    return idx.by_fp[filepath] or idx.by_fp[DownloadsEngine.normalizePath(filepath)]
end

function SimpleUIBridge.getSummary()
    local host = SimpleUIBridge.getHost()
    local idx = SimpleUIBridge._ensureIndex()
    local qstats = DownloadQueue and DownloadQueue:getStats() or { pending = 0 }
    return {
        series_count = #(idx.list or {}),
        syncing = KooboneSync:isRunning(),
        queue_count = qstats.pending or 0,
        has_host = host ~= nil,
    }
end

function SimpleUIBridge.getSeriesKeyList()
    local idx = SimpleUIBridge._ensureIndex()
    local keys = {}
    for _idx, s in ipairs(idx.list or {}) do
        if #s.all_paths > 0 or s.cover_disk_path then
            table.insert(keys, s.key)
        end
    end
    return keys
end

function SimpleUIBridge.describeSeriesGroup(series_key)
    local idx = SimpleUIBridge._ensureIndex()
    local s = idx.by_key[series_key]
    if not s then
        return {
            name = "?",
            paths = {},
            count = 0,
            open = function() end,
        }
    end
    local paths = {}
    for i, fp in ipairs(s.all_paths or {}) do
        paths[i] = fp
    end
    if #paths == 0 and s.cover_disk_path then
        paths[1] = s.cover_disk_path
        idx.by_fp[s.cover_disk_path] = s
    end

    return {
        name = s.title,
        paths = paths,
        count = s.total_count > 0 and s.total_count or 1,
        cover_key = "tsundoku:" .. s.key,
        open = function()
            SimpleUIBridge.openSeries(s)
        end,
        extra_actions = function()
            local acts = {}
            if s.active_fp and lfs.attributes(s.active_fp, "mode") == "file" then
                table.insert(acts, {
                    text = _("Resume active chapter"),
                    sui_icon = "play",
                    callback = function(dialog)
                        if dialog and dialog.close then
                            pcall(dialog.close, dialog)
                        end
                        SimpleUIBridge.openFile(s.active_fp)
                    end,
                })
            end
            table.insert(acts, {
                text = _("Open series chapter list"),
                sui_icon = "library",
                callback = function(dialog)
                    if dialog and dialog.close then
                        pcall(dialog.close, dialog)
                    end
                    SimpleUIBridge.openSeries(s)
                end,
            })
            return acts
        end,
    }
end

function SimpleUIBridge._maybeFetchMissingCover(series)
    if not series or series.cover_disk_path or series.cover_url == "" then
        return
    end
    if series.source_key == "" or series.manga_key == "" then
        return
    end
    if SimpleUIBridge._pending_cover_fetch[series.key] then
        return
    end
    local host = SimpleUIBridge.getHost()
    if not host or not host.engine or not host.covers_dir or host.covers_dir == "" then
        return
    end
    SimpleUIBridge._pending_cover_fetch[series.key] = true

    UIManager:scheduleIn(0.15, function()
        local h = SimpleUIBridge.getHost()
        if not h or not h.engine then
            return
        end
        local source_path = series.source_path
        if (not source_path or source_path == "") and InstalledSources and series.source_key ~= "" then
            local found = InstalledSources.findByKey(h.sources_dir, h.engine, series.source_key)
            if found then
                source_path = found.path
            end
        end
        if not source_path or source_path == "" then
            return
        end
        CoverCache:requestBatch({{
            source_key = series.source_key,
            source_path = source_path,
            manga_key = series.manga_key,
            cover_url = series.cover_url,
            on_ready = function()
                local Config = safeRequire("infra/sui_config")
                if Config and Config.dropCoverCaches then
                    for _idx, fp in ipairs(series.all_paths or {}) do
                        Config.dropCoverCaches(fp)
                    end
                end
                SimpleUIBridge.invalidate()
                UIManager:nextTick(function()
                    SimpleUIBridge.refreshSimpleUIScreens(false)
                end)
            end,
        }}, {
            engine = h.engine,
            store = h.store,
            sources_dir = h.sources_dir,
            covers_dir = h.covers_dir,
        })
    end)
end

-- Helper to open a local file inside KOReader cleanly (marking from_tsundoku = false
-- unless already inside a Tsundoku browser, so closing returns to SimpleUI Home).
function SimpleUIBridge.openFile(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    if lfs.attributes(path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{ text = _("Chapter file not found on storage."), timeout = 2 })
        return false
    end
    local host = SimpleUIBridge.getHost()
    if not host or not host.ui then
        return false
    end
    require("pendinglibrary").from_tsundoku = false
    if host.ui.document then
        host.ui:switchDocument(path)
    else
        host.ui:openFile(path)
    end
    return true
end

function SimpleUIBridge.openSeries(series, opts)
    opts = opts or {}
    local host = SimpleUIBridge.getHost()
    if not host or not host.ui then
        return false
    end
    if type(series) == "string" then
        local idx = SimpleUIBridge._ensureIndex()
        series = idx.by_key[series] or SimpleUIBridge.findSeriesByPath(series)
    end
    if not series then
        return SimpleUIBridge.openLibrary()
    end

    if host.openSeriesObject then
        host:openSeriesObject(series, opts.offline_first ~= false)
        return true
    end
    return false
end

function SimpleUIBridge.openLibrary()
    local host = SimpleUIBridge.getHost()
    if host and host.onAidokuBrowseSources then
        host:onAidokuBrowseSources()
        return true
    end
    return false
end

function SimpleUIBridge.openSearch(prompt_immediately)
    local host = SimpleUIBridge.getHost()
    if host and host.onTsundokuSearch then
        host:onTsundokuSearch(prompt_immediately ~= false)
        return true
    end
    return false
end

function SimpleUIBridge.openKoobone()
    local host = SimpleUIBridge.getHost()
    if host and host.onTsundokuKoobone then
        host:onTsundokuKoobone()
        return true
    end
    return false
end

function SimpleUIBridge.syncKoobone(on_refresh)
    local host = SimpleUIBridge.getHost()
    if host and host.onTsundokuSyncKoobone then
        host:onTsundokuSyncKoobone(function(stats, err)
            SimpleUIBridge.invalidate()
            SimpleUIBridge.refreshSimpleUIScreens(false)
            if type(on_refresh) == "function" then
                pcall(on_refresh, stats, err)
            end
        end)
        return true
    end
    return false
end

function SimpleUIBridge.openDownloads()
    local host = SimpleUIBridge.getHost()
    if host and host.onTsundokuDownloads then
        host:onTsundokuDownloads()
        return true
    end
    return false
end

local function makeOpenWrapper(orig_open_fn)
    return function(fp, pos0, page)
        local series = SimpleUIBridge.findSeriesByPath(fp)
        if series and SimpleUIBridge.getSeriesTapMode() == "series_view" then
            if SimpleUIBridge.openSeries(series, { offline_first = true }) then
                return
            end
        elseif series then
            fp = series.active_fp or fp
        end
        if orig_open_fn then
            return orig_open_fn(fp, pos0, page)
        end
    end
end

local function wrapCtxOpenFn(ctx)
    if type(ctx) ~= "table" or ctx._tsundoku_open_wrapped or type(ctx.open_fn) ~= "function" then
        return ctx
    end
    local wrapped = {}
    setmetatable(wrapped, { __index = ctx })
    wrapped.open_fn = makeOpenWrapper(ctx.open_fn)
    wrapped._tsundoku_open_wrapped = true
    return wrapped
end

local function dedupeBookState(state, show_currently, show_recent, max_recent, exclude_current)
    if type(state) ~= "table" then
        return state
    end

    local seen_series = {}
    local cur_series = state.current_fp and SimpleUIBridge.findSeriesByPath(state.current_fp) or nil
    if cur_series then
        if cur_series.active_fp and lfs.attributes(cur_series.active_fp, "mode") == "file" then
            state.current_fp = cur_series.active_fp
            if not (state.prefetched_data and state.prefetched_data[state.current_fp]) then
                local SH = safeRequire("modules/module_books_shared")
                if SH and SH.sidecarData then
                    state.prefetched_data = state.prefetched_data or {}
                    state.prefetched_data[state.current_fp] = SH.sidecarData(state.current_fp, true) or false
                end
            end
        end
        if exclude_current and show_currently then
            seen_series[cur_series.key] = true
        end
    elseif state.current_fp and exclude_current and show_currently then
        seen_series["fp:" .. state.current_fp] = true
    end

    if not show_recent then
        return state
    end

    local deduped = {}
    local limit = max_recent or 5
    local SH = safeRequire("modules/module_books_shared")

    local function tryAppend(fp)
        if #deduped >= limit or type(fp) ~= "string" or fp == "" then
            return
        end
        local series = SimpleUIBridge.findSeriesByPath(fp)
        if series then
            if seen_series[series.key] then
                return
            end
            local canon_fp = series.active_fp or fp
            if lfs.attributes(canon_fp, "mode") ~= "file" then
                return
            end
            seen_series[series.key] = true
            table.insert(deduped, canon_fp)
            if state.prefetched_data and state.prefetched_data[canon_fp] == nil and SH and SH.sidecarData then
                state.prefetched_data[canon_fp] = SH.sidecarData(canon_fp, true) or false
            end
        else
            if seen_series["fp:" .. fp] or (exclude_current and show_currently and fp == state.current_fp) then
                return
            end
            if lfs.attributes(fp, "mode") ~= "file" then
                return
            end
            seen_series["fp:" .. fp] = true
            table.insert(deduped, fp)
            if state.prefetched_data and state.prefetched_data[fp] == nil and SH and SH.sidecarData then
                state.prefetched_data[fp] = SH.sidecarData(fp, true) or false
            end
        end
    end

    for _idx, fp in ipairs(state.recent_fps or {}) do
        tryAppend(fp)
        if #deduped >= limit then
            break
        end
    end

    -- Walk deeper into ReadHistory when many chapters of one series occupied top entries.
    if #deduped < limit and ReadHistory and type(ReadHistory.hist) == "table" then
        for _idx, hitem in ipairs(ReadHistory.hist) do
            tryAppend(hitem.file)
            if #deduped >= limit then
                break
            end
        end
    end

    state.recent_fps = deduped
    return state
end

function SimpleUIBridge._installPatches()
    if SimpleUIBridge._patched then
        return
    end
    SimpleUIBridge._patched = true

    local SH = safeRequire("modules/module_books_shared")
    local Config = safeRequire("infra/sui_config")
    local SUICoverCache = safeRequire("infra/sui_cover_cache")
    local Sources = safeRequire("engines/sui_book_sources")
    local GridRenderer = safeRequire("engines/sui_book_grid")
    local CoverDeck = safeRequire("modules/module_coverdeck")
    local UI = safeRequire("infra/sui_core")
    local SUISettings = safeRequire("infra/sui_store")

    -- Clear stale pre-upgrade single-chapter snapshot once per startup when present.
    if SUISettings and SUISettings.delSetting then
        SUISettings:delSetting("simpleui_stale_books_v1")
    end

    local _unpack = table.unpack or unpack
    local function safeHook(name, fn, fallback_fn)
        return function(...)
            local args = { n = select("#", ...), ... }
            local function handle(ok, ...)
                if ok then
                    return ...
                end
                local err = ...
                logger.warn("tsundoku simpleui_bridge:", name, "failed:", tostring(err))
                if fallback_fn then
                    return fallback_fn(_unpack(args, 1, args.n))
                end
            end
            return handle(pcall(fn, ...))
        end
    end

    -- 1. SH hooks for aggregated series in Currently Reading, Recent Books, CoverDeck, New Books
    if SH then
        Orig.isFinished = SH.isFinished
        Orig.prefetchBooks = SH.prefetchBooks
        Orig.getStaleBooks = SH.getStaleBooks
        Orig.getBookData = SH.getBookData
        Orig.getBookSeries = SH.getBookSeries

        if type(Orig.isFinished) == "function" then
            SH.isFinished = safeHook("SH.isFinished", function(fp, prefetched)
                local s = SimpleUIBridge.findSeriesByPath(fp)
                if s then
                    return s.total_count > 0 and s.read_count >= s.total_count and s.series_percent >= 0.999
                end
                return Orig.isFinished(fp, prefetched)
            end, Orig.isFinished)
        end

        if type(Orig.getStaleBooks) == "function" then
            SH.getStaleBooks = safeHook("SH.getStaleBooks", function()
                local stale = Orig.getStaleBooks()
                if not stale then
                    return nil
                end
                return dedupeBookState(stale, true, true, 15, true)
            end, Orig.getStaleBooks)
        end

        if type(Orig.prefetchBooks) == "function" then
            SH.prefetchBooks = safeHook("SH.prefetchBooks", function(show_currently, show_recent, max_recent, opts)
                local scan_n = show_recent and math.max((max_recent or 5) * 20, 150) or max_recent
                local state = Orig.prefetchBooks(show_currently, show_recent, scan_n, opts)
                local exclude_current = not (type(opts) == "table" and opts.exclude_current == false)
                return dedupeBookState(state, show_currently, show_recent, max_recent, exclude_current)
            end, Orig.prefetchBooks)
        end

        if type(Orig.getBookData) == "function" then
            SH.getBookData = safeHook("SH.getBookData", function(filepath, prefetched)
                local bd = Orig.getBookData(filepath, prefetched)
                local s = SimpleUIBridge.findSeriesByPath(filepath)
                if s and type(bd) == "table" then
                    bd.title = s.title
                    local ch_info = s.active_chapter_label or ""
                    if s.total_count > 1 then
                        local progress_tag = string.format("(%d/%d)", s.read_count, s.total_count)
                        ch_info = (ch_info ~= "" and (ch_info .. " " .. progress_tag)) or progress_tag
                    end
                    if type(bd.authors) == "string" and bd.authors ~= "" then
                        if ch_info ~= "" then
                            bd.authors = bd.authors .. " · " .. ch_info
                        end
                    else
                        bd.authors = ch_info
                    end
                    bd.percent = s.series_percent
                    if s.total_count > 1 then
                        bd.pages = s.total_count
                    end
                    bd.status = (s.total_count > 0 and s.read_count >= s.total_count and s.series_percent >= 0.999)
                        and "complete" or nil
                    bd._tsundoku_series = s
                    bd._tsundoku_recent_label = s.recent_label
                end
                return bd
            end, Orig.getBookData)
        end

        if type(Orig.getBookSeries) == "function" then
            SH.getBookSeries = safeHook("SH.getBookSeries", function(filepath)
                local s = SimpleUIBridge.findSeriesByPath(filepath)
                if s then
                    return {
                        series = T(_("%1/%2 ch"), s.read_count, math.max(1, s.total_count)),
                        series_index = nil,
                    }
                end
                return Orig.getBookSeries(filepath)
            end, Orig.getBookSeries)
        end
    end

    -- 2. Config cover hooks: serve official Tsundoku series covers into SUICoverCache
    if Config then
        Orig.getStretchedCoverBB = Config.getStretchedCoverBB
        Orig.getCroppedCoverBB = Config.getCroppedCoverBB

        if type(Orig.getStretchedCoverBB) == "function" and type(Config.stretchBBToSize) == "function" then
            Config.getStretchedCoverBB = safeHook("Config.getStretchedCoverBB", function(filepath, w, h)
                local s = SimpleUIBridge.findSeriesByPath(filepath)
                if s then
                    if s.cover_disk_path and lfs.attributes(s.cover_disk_path, "mode") == "file" and SUICoverCache then
                        local cached = SUICoverCache:get(filepath)
                        if cached and cached:getWidth() >= w and cached:getHeight() >= h then
                            return cached
                        end
                        local raw_bb = RenderImage:renderImageFile(s.cover_disk_path, false, nil, nil)
                        if raw_bb then
                            local stretched = Config.stretchBBToSize(raw_bb, w, h)
                            if stretched and stretched ~= raw_bb then
                                pcall(raw_bb.free, raw_bb)
                            end
                            if stretched then
                                return SUICoverCache:put(filepath, stretched)
                            end
                        end
                    elseif not s.cover_disk_path then
                        SimpleUIBridge._maybeFetchMissingCover(s)
                    end
                end
                return Orig.getStretchedCoverBB(filepath, w, h)
            end, Orig.getStretchedCoverBB)
        end

        if type(Orig.getCroppedCoverBB) == "function" then
            Config.getCroppedCoverBB = safeHook("Config.getCroppedCoverBB", function(filepath, w, h, align)
                local s = SimpleUIBridge.findSeriesByPath(filepath)
                if s then
                    if s.cover_disk_path and lfs.attributes(s.cover_disk_path, "mode") == "file" then
                        local cropped = buildCroppedCoverBB(s.cover_disk_path, w, h, align)
                        if cropped then
                            return cropped
                        end
                    elseif not s.cover_disk_path then
                        SimpleUIBridge._maybeFetchMissingCover(s)
                    end
                end
                return Orig.getCroppedCoverBB(filepath, w, h, align)
            end, Orig.getCroppedCoverBB)
        end
    end

    -- 3. Sources & GridRenderer hooks for recent/new_books deduplication, labels, and series tap
    if Sources then
        local recent_src = Sources.get("recent")
        if recent_src and not recent_src._tsundoku_wrapped then
            local orig_lbl = recent_src.labelForItem
            recent_src.labelForItem = function(bd)
                if type(bd) == "table" and bd._tsundoku_recent_label then
                    return bd._tsundoku_recent_label
                end
                return orig_lbl and orig_lbl(bd) or nil
            end
            recent_src._tsundoku_wrapped = true
        end

        local new_src = Sources.get("new_books")
        if new_src and new_src.getFileList and not new_src._tsundoku_wrapped then
            local orig_new_list = new_src.getFileList
            new_src.getFileList = safeHook("Sources.new_books.getFileList", function(ctx, params)
                local raw_fps = orig_new_list(ctx, params) or {}
                local out, seen = {}, {}
                for _idx, fp in ipairs(raw_fps) do
                    local s = SimpleUIBridge.findSeriesByPath(fp)
                    if s then
                        if not seen[s.key] then
                            seen[s.key] = true
                            table.insert(out, s.active_fp or fp)
                        end
                    else
                        table.insert(out, fp)
                    end
                end
                return out
            end, orig_new_list)
            new_src._tsundoku_wrapped = true
        end
    end

    if GridRenderer and GridRenderer.build then
        Orig.gridBuild = GridRenderer.build
        GridRenderer.build = safeHook("GridRenderer.build", function(w, ctx, opts)
            local use_opts = opts
            if type(opts) == "table" and opts.id == "recent" and not opts._tsundoku_wrapped then
                use_opts = {}
                for k, v in pairs(opts) do
                    use_opts[k] = v
                end
                local prev_lbl = opts.labelForItem
                use_opts.labelForItem = function(bd)
                    if type(bd) == "table" and bd._tsundoku_recent_label then
                        return bd._tsundoku_recent_label
                    end
                    return prev_lbl and prev_lbl(bd) or nil
                end
                use_opts._tsundoku_wrapped = true
            end
            return Orig.gridBuild(w, wrapCtxOpenFn(ctx), use_opts)
        end, Orig.gridBuild)
    end

    if CoverDeck and CoverDeck.build then
        Orig.coverDeckBuild = CoverDeck.build
        CoverDeck.build = safeHook("CoverDeck.build", function(w, ctx)
            return Orig.coverDeckBuild(w, wrapCtxOpenFn(ctx))
        end, Orig.coverDeckBuild)
    end

    -- 4. Menu.init height adjustment so full-screen Tsundoku menus size accurately
    --    for SimpleUI's top and bottom bars BEFORE item layout & page_info placement.
    Orig.menuInit = Menu.init
    Menu.init = function(menu_self, ...)
        pcall(function()
            if UI and type(menu_self.name) == "string" and menu_self.name:sub(1, 9) == "tsundoku_" then
                if menu_self.is_popout == false or menu_self.is_borderless == true then
                    menu_self.covers_fullscreen = true
                end
                local ok_h, content_h = pcall(UI.getContentHeight)
                if ok_h and type(content_h) == "number" and content_h > 0 and content_h < Screen:getHeight() then
                    menu_self.height = content_h
                end
            end
        end)
        return Orig.menuInit(menu_self, ...)
    end
end

function SimpleUIBridge._registerIntegrations()
    if SimpleUIBridge._registered then
        return
    end
    SimpleUIBridge._registered = true

    local Config = safeRequire("infra/sui_config")
    local Registry = safeRequire("modules/moduleregistry")
    local Sources = safeRequire("engines/sui_book_sources")
    local QA = safeRequire("features/sui_quickactions")
    local UI = safeRequire("infra/sui_core")
    local WindowHooks = safeRequire("infra/sui_window_hooks")

    -- 1. Register `tsundoku` Group Source for Tabbed Grid modules
    if Sources and Sources.register then
        pcall(Sources.register, {
            id = "tsundoku",
            label = function() return _.brandName() end,
            tab_label = function() return _.brandName() end,
            getFileList = function() return SimpleUIBridge.getSeriesKeyList() end,
            describe = function(series_key) return SimpleUIBridge.describeSeriesGroup(series_key) end,
            invalidate = function() SimpleUIBridge.invalidate() end,
        })
    end

    -- 2. Register `tsundoku_hub` and `tsundoku_series` Bento modules
    local sui_mod = safeRequire("sui_module_tsundoku")
    if Registry and type(Registry.register) == "function" and sui_mod and type(sui_mod.buildModules) == "function" then
        local ok_bm, hub_mod, series_mod = pcall(sui_mod.buildModules, SimpleUIBridge)
        if ok_bm then
            if hub_mod then
                pcall(Registry.register, hub_mod)
            end
            if series_mod then
                pcall(Registry.register, series_mod)
            end
        else
            logger.warn("tsundoku simpleui_bridge: buildModules failed:", tostring(hub_mod))
        end
    end

    -- 3. Register 5 Quick Actions (available for Quick Actions rows, Action List, Bottom Bar tabs)
    if QA and QA.register then
        local actions = {
            {
                id = "tsundoku_library",
                label = _.brandName() .. " · " .. _("Manga Library"),
                get_label = function() return _.brandName() end,
                icon = SimpleUIBridge.iconPath("tsundoku.svg"),
                execute = function() SimpleUIBridge.openLibrary() end,
            },
            {
                id = "tsundoku_search",
                label = _("Search Manga"),
                icon = SimpleUIBridge.iconPath("tsundoku_search.svg"),
                execute = function() SimpleUIBridge.openSearch(true) end,
            },
            {
                id = "tsundoku_koobone_sync",
                label = _("Refresh Koobone"),
                icon = SimpleUIBridge.iconPath("tsundoku_koobone.svg"),
                is_in_place = true,
                is_async_in_place = true,
                execute = function(ctx)
                    SimpleUIBridge.syncKoobone(function()
                        if ctx and ctx.refresh then
                            pcall(ctx.refresh)
                        end
                    end)
                end,
            },
            {
                id = "tsundoku_koobone",
                label = _("Koobone Shelf"),
                icon = SimpleUIBridge.iconPath("tsundoku_koobone.svg"),
                execute = function() SimpleUIBridge.openKoobone() end,
            },
            {
                id = "tsundoku_downloads",
                label = _("Manga Downloads"),
                icon = SimpleUIBridge.iconPath("tsundoku_downloads.svg"),
                execute = function() SimpleUIBridge.openDownloads() end,
            },
        }
        for _idx, act in ipairs(actions) do
            pcall(QA.register, act)
        end
        if Config and Config.invalidateTabsCache then
            pcall(Config.invalidateTabsCache)
        end
    end

    -- 4. Register BarInjection so SimpleUI Topbar + Navbar frame Tsundoku fullscreen menus
    if UI and UI.BarInjection and UI.BarInjection.register then
        pcall(UI.BarInjection.register, {
            id = "tsundoku_menus",
            match = function(widget)
                return type(widget.name) == "string" and widget.name:sub(1, 9) == "tsundoku_"
            end,
            get_active_action = function(widget)
                local wname = widget and widget.name or ""
                if wname == "tsundoku_search" then
                    return "tsundoku_search"
                elseif wname == "tsundoku_koobone" then
                    return "tsundoku_koobone"
                elseif wname:sub(1, 18) == "tsundoku_downloads" then
                    return "tsundoku_downloads"
                end
                return "tsundoku_library"
            end,
            is_pageable = true,
        })
    end

    -- 5. Keep SimpleUI Homescreen synchronized with DownloadQueue and Homescreen shows
    if DownloadQueue and DownloadQueue.subscribe then
        DownloadQueue:subscribe("tsundoku_simpleui_bridge", function(event_kind)
            if event_kind == "completed" or event_kind == "enqueued" then
                SimpleUIBridge.invalidate()
                if event_kind == "completed" then
                    UIManager:nextTick(function()
                        SimpleUIBridge.refreshSimpleUIScreens(false)
                    end)
                end
            end
        end)
    end

    if WindowHooks and WindowHooks.register and WindowHooks.POINT then
        pcall(WindowHooks.register, {
            id = "tsundoku_homescreen_sync",
            point = WindowHooks.POINT.SHOW,
            order = 5,
            match = function(widget)
                return widget and widget.name == "homescreen"
            end,
            before = function()
                OpenWidgets.closeAll()
                SimpleUIBridge.invalidate()
            end,
        })
    end
end

function SimpleUIBridge._seedHomeHubIfNeeded(store)
    if not store or store:suiHubSeeded() then
        return
    end
    local SUISettings = safeRequire("infra/sui_store")
    local Config = safeRequire("infra/sui_config")
    if not (SUISettings and Config) then
        return
    end

    -- Ensure the simpleui settings directory exists on disk before flushing.
    util.makePath(DataStorage:getSettingsDir() .. "/simpleui")

    SUISettings:saveSetting("simpleui_hs_tsundoku_hub_enabled", true)
    Config.setBentoSpan(2, "clock", "simpleui_hs_")
    Config.setBentoSpan(4, "tsundoku_hub", "simpleui_hs_")

    local function insertAfterClock(list)
        if type(list) ~= "table" then
            return nil, false
        end
        for _idx, id in ipairs(list) do
            if id == "tsundoku_hub" then
                return list, false
            end
        end
        local clock_pos
        for idx, id in ipairs(list) do
            if id == "clock" then
                clock_pos = idx
                break
            end
        end
        if clock_pos then
            table.insert(list, clock_pos + 1, "tsundoku_hub")
        else
            table.insert(list, 1, "tsundoku_hub")
        end
        return list, true
    end

    local layout = SUISettings:readSetting("simpleui_layout")
    if type(layout) == "table" and type(layout.pages) == "table" and layout.pages[1]
            and type(layout.pages[1].modules) == "table" then
        local _unused_l, changed = insertAfterClock(layout.pages[1].modules)
        if changed then
            SUISettings:saveSetting("simpleui_layout", layout)
        end
    end

    local order = SUISettings:readSetting("simpleui_hs_module_order")
    if type(order) == "table" then
        local _unused_o, changed = insertAfterClock(order)
        if changed then
            SUISettings:saveSetting("simpleui_hs_module_order", order)
        end
    end

    SUISettings:flush()
    store:setSuiHubSeeded(true)
end

function SimpleUIBridge.setup(aidoku)
    if not aidoku then
        return false
    end
    SimpleUIBridge._aidoku_path = aidoku.path
    SimpleUIBridge._latest_host = aidoku
    if not aidoku.document then
        SimpleUIBridge._fm_host = aidoku
    end
    SimpleUIBridge.invalidate()

    if isSimpleUIDisabled() then
        SimpleUIBridge._active = false
        return false
    end

    local Config = safeRequire("infra/sui_config")
    local SUISettings = safeRequire("infra/sui_store")
    if not Config or not SUISettings or not SUISettings:nilOrTrue("simpleui_enabled") then
        SimpleUIBridge._active = false
        return false
    end

    SimpleUIBridge._active = true
    SimpleUIBridge._installPatches()
    SimpleUIBridge._registerIntegrations()
    SimpleUIBridge._seedHomeHubIfNeeded(aidoku.store)
    SimpleUIBridge._initialized = true
    return true
end

return SimpleUIBridge
