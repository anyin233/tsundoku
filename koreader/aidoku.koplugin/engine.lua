--[[--
Engine wraps the bundled aidoku-run binary: it shells out to it for every
call (see cmd/aidoku-run/main.go in the parent repo for the command surface)
and decodes its JSON stdout into Lua tables. See subprocess.lua for the
underlying "shell out and decode JSON" mechanics and its important note
about Trapper:wrap().
]]

local Runner = require("subprocess")
local json = require("json")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local function invalidateDownloadsCache(downloads_dir)
    local ok_de, DownloadsEngine = pcall(require, "downloadsengine")
    if ok_de and DownloadsEngine and type(DownloadsEngine.invalidateCache) == "function" then
        DownloadsEngine.invalidateCache(downloads_dir)
    end
end

local Engine = {}
Engine.__index = Engine

function Engine.new(bin_path, env_fn)
    return setmetatable({
        runner = Runner.new(bin_path),
        env_fn = env_fn,
    }, Engine)
end

function Engine:isAvailable()
    return self.runner:isAvailable()
end

function Engine:sourceEnv()
    if self.env_fn then
        return self.env_fn()
    end
    return nil
end

function Engine:repoList(index_url)
    return self.runner:execJSON({ "-", "repo", "list", index_url }, _("Fetching repository…"))
end

function Engine:repoInstall(index_url, source_id, dest_dir)
    return self.runner:exec({ "-", "repo", "install", index_url, source_id, dest_dir }, _("Installing…"))
end

function Engine:cookieLoad(cookies_path)
    return self.runner:exec({ "-", "cookie", "load", cookies_path }, _("Loading cookies…"), self:sourceEnv())
end

function Engine:cookieClear()
    return self.runner:exec({ "-", "cookie", "clear" }, nil, self:sourceEnv())
end

function Engine:checkUpdate(bin_arch, current_version)
    return self.runner:execJSON({ "-", "update", "check", bin_arch, current_version }, _("Checking for updates…"))
end

function Engine:selfUpdate(plugin_dir, asset_url)
    return self.runner:execJSON({ "-", "update", "apply", plugin_dir, asset_url }, _("Downloading update…"))
end

function Engine:info(source_path)
    return self.runner:execJSON({ source_path, "info" }, _("Loading source…"), self:sourceEnv())
end

function Engine:manifest(source_path)
    return self.runner:execJSON({ source_path, "manifest" }, nil)
end

-- manifests reads source.json from every .aix in sources_dir in a single
-- process invocation -- turns 20+ subprocess spawns into 1 (~35ms on Kindle).
function Engine:manifests(sources_dir)
    return self.runner:execJSON({ "-", "manifests", sources_dir }, nil)
end

local function encodeFilterValues(filter_values)
    local sanitized = {}
    for i, v in ipairs(filter_values) do
        local copy = {}
        for k, val in pairs(v) do
            if not ((k == "included" or k == "excluded") and type(val) == "table" and #val == 0) then
                copy[k] = val
            end
        end
        sanitized[i] = copy
    end
    return json.encode(sanitized)
end

-- Strip KOReader json's null-sentinel functions recursively before re-encoding
-- Manga/Chapter tables back to JSON for aidoku-run's download-payload command.
local function sanitizeForJSON(val)
    local t = type(val)
    if t == "function" or t == "userdata" or t == "thread" then
        return nil
    end
    if t ~= "table" then
        return val
    end
    local out = {}
    for k, v in pairs(val) do
        local cleaned = sanitizeForJSON(v)
        if cleaned ~= nil then
            -- Drop empty arrays so KOReader's json.encode doesn't emit "{}"
            -- where Go expects a slice ([]string).
            if not (type(cleaned) == "table" and next(cleaned) == nil) then
                out[k] = cleaned
            end
        end
    end
    return out
end

function Engine:prepareSearchArgs(source_path, query, page, filter_values)
    local args = { source_path, "search", query or "", tostring(page or 1) }
    local cleanup
    if filter_values and #filter_values > 0 then
        local filters_path = Runner.makeTempPath("flt")
        local f = io.open(filters_path, "w")
        local ok = f and f:write(encodeFilterValues(filter_values))
        if f then
            ok = f:close() and ok
        end
        if not ok then
            os.remove(filters_path)
            return nil, nil, _("Could not write search filters")
        end
        table.insert(args, filters_path)
        cleanup = { filters_path }
    end
    return args, cleanup
end

function Engine:search(source_path, query, page, filter_values, progress_text)
    local args, cleanup, prep_err = self:prepareSearchArgs(source_path, query, page, filter_values)
    if not args then
        return nil, prep_err
    end
    local result, err = self.runner:execJSON(args, progress_text or _("Searching…"), self:sourceEnv())
    for _idx, p in ipairs(cleanup or {}) do
        os.remove(p)
    end
    return result, err
end

function Engine:spawnSearch(source_path, query, page, filter_values)
    local args, cleanup, prep_err = self:prepareSearchArgs(source_path, query, page, filter_values)
    if not args then
        return nil, prep_err
    end
    return self.runner:spawnAsync(args, self:sourceEnv(), false, cleanup)
end

function Engine:filters(source_path)
    return self.runner:execJSON({ source_path, "filters" }, _("Loading filters…"), self:sourceEnv())
end

function Engine:spawnFilters(source_path)
    return self.runner:spawnAsync({ source_path, "filters" }, self:sourceEnv(), true)
end

function Engine:settingsList(source_path)
    return self.runner:execJSON({ source_path, "settings" }, _("Loading settings…"), self:sourceEnv())
end

function Engine:settingsGet(source_path, key)
    local result, err = self.runner:execJSON({ source_path, "settings", "get", key }, nil, self:sourceEnv())
    if type(result) ~= "table" then
        return nil, err
    end
    if type(result.value) == "function" then
        return nil
    end
    return result.value
end

function Engine:settingsSet(source_path, key, setting_type, values)
    local args = { source_path, "settings", "set", key, setting_type }
    for _idx, v in ipairs(values) do
        table.insert(args, v)
    end
    return self.runner:exec(args, nil, self:sourceEnv())
end

function Engine:sourceLogin(source_path, key, username, password)
    return self.runner:execJSON({ source_path, "login", key, username, password }, _("Logging in…"), self:sourceEnv())
end

function Engine:sourceLogout(source_path, key, notification)
    local args = { source_path, "logout", key }
    if notification and notification ~= "" then
        table.insert(args, notification)
    end
    return self.runner:execJSON(args, _("Logging out…"), self:sourceEnv())
end

function Engine:sourceNotify(source_path, notification)
    return self.runner:execJSON({ source_path, "notify", notification }, _("Updating…"), self:sourceEnv())
end

function Engine:listings(source_path)
    return self.runner:execJSON({ source_path, "listings" }, _("Loading listings…"), self:sourceEnv())
end

function Engine:listingGet(source_path, listing_id, page, listing_name)
    return self.runner:execJSON({
        source_path, "listings", "get", listing_id, tostring(page or 1), listing_name or listing_id,
    }, _("Loading…"), self:sourceEnv())
end

function Engine:spawnListingGet(source_path, listing_id, page, listing_name)
    return self.runner:spawnAsync({
        source_path, "listings", "get", listing_id, tostring(page or 1), listing_name or listing_id,
    }, self:sourceEnv(), false)
end

-- ===== Native Kox.moe & Koobone Integration =====

function Engine:koxLogin(email, password)
    return self.runner:execJSON({ "-", "kox", "login", email, password }, _("Signing in to Kox.moe…"), self:sourceEnv())
end

function Engine:koxLogout()
    return self.runner:execJSON({ "-", "kox", "logout" }, _("Signing out…"), self:sourceEnv())
end

function Engine:koxStatus(cached_only)
    local args = { "-", "kox", "status" }
    if cached_only then
        table.insert(args, "cached")
    end
    return self.runner:execJSON(args, cached_only and nil or _("Refreshing account status…"), self:sourceEnv())
end

function Engine:koxPushKoobone(book_id, vol_ids_csv)
    return self.runner:execJSON(
        { "-", "kox", "push-koobone", tostring(book_id), tostring(vol_ids_csv) },
        _("Pushing to Koobone…"),
        self:sourceEnv()
    )
end

function Engine:kooboneSeries(page)
    return self.runner:execJSON({ "-", "koobone", "series", tostring(page or 1) }, _("Loading Koobone bookshelf…"), self:sourceEnv())
end

function Engine:kooboneVolumes(page, series_id, series_name, search_query, liked_only)
    return self.runner:execJSON({
        "-", "koobone", "vols",
        tostring(page or 1),
        series_id or "",
        series_name or "",
        search_query or "",
        liked_only and "1" or "0",
    }, _("Loading Koobone volumes…"), self:sourceEnv())
end

function Engine:kooboneAllVolumes(series_id, series_name, liked_only, silent)
    local args = {
        "-", "koobone", "all-vols",
        series_id or "",
        series_name or "",
        liked_only and "1" or "0",
    }
    if silent then
        local out, err = self.runner:exec(args, nil, self:sourceEnv(), true)
        if not out then
            return nil, err
        end
        local ok, decoded = pcall(json.decode, out)
        return ok and decoded or nil, not ok and tostring(decoded) or nil
    end
    return self.runner:execJSON(args, _("Syncing Koobone bookshelf…"), self:sourceEnv())
end

function Engine:spawnKooboneSyncCheck()
    return self.runner:spawnAsync({ "-", "koobone", "all-vols", "", "", "0" }, self:sourceEnv(), true)
end

function Engine:mangaUpdate(source_path, manga_key)
    return self.runner:execJSON({ source_path, "manga", manga_key }, _("Loading chapters…"), self:sourceEnv())
end

-- prepareDownloadArgs builds CLI args (and optional scratch payload file) for
-- downloading one chapter. When manga_obj and chapter_obj are provided, uses
-- `download-payload` so aidoku-run skips a redundant network GetMangaUpdate
-- call per chapter during batch downloads.
local function slimManga(manga_obj)
    if type(manga_obj) ~= "table" then
        return manga_obj
    end
    local slim = {}
    for k, v in pairs(manga_obj) do
        if k ~= "Chapters" then
            slim[k] = v
        end
    end
    return slim
end

local function writeJSONPayload(payload)
    local cleaned = sanitizeForJSON(payload)
    local ok_enc, encoded = pcall(json.encode, cleaned)
    if not ok_enc or not encoded then
        return nil, _("Could not encode request payload")
    end
    local payload_path = Runner.makeTempPath("payload")
    local f = io.open(payload_path, "w")
    local ok_write = f and f:write(encoded)
    if f then
        ok_write = f:close() and ok_write
    end
    if not ok_write then
        os.remove(payload_path)
        return nil, _("Could not write request payload")
    end
    return payload_path
end

function Engine:prepareDownloadArgs(source_path, manga_key, chapter_key, out_path, downloads_dir, manga_dir_name, redownload, manga_obj, chapter_obj, koobone_vol, canonical_keys)
    if type(koobone_vol) == "table" and koobone_vol.file_md5 and koobone_vol.file_md5 ~= "" then
        local payload_path = writeJSONPayload({
            volume = koobone_vol,
            sourcePath = source_path or "",
            outputPath = out_path or "",
            downloadsDir = downloads_dir or "",
            mangaDirName = manga_dir_name or "",
            redownload = redownload and true or false,
        })
        if payload_path then
            return { "-", "koobone", "download-payload", payload_path }, { payload_path }
        end
    end

    if type(manga_obj) == "table" and type(chapter_obj) == "table" and manga_obj.Key and chapter_obj.Key then
        local payload_path = writeJSONPayload({
            manga = slimManga(manga_obj),
            chapter = chapter_obj,
            canonicalKeys = type(canonical_keys) == "table" and canonical_keys or nil,
            outputPath = out_path or "",
            downloadsDir = downloads_dir or "",
            mangaDirName = manga_dir_name or "",
            redownload = redownload and true or false,
        })
        if payload_path then
            return { source_path, "download-payload", payload_path }, { payload_path }
        end
    end

    local args = { source_path, redownload and "redownload" or "download", manga_key, chapter_key, out_path }
    if downloads_dir or manga_dir_name then
        table.insert(args, downloads_dir or "")
    end
    if manga_dir_name then
        table.insert(args, manga_dir_name)
    end
    return args, nil
end

function Engine:download(source_path, manga_key, chapter_key, out_path, downloads_dir, silent, progress_text_override, manga_dir_name, redownload, manga_obj, chapter_obj, koobone_vol, canonical_keys)
    local progress_text = progress_text_override or _("Downloading chapter…")
    if silent then
        progress_text = nil
    end
    local args, cleanup = self:prepareDownloadArgs(
        source_path, manga_key, chapter_key, out_path, downloads_dir, manga_dir_name, redownload, manga_obj, chapter_obj, koobone_vol, canonical_keys)
    if silent then
        local out, err = self.runner:exec(args, nil, self:sourceEnv(), true)
        for _idx, p in ipairs(cleanup or {}) do
            os.remove(p)
        end
        if out then
            invalidateDownloadsCache(downloads_dir)
        end
        return out, err
    end
    local out, err = self.runner:execDownload(args, progress_text, self:sourceEnv(), false, cleanup)
    if out then
        invalidateDownloadsCache(downloads_dir)
    end
    return out, err
end

-- spawnDownload starts a non-blocking background download subprocess for
-- DownloadQueue and returns its pollable handle.
function Engine:spawnDownload(opts)
    local args, cleanup = self:prepareDownloadArgs(
        opts.source_path,
        opts.manga_key,
        opts.chapter_key,
        opts.out_path,
        opts.downloads_dir,
        opts.manga_dir_name,
        opts.redownload,
        opts.manga,
        opts.chapter,
        opts.koobone_vol,
        opts.canonical_keys
    )
    return self.runner:spawnAsync(args, self:sourceEnv(), true, cleanup)
end

function Engine:prepareBatchDownloadArgs(opts)
    local payload_path, err = writeJSONPayload({
        manga = slimManga(opts.manga),
        chapters = opts.chapters or {},
        canonicalKeys = type(opts.canonical_keys) == "table" and opts.canonical_keys or nil,
        outputPath = opts.out_path or "",
        downloadsDir = opts.downloads_dir or "",
        mangaDirName = opts.manga_dir_name or "",
        redownload = opts.redownload and true or false,
    })
    if not payload_path then
        return nil, nil, err
    end
    return { opts.source_path, "download-batch", payload_path }, { payload_path }
end

function Engine:batchDownload(opts)
    local args, cleanup, err = self:prepareBatchDownloadArgs(opts)
    if not args then
        return nil, err
    end
    if opts.silent then
        local out, exec_err = self.runner:exec(args, nil, self:sourceEnv(), true)
        for _idx, p in ipairs(cleanup or {}) do
            os.remove(p)
        end
        if out then
            invalidateDownloadsCache(opts.downloads_dir)
        end
        return out, exec_err
    end
    local progress_text = opts.progress_text or _("Downloading chapters…")
    local out, exec_err = self.runner:execDownload(args, progress_text, self:sourceEnv(), false, cleanup)
    if out then
        invalidateDownloadsCache(opts.downloads_dir)
    end
    return out, exec_err
end

local function buildSearchBatchSpecs(target_sources)
    local specs = {}
    for _idx, src in ipairs(target_sources or {}) do
        local spec = {
            key = src.key or "",
            name = src.name or src.text or src.key or "",
            path = src.path or "",
        }
        if type(src.filters) == "table" and #src.filters > 0 then
            spec.filters = src.filters
        end
        table.insert(specs, spec)
    end
    return specs
end

function Engine:searchBatch(target_sources, query, page)
    local specs = buildSearchBatchSpecs(target_sources)
    local payload_path, err = writeJSONPayload({
        query = query or "",
        page = page or 1,
        sources = specs,
    })
    if not payload_path then
        return nil, err
    end
    local total = #specs
    local first_name = specs[1] and specs[1].name or ""
    local initial_msg = total > 0
        and T(_("Searching (%1/%2): %3…"), 0, total, first_name)
        or _("Searching…")
    local out, exec_err = self.runner:execSearchBatch(
        { "-", "search-batch", payload_path },
        initial_msg,
        self:sourceEnv(),
        { payload_path }
    )
    if not out then
        return nil, exec_err
    end
    local ok_dec, decoded = pcall(json.decode, out)
    if not ok_dec or type(decoded) ~= "table" then
        return nil, _("Invalid response from aidoku-run")
    end
    return decoded
end

function Engine:spawnSearchBatch(target_sources, query, page, opts)
    local specs = buildSearchBatchSpecs(target_sources)
    local stream_path = Runner.makeTempPath("sbatch")
    local payload_path, err = writeJSONPayload({
        query = query or "",
        page = page or 1,
        workers = opts and opts.workers or 0,
        timeoutSec = opts and opts.timeout_sec or 0,
        streamPath = stream_path,
        sources = specs,
    })
    if not payload_path then
        os.remove(stream_path)
        return nil, err
    end
    return self.runner:spawnAsync(
        { "-", "search-batch", payload_path },
        self:sourceEnv(),
        false,
        { payload_path, stream_path },
        { stream_path = stream_path }
    )
end

function Engine:spawnBatchDownload(opts)
    local args, cleanup, err = self:prepareBatchDownloadArgs(opts)
    if not args then
        return nil, err
    end
    return self.runner:spawnAsync(args, self:sourceEnv(), true, cleanup)
end

-- Removes chapter_keys from a shared EPUB archive and repacks it via Go.
function Engine:epubRemove(opts)
    local payload_path, err = writeJSONPayload({
        epubPath = opts.epub_path or "",
        downloadsDir = opts.downloads_dir or "",
        sourceKey = opts.source_key or "",
        mangaKey = opts.manga_key or "",
        chapterKeys = opts.chapter_keys or {},
    })
    if not payload_path then
        return nil, err
    end
    local out, exec_err = self.runner:exec({ "-", "epub-remove", payload_path }, nil, nil, true)
    os.remove(payload_path)
    if not out then
        return nil, exec_err
    end
    local ok_dec, decoded = pcall(json.decode, out)
    if not ok_dec or type(decoded) ~= "table" then
        return nil, _("Could not decode epub-remove result")
    end
    return decoded
end

-- Splits a legacy single-book EPUB into fixed 50-chapter volumes via Go.
function Engine:epubSplit(opts)
    local payload_path, err = writeJSONPayload({
        epubPath = opts.epub_path or "",
        downloadsDir = opts.downloads_dir or "",
        sourceKey = opts.source_key or "",
        mangaKey = opts.manga_key or "",
        canonicalKeys = type(opts.canonical_keys) == "table" and opts.canonical_keys or nil,
        volumeSize = tonumber(opts.volume_size) or 0,
    })
    if not payload_path then
        return nil, err
    end
    local out, exec_err = self.runner:exec({ "-", "epub-split", payload_path }, nil, nil, true)
    os.remove(payload_path)
    if not out then
        return nil, exec_err
    end
    invalidateDownloadsCache(opts.downloads_dir)
    local ok_dec, decoded = pcall(json.decode, out)
    if not ok_dec or type(decoded) ~= "table" then
        return nil, _("Could not decode epub-split result")
    end
    return decoded
end

-- spawnCovers starts a non-blocking background cover batch subprocess for
-- CoverCache and returns its pollable handle.
function Engine:spawnCovers(payload)
    local payload_path, err = writeJSONPayload(payload)
    if not payload_path then
        return nil, err or _("Could not write cover request")
    end
    return self.runner:spawnAsync({ "-", "covers", payload_path }, self:sourceEnv(), true, { payload_path })
end

return Engine
