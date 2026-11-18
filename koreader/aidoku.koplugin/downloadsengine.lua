--[[--
DownloadsEngine reads/writes <downloads_dir>/index.db directly via
lua-ljsqlite3. Also provides per-manga aggregated download statistics and
canonical/slug-prefix matching so downloaded manga are accurately annotated
across LibraryBrowser, SearchBrowser, GlobalSearchBrowser, and DownloadsBrowser.
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local EpubHelper = require("epubhelper")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("aidoku_l10n")

local DownloadsEngine = {}
DownloadsEngine.__index = DownloadsEngine

local _full_data_dir_cache = nil
local _cache_rev = 0
local _cache_by_dir = {}

function DownloadsEngine.invalidateCache(downloads_dir)
    _cache_rev = _cache_rev + 1
    if type(downloads_dir) == "string" and downloads_dir ~= "" then
        _cache_by_dir[DownloadsEngine.normalizePath(downloads_dir)] = nil
    else
        _cache_by_dir = {}
    end
end

local function dbStateToken(downloads_dir)
    if not downloads_dir or downloads_dir == "" then
        return tostring(_cache_rev)
    end
    local db_attr = lfs.attributes(downloads_dir .. "/index.db")
    local wal_attr = lfs.attributes(downloads_dir .. "/index.db-wal")
    return string.format("%d:%s:%s:%s:%s",
        _cache_rev,
        tostring(db_attr and db_attr.modification or 0),
        tostring(db_attr and db_attr.size or 0),
        tostring(wal_attr and wal_attr.modification or 0),
        tostring(wal_attr and wal_attr.size or 0))
end

-- buildExistingFilesSet verifies file existence in batches grouped by parent
-- directory (1 readdir per unique manga folder instead of 400+ FUSE stat() calls).
function DownloadsEngine.buildExistingFilesSet(items)
    local existing = {}
    local records = {}
    local dirs_needed = {}
    for _idx, item in ipairs(items or {}) do
        local raw_p = type(item) == "table" and item.path or item
        if type(raw_p) == "string" and raw_p ~= "" then
            local norm_p = DownloadsEngine.normalizePath(raw_p)
            local dir, name = norm_p:match("^(.*)/([^/]+)$")
            if name then
                if dir == "" then
                    dir = "/"
                end
                dirs_needed[dir] = true
            end
            table.insert(records, { raw = raw_p, norm = norm_p, dir = dir, name = name })
        end
    end

    local dir_entries = {}
    for dir in pairs(dirs_needed) do
        if lfs.attributes(dir, "mode") == "directory" then
            local map = {}
            local ok_dir, iter, dir_obj = pcall(lfs.dir, dir)
            if ok_dir and iter then
                for fname in iter, dir_obj do
                    if fname ~= "." and fname ~= ".." then
                        map[fname] = true
                    end
                end
            end
            dir_entries[dir] = map
        end
    end

    for _idx, rec in ipairs(records) do
        local found = false
        if rec.name then
            local d = rec.dir == "" and "/" or rec.dir
            local map = dir_entries[d]
            if map and map[rec.name] then
                found = true
            end
        elseif lfs.attributes(rec.norm, "mode") == "file" then
            found = true
        end
        if found then
            existing[rec.norm] = true
            existing[rec.raw] = true
        end
    end
    return existing
end

function DownloadsEngine.fullDataDir()
    if _full_data_dir_cache then
        return _full_data_dir_cache
    end
    local dir
    if type(DataStorage.getFullDataDir) == "function" then
        local ok, v = pcall(DataStorage.getFullDataDir, DataStorage)
        if ok and type(v) == "string" and v ~= "" then
            dir = v
        end
    end
    if not dir or dir == "" or dir == "." then
        local dd = DataStorage:getDataDir()
        if dd == "." or dd == "./" or dd == "" then
            dir = lfs.currentdir() or "."
        elseif dd:sub(1, 1) == "/" then
            dir = dd
        else
            local cwd = lfs.currentdir() or "."
            dir = cwd .. "/" .. dd:gsub("^%./", "")
        end
    end
    dir = dir:gsub("/+$", "")
    if dir == "" then
        dir = "/"
    end
    _full_data_dir_cache = dir
    return dir
end

function DownloadsEngine.normalizePath(p)
    if type(p) ~= "string" or p == "" then
        return ""
    end
    p = p:gsub("^%./", "")
    if p:sub(1, 1) ~= "/" then
        local base = DownloadsEngine.fullDataDir()
        if base == "/" then
            p = "/" .. p
        else
            p = base .. "/" .. p
        end
    end
    p = p:gsub("//+", "/")
    if #p > 1 then
        p = p:gsub("/+$", "")
    end
    return p
end

function DownloadsEngine.relativeDataPath(p)
    local norm = DownloadsEngine.normalizePath(p)
    if norm == "" then
        return ""
    end
    local base = DownloadsEngine.fullDataDir()
    if base ~= "/" and norm:sub(1, #base + 1) == base .. "/" then
        return norm:sub(#base + 2)
    end
    return ""
end

function DownloadsEngine.isUnder(file, dir)
    if type(file) ~= "string" or file == "" or type(dir) ~= "string" or dir == "" then
        return false
    end
    local nf = DownloadsEngine.normalizePath(file)
    local nd = DownloadsEngine.normalizePath(dir)
    return nf:sub(1, #nd + 1) == nd .. "/"
end

local BASE_COLUMNS = "source_key, source_path, manga_key, chapter_key, path, "
    .. "manga_title, chapter_title, size_bytes, downloaded_at, chapter_number, volume_number"

local function float32(v)
    v = tonumber(v)
    return v and tonumber(string.format("%.7g", v))
end

local function rowToEntry(row, has_date_uploaded, has_viewer)
    local idx = 12
    local date_uploaded = nil
    if has_date_uploaded then
        date_uploaded = row[idx] and tonumber(row[idx]) or nil
        idx = idx + 1
    end
    local viewer = 0
    if has_viewer then
        viewer = (row[idx] and tonumber(row[idx])) or 0
    end
    return {
        sourceKey = row[1],
        sourcePath = row[2],
        mangaKey = row[3],
        chapterKey = row[4],
        path = DownloadsEngine.normalizePath(row[5] or ""),
        mangaTitle = row[6],
        chapterTitle = row[7],
        sizeBytes = tonumber(row[8]) or 0,
        downloadedAt = tonumber(row[9]) or 0,
        chapterNumber = float32(row[10]),
        volumeNumber = float32(row[11]),
        dateUploaded = date_uploaded,
        viewer = viewer,
    }
end

local function purgeSidecar(path)
    local sidecar_dir = DocSettings:getSidecarDir(path)
    if sidecar_dir ~= "" and lfs.attributes(sidecar_dir, "mode") == "directory" then
        ffiUtil.purgeDir(sidecar_dir)
    end
end

local function query(conn, fallback, sql, binds, fn)
    local ok, stmt = pcall(conn.prepare, conn, sql)
    if not ok then
        return fallback
    end
    local ok_run, result = pcall(function()
        if binds then
            stmt:bind(unpack(binds))
        end
        return fn(stmt)
    end)
    pcall(stmt.close, stmt)
    if not ok_run then
        return fallback
    end
    return result
end

local function firstRow(stmt)
    return stmt:step()
end

function DownloadsEngine.new(downloads_dir, engine)
    downloads_dir = DownloadsEngine.normalizePath(downloads_dir)
    local self = setmetatable({
        downloads_dir = downloads_dir,
        engine = engine,
        conn = nil,
        has_date_uploaded = nil,
        has_viewer = nil,
        table_exists = false,
        path_index_ensured = false,
    }, DownloadsEngine)
    local ok, conn = pcall(SQ3.open, downloads_dir .. "/index.db")
    if ok and pcall(conn.set_busy_timeout, conn, 5000) then
        self.conn = conn
    end
    return self
end

function DownloadsEngine:stateToken()
    return dbStateToken(self.downloads_dir)
end

function DownloadsEngine:setEngine(engine)
    self.engine = engine
end

function DownloadsEngine:isAvailable()
    return self.conn ~= nil
end

function DownloadsEngine:tableExists()
    if self.table_exists then
        return true
    end
    if not self.conn then
        return false
    end
    local ok, count = pcall(self.conn.rowexec, self.conn,
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='downloads'")
    if ok and (tonumber(count) or 0) > 0 then
        self.table_exists = true
        return true
    end
    return false
end

function DownloadsEngine:ensurePathIndex()
    if self.path_index_ensured or not self.conn then
        return
    end
    self.path_index_ensured = true
    pcall(self.conn.exec, self.conn, "CREATE INDEX IF NOT EXISTS idx_downloads_path ON downloads(path)")
end

function DownloadsEngine:entryColumns()
    if self.has_date_uploaded and self.has_viewer then
        return BASE_COLUMNS .. ", date_uploaded, viewer", true, true
    end
    local has_date, has_viewer = false, false
    query(self.conn, false, "PRAGMA table_info(downloads)", nil, function(stmt)
        local row = {}
        while stmt:step(row) do
            if row[2] == "date_uploaded" then
                has_date = true
            elseif row[2] == "viewer" then
                has_viewer = true
            end
        end
        return true
    end)
    if has_date then
        self.has_date_uploaded = true
    end
    if has_viewer then
        self.has_viewer = true
    end
    local cols = BASE_COLUMNS
    if has_date then
        cols = cols .. ", date_uploaded"
    end
    if has_viewer then
        cols = cols .. ", viewer"
    end
    return cols, has_date, has_viewer
end

function DownloadsEngine:indexedPath(source_key, manga_key, chapter_key)
    if not self:tableExists() then
        return ""
    end
    local row = query(self.conn, nil,
        "SELECT path FROM downloads WHERE source_key=? AND manga_key=? AND chapter_key=?",
        { source_key, manga_key, chapter_key }, firstRow)
    return row and row[1] or ""
end

function DownloadsEngine:path(source_key, manga_key, chapter_key)
    local p = self:indexedPath(source_key, manga_key, chapter_key)
    if p == "" then
        return ""
    end
    local norm = DownloadsEngine.normalizePath(p)
    if lfs.attributes(norm, "mode") ~= "file" then
        return ""
    end
    return norm
end

function DownloadsEngine:byPath(file_path)
    if not self:tableExists() or type(file_path) ~= "string" or file_path == "" then
        return nil
    end
    self:ensurePathIndex()
    local cols, has_date, has_viewer = self:entryColumns()
    local norm = DownloadsEngine.normalizePath(file_path)
    local rel = DownloadsEngine.relativeDataPath(norm)
    local alt = rel ~= "" and rel or norm
    local row = query(self.conn, nil,
        "SELECT " .. cols .. " FROM downloads WHERE path=? OR path=? OR path=? LIMIT 1",
        { norm, alt, file_path }, firstRow)
    if not row then
        return nil
    end
    return rowToEntry(row, has_date, has_viewer)
end

function DownloadsEngine:mangaEpubPath(source_key, manga_key)
    if not self:tableExists() or not source_key or not manga_key or manga_key == "" then
        return ""
    end
    local stats = self:mangaDownloadStats()
    if stats and stats.by_exact then
        local g = stats.by_exact[source_key .. "\0" .. manga_key]
        return g and g.epubPath or ""
    end
    local row = query(self.conn, nil,
        "SELECT path FROM downloads WHERE source_key=? AND manga_key=? AND lower(path) LIKE '%.epub' ORDER BY downloaded_at DESC LIMIT 1",
        { source_key, manga_key }, firstRow)
    local p = row and row[1] or ""
    if p == "" then
        return ""
    end
    local norm = DownloadsEngine.normalizePath(p)
    if lfs.attributes(norm, "mode") ~= "file" then
        return ""
    end
    return norm
end

local function unlinkFilePaths(norm_path, raw_paths)
    if lfs.attributes(norm_path, "mode") == "file" then
        local ok, err = os.remove(norm_path)
        if not ok then
            return false, err
        end
    end
    for raw_path in pairs(raw_paths or {}) do
        if raw_path ~= norm_path and lfs.attributes(raw_path, "mode") == "file" then
            local ok, err = os.remove(raw_path)
            if not ok then
                return false, err
            end
        end
    end
    purgeSidecar(norm_path)
    return true
end

function DownloadsEngine:deleteRowsByPaths(norm_path, raw_paths)
    local deleted = query(self.conn, false,
        "DELETE FROM downloads WHERE path=?", { norm_path }, function(stmt) stmt:step() return true end)
    for raw_path in pairs(raw_paths or {}) do
        if raw_path ~= norm_path then
            query(self.conn, false,
                "DELETE FROM downloads WHERE path=?", { raw_path }, function(stmt) stmt:step() return true end)
        end
    end
    DownloadsEngine.invalidateCache(self.downloads_dir)
    return deleted
end

function DownloadsEngine:remove(source_key, manga_key, chapter_key)
    local raw_path = self:indexedPath(source_key, manga_key, chapter_key)
    if raw_path == "" then
        return true
    end
    local path = DownloadsEngine.normalizePath(raw_path)
    if EpubHelper.isEpub(path) then
        if not self.engine then
            return false, "engine unavailable for epub repack"
        end
        local res, err = self.engine:epubRemove({
            epub_path = path,
            downloads_dir = self.downloads_dir,
            source_key = source_key,
            manga_key = manga_key,
            chapter_keys = { chapter_key },
        })
        if not res then
            return false, err
        end
        if (res.remaining or 0) <= 0 then
            purgeSidecar(path)
        elseif type(res.oldKeys) == "table" and type(res.newKeys) == "table" then
            EpubHelper.remapDocSettings(path, res.oldKeys, res.newKeys, res.sdrRemapped == true)
        end
        EpubHelper.invalidateCache(path)
        DownloadsEngine.invalidateCache(self.downloads_dir)
        return true
    end

    local ok_rm, rm_err = unlinkFilePaths(path, { [raw_path] = true })
    if not ok_rm then
        return false, rm_err
    end
    local deleted = query(self.conn, false,
        "DELETE FROM downloads WHERE source_key=? AND manga_key=? AND chapter_key=?",
        { source_key, manga_key, chapter_key }, function(stmt) stmt:step() return true end)
    if not deleted then
        return false
    end
    DownloadsEngine.invalidateCache(self.downloads_dir)
    return true
end

-- removeManga deletes every downloaded chapter matching (source_key, manga_key)
-- (including canonical slug/id variants), unlinking shared EPUB files once
-- instead of repacking chapter-by-chapter, returning how many rows were removed.
function DownloadsEngine:removeManga(source_key, manga_key, manga_title)
    local matching = {}
    local files_to_unlink = {}
    for _idx, e in ipairs(self:list() or {}) do
        if DownloadsEngine.entryMatchesManga(e, source_key, manga_key, manga_title) then
            table.insert(matching, e)
            local norm = DownloadsEngine.normalizePath(e.path)
            if norm ~= "" then
                files_to_unlink[norm] = files_to_unlink[norm] or {}
                files_to_unlink[norm][e.path] = true
            end
        end
    end
    if #matching == 0 then
        return 0
    end

    for norm, raw_paths in pairs(files_to_unlink) do
        unlinkFilePaths(norm, raw_paths)
    end

    local removed = 0
    for _idx, e in ipairs(matching) do
        local norm = DownloadsEngine.normalizePath(e.path)
        if lfs.attributes(norm, "mode") ~= "file" then
            local deleted = query(self.conn, false,
                "DELETE FROM downloads WHERE source_key=? AND manga_key=? AND chapter_key=?",
                { e.sourceKey, e.mangaKey, e.chapterKey }, function(stmt) stmt:step() return true end)
            if deleted then
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        DownloadsEngine.invalidateCache(self.downloads_dir)
    end
    return removed
end

-- entryMatchesManga handles sources (e.g. zh.godamanga) where search returns
-- manga.Key = "<slug>" while mangaUpdate canonicalizes it to "<slug>/<numeric_id>".
function DownloadsEngine.entryMatchesManga(entry, source_key, manga_key, manga_title)
    if entry.sourceKey ~= source_key then
        return false
    end
    if manga_key and manga_key ~= "" then
        if entry.mangaKey == manga_key then
            return true
        end
        if entry.mangaKey:sub(1, #manga_key + 1) == manga_key .. "/" then
            return true
        end
        if manga_key:sub(1, #entry.mangaKey + 1) == entry.mangaKey .. "/" then
            return true
        end
    end
    if manga_title and manga_title ~= "" and entry.mangaTitle == manga_title then
        return true
    end
    return false
end

function DownloadsEngine:resetProgress(source_key, manga_key)
    if not self:tableExists() then
        return
    end
    local seen = {}
    for _idx, e in ipairs(self:list() or {}) do
        if DownloadsEngine.entryMatchesManga(e, source_key, manga_key) then
            local norm = DownloadsEngine.normalizePath(e.path)
            if norm ~= "" and not seen[norm] then
                seen[norm] = true
                purgeSidecar(norm)
            end
        end
    end
end

function DownloadsEngine:list()
    if not self:tableExists() then
        return {}
    end
    local token = dbStateToken(self.downloads_dir)
    local cached = _cache_by_dir[self.downloads_dir]
    if cached and cached.token == token and cached.entries then
        return cached.entries
    end
    local cols, has_date, has_viewer = self:entryColumns()
    local entries = query(self.conn, nil,
        "SELECT " .. cols .. " FROM downloads ORDER BY downloaded_at DESC", nil,
        function(stmt)
            local out, row = {}, {}
            while stmt:step(row) do
                table.insert(out, rowToEntry(row, has_date, has_viewer))
            end
            return out
        end)
    if not entries then
        return nil, _("Could not read the downloads index.")
    end
    _cache_by_dir[self.downloads_dir] = {
        token = token,
        entries = entries,
        stats = nil,
    }
    return entries
end

-- mangaDownloadStats aggregates valid (still-on-disk) downloaded chapters per
-- manga, indexed by exact key, slug prefix (before '/'), and manga title so
-- lookups from LibraryBrowser, SearchBrowser, and GlobalSearchBrowser are O(1).
function DownloadsEngine:mangaDownloadStats(entries)
    local token = dbStateToken(self.downloads_dir)
    local cached = _cache_by_dir[self.downloads_dir]
    local use_cache = (entries == nil) or (cached and cached.entries == entries)
    if use_cache and cached and cached.token == token and cached.stats then
        return cached.stats
    end

    if not entries then
        entries = self:list() or {}
        cached = _cache_by_dir[self.downloads_dir]
        token = dbStateToken(self.downloads_dir)
    end

    local existing = DownloadsEngine.buildExistingFilesSet(entries)
    local valid_entries = {}
    local by_exact = {}
    local by_prefix = {}
    local by_title = {}
    local groups = {}

    for _idx, e in ipairs(entries) do
        if e.path ~= "" and existing[e.path] then
            table.insert(valid_entries, e)
            local exact_id = e.sourceKey .. "\0" .. e.mangaKey
            local group = by_exact[exact_id]
            if not group then
                group = {
                    sourceKey = e.sourceKey,
                    sourcePath = e.sourcePath,
                    mangaKey = e.mangaKey,
                    mangaTitle = e.mangaTitle,
                    count = 0,
                    sizeBytes = 0,
                    latestAt = 0,
                    chapters = {},
                    _seen_paths = {},
                }
                by_exact[exact_id] = group
                table.insert(groups, group)

                local slug = e.mangaKey:match("^([^/]+)/")
                if slug and slug ~= "" then
                    by_prefix[e.sourceKey .. "\0" .. slug] = group
                end
                if e.mangaTitle and e.mangaTitle ~= "" then
                    by_title[e.sourceKey .. "\0" .. e.mangaTitle] = group
                end
            end
            group.count = group.count + 1
            local norm = DownloadsEngine.normalizePath(e.path)
            if norm ~= "" and not group._seen_paths[norm] then
                group._seen_paths[norm] = true
                group.sizeBytes = group.sizeBytes + (e.sizeBytes or 0)
            end
            local dl_at = e.downloadedAt or 0
            if norm ~= "" and EpubHelper.isEpub(norm) and (not group.epubPath or dl_at > (group._epub_at or -1)) then
                group.epubPath = norm
                group._epub_at = dl_at
            end
            if dl_at > group.latestAt then
                group.latestAt = dl_at
            end
            table.insert(group.chapters, e)
        end
    end
    for _idx, group in ipairs(groups) do
        group._seen_paths = nil
        group._epub_at = nil
    end

    local stats = {
        groups = groups,
        by_exact = by_exact,
        by_prefix = by_prefix,
        by_title = by_title,
        valid_entries = valid_entries,
    }
    if use_cache then
        if not cached or cached.token ~= token then
            cached = { token = token, entries = entries }
            _cache_by_dir[self.downloads_dir] = cached
        end
        cached.stats = stats
    end
    return stats
end

function DownloadsEngine.lookupMangaGroup(stats, source_key, manga_key, manga_title, canonical_key)
    if not stats or not source_key then
        return nil
    end
    if canonical_key and canonical_key ~= "" then
        local g = stats.by_exact[source_key .. "\0" .. canonical_key]
        if g then return g end
    end
    if manga_key and manga_key ~= "" then
        local g = stats.by_exact[source_key .. "\0" .. manga_key]
            or stats.by_prefix[source_key .. "\0" .. manga_key]
        if g then return g end
        local slug = manga_key:match("^([^/]+)/")
        if slug and slug ~= "" then
            g = stats.by_prefix[source_key .. "\0" .. slug] or stats.by_exact[source_key .. "\0" .. slug]
            if g then return g end
        end
    end
    if manga_title and manga_title ~= "" then
        return stats.by_title[source_key .. "\0" .. manga_title]
    end
    return nil
end

-- Returns a read-only { [chapter_key] = file_path } map for a manga in O(1)
-- when stats are cached, avoiding per-chapter SQLite + lfs.attributes queries.
function DownloadsEngine:downloadedPathsMap(source_key, manga_key, manga_title, canonical_key)
    local stats = self:mangaDownloadStats()
    local group = DownloadsEngine.lookupMangaGroup(stats, source_key, manga_key, manga_title, canonical_key)
    if not group then
        return {}
    end
    if not group._paths_map then
        local map = {}
        for _idx, e in ipairs(group.chapters or {}) do
            if e.chapterKey and e.chapterKey ~= "" and e.path and e.path ~= "" then
                map[e.chapterKey] = e.path
            end
        end
        group._paths_map = map
    end
    return group._paths_map
end

function DownloadsEngine:totalBytes()
    if not self:tableExists() then
        return 0
    end
    local ok, total = pcall(self.conn.rowexec, self.conn,
        "SELECT COALESCE(SUM(sz), 0) FROM (SELECT MAX(size_bytes) AS sz FROM downloads GROUP BY path)")
    return ok and tonumber(total) or 0
end

local function isPathKept(keep_path, norm_path, raw_paths)
    if type(keep_path) == "table" then
        if keep_path[norm_path] then
            return true
        end
        for raw_path in pairs(raw_paths or {}) do
            if keep_path[raw_path] then
                return true
            end
        end
        return false
    elseif type(keep_path) == "string" and keep_path ~= "" then
        local keep_norm = DownloadsEngine.normalizePath(keep_path)
        if norm_path == keep_norm or raw_paths[keep_path] then
            return true
        end
    end
    return false
end

function DownloadsEngine:prune(limit_bytes, keep_path)
    if not limit_bytes or limit_bytes <= 0 then
        return {}
    end
    local total = self:totalBytes()
    if total <= limit_bytes then
        return {}
    end
    local entries = self:list() or {}
    -- entries is newest-first; group by distinct file path so shared EPUB files
    -- are counted once and unlinked wholesale rather than repacked per chapter.
    local groups = {}
    local by_norm = {}
    for _idx, e in ipairs(entries) do
        local norm = DownloadsEngine.normalizePath(e.path)
        if norm ~= "" then
            local g = by_norm[norm]
            if not g then
                g = {
                    norm_path = norm,
                    raw_paths = {},
                    sizeBytes = 0,
                    entries = {},
                }
                by_norm[norm] = g
                table.insert(groups, g)
            end
            g.raw_paths[e.path] = true
            if (e.sizeBytes or 0) > g.sizeBytes then
                g.sizeBytes = e.sizeBytes or 0
            end
            table.insert(g.entries, e)
        end
    end

    local removed = {}
    for i = #groups, 1, -1 do
        if total <= limit_bytes then
            break
        end
        local g = groups[i]
        if not isPathKept(keep_path, g.norm_path, g.raw_paths) then
            local ok_rm = unlinkFilePaths(g.norm_path, g.raw_paths)
            if ok_rm and self:deleteRowsByPaths(g.norm_path, g.raw_paths) then
                total = total - g.sizeBytes
                for _j, e in ipairs(g.entries) do
                    table.insert(removed, e)
                end
            end
        end
    end
    return removed
end

function DownloadsEngine:removeAllExcept(keep_path)
    local by_norm = {}
    for _idx, e in ipairs(self:list() or {}) do
        local norm = DownloadsEngine.normalizePath(e.path)
        if norm ~= "" then
            by_norm[norm] = by_norm[norm] or {}
            by_norm[norm][e.path] = true
        end
    end
    for norm, raw_paths in pairs(by_norm) do
        if not isPathKept(keep_path, norm, raw_paths) then
            if unlinkFilePaths(norm, raw_paths) then
                self:deleteRowsByPaths(norm, raw_paths)
            end
        end
    end
end

return DownloadsEngine
