--[[--
Engine wraps the bundled aidoku-run binary: it shells out to it for every
call (see cmd/aidoku-run/main.go in the parent repo for the command surface)
and decodes its JSON stdout into Lua tables. See subprocess.lua for the
underlying "shell out and decode JSON" mechanics and its important note
about Trapper:wrap().
]]

local Runner = require("subprocess")
local json = require("json")
local _ = require("aidoku_l10n")

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

function Engine:search(source_path, query, page, filter_values, progress_text)
    local args = { source_path, "search", query, tostring(page or 1) }
    local filters_path
    if filter_values and #filter_values > 0 then
        filters_path = os.tmpname()
        local f = io.open(filters_path, "w")
        local ok = f and f:write(encodeFilterValues(filter_values))
        if f then
            ok = f:close() and ok
        end
        if not ok then
            os.remove(filters_path)
            return nil, _("Could not write search filters")
        end
        table.insert(args, filters_path)
    end
    local result, err = self.runner:execJSON(args, progress_text or _("Searching…"), self:sourceEnv())
    if filters_path then
        os.remove(filters_path)
    end
    return result, err
end

function Engine:filters(source_path)
    return self.runner:execJSON({ source_path, "filters" }, _("Loading filters…"), self:sourceEnv())
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
function Engine:prepareDownloadArgs(source_path, manga_key, chapter_key, out_path, downloads_dir, manga_dir_name, redownload, manga_obj, chapter_obj, koobone_vol)
    if type(koobone_vol) == "table" and koobone_vol.file_md5 and koobone_vol.file_md5 ~= "" then
        local payload = sanitizeForJSON({
            volume = koobone_vol,
            sourcePath = source_path or "",
            outputPath = out_path or "",
            downloadsDir = downloads_dir or "",
            mangaDirName = manga_dir_name or "",
            redownload = redownload and true or false,
        })
        local ok_enc, encoded = pcall(json.encode, payload)
        if ok_enc and encoded then
            local payload_path = os.tmpname()
            local f = io.open(payload_path, "w")
            local ok_write = f and f:write(encoded)
            if f then
                ok_write = f:close() and ok_write
            end
            if ok_write then
                return { "-", "koobone", "download-payload", payload_path }, { payload_path }
            end
            os.remove(payload_path)
        end
    end

    if type(manga_obj) == "table" and type(chapter_obj) == "table" and manga_obj.Key and chapter_obj.Key then
        local manga_slim = {}
        for k, v in pairs(manga_obj) do
            if k ~= "Chapters" then
                manga_slim[k] = v
            end
        end
        local payload = sanitizeForJSON({
            manga = manga_slim,
            chapter = chapter_obj,
            outputPath = out_path or "",
            downloadsDir = downloads_dir or "",
            mangaDirName = manga_dir_name or "",
            redownload = redownload and true or false,
        })
        local ok_enc, encoded = pcall(json.encode, payload)
        if ok_enc and encoded then
            local payload_path = os.tmpname()
            local f = io.open(payload_path, "w")
            local ok_write = f and f:write(encoded)
            if f then
                ok_write = f:close() and ok_write
            end
            if ok_write then
                return { source_path, "download-payload", payload_path }, { payload_path }
            end
            os.remove(payload_path)
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

function Engine:download(source_path, manga_key, chapter_key, out_path, downloads_dir, silent, progress_text_override, manga_dir_name, redownload, manga_obj, chapter_obj, koobone_vol)
    local progress_text = progress_text_override or _("Downloading chapter…")
    if silent then
        progress_text = nil
    end
    local args, cleanup = self:prepareDownloadArgs(
        source_path, manga_key, chapter_key, out_path, downloads_dir, manga_dir_name, redownload, manga_obj, chapter_obj, koobone_vol)
    if silent then
        local out, err = self.runner:exec(args, nil, self:sourceEnv(), true)
        for _idx, p in ipairs(cleanup or {}) do
            os.remove(p)
        end
        return out, err
    end
    return self.runner:execDownload(args, progress_text, self:sourceEnv(), false, cleanup)
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
        opts.koobone_vol
    )
    return self.runner:spawnAsync(args, self:sourceEnv(), true, cleanup)
end

-- spawnCovers starts a non-blocking background cover batch subprocess for
-- CoverCache and returns its pollable handle.
function Engine:spawnCovers(payload)
    local cleaned = sanitizeForJSON(payload)
    local ok_enc, encoded = pcall(json.encode, cleaned)
    if not ok_enc or not encoded then
        return nil, _("Could not encode cover request")
    end
    local payload_path = os.tmpname()
    local f = io.open(payload_path, "w")
    local ok_write = f and f:write(encoded)
    if f then
        ok_write = f:close() and ok_write
    end
    if not ok_write then
        os.remove(payload_path)
        return nil, _("Could not write cover request")
    end
    return self.runner:spawnAsync({ "-", "covers", payload_path }, self:sourceEnv(), true, { payload_path })
end

return Engine
