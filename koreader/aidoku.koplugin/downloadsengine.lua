--[[--
DownloadsEngine reads/writes <downloads_dir>/index.db directly via
lua-ljsqlite3. Also provides per-manga aggregated download statistics and
canonical/slug-prefix matching so downloaded manga are accurately annotated
across LibraryBrowser, SearchBrowser, GlobalSearchBrowser, and DownloadsBrowser.
]]

local DocSettings = require("docsettings")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("aidoku_l10n")

local DownloadsEngine = {}
DownloadsEngine.__index = DownloadsEngine

function DownloadsEngine.isUnder(file, dir)
    dir = dir:gsub("/+$", "")
    return file:sub(1, #dir + 1) == dir .. "/"
end

local BASE_COLUMNS = "source_key, source_path, manga_key, chapter_key, path, "
    .. "manga_title, chapter_title, size_bytes, downloaded_at, chapter_number, volume_number"

local function float32(v)
    v = tonumber(v)
    return v and tonumber(string.format("%.7g", v))
end

local function rowToEntry(row)
    return {
        sourceKey = row[1],
        sourcePath = row[2],
        mangaKey = row[3],
        chapterKey = row[4],
        path = row[5],
        mangaTitle = row[6],
        chapterTitle = row[7],
        sizeBytes = tonumber(row[8]) or 0,
        downloadedAt = tonumber(row[9]) or 0,
        chapterNumber = float32(row[10]),
        volumeNumber = float32(row[11]),
        dateUploaded = row[12] and tonumber(row[12]) or nil,
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

function DownloadsEngine.new(downloads_dir)
    local self = setmetatable({
        downloads_dir = downloads_dir,
        conn = nil,
        has_date_uploaded = nil,
    }, DownloadsEngine)
    local ok, conn = pcall(SQ3.open, downloads_dir .. "/index.db")
    if ok and pcall(conn.set_busy_timeout, conn, 5000) then
        self.conn = conn
    end
    return self
end

function DownloadsEngine:isAvailable()
    return self.conn ~= nil
end

function DownloadsEngine:tableExists()
    if not self.conn then
        return false
    end
    local ok, count = pcall(self.conn.rowexec, self.conn,
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='downloads'")
    return ok and (tonumber(count) or 0) > 0
end

function DownloadsEngine:entryColumns()
    if self.has_date_uploaded then
        return BASE_COLUMNS .. ", date_uploaded"
    end
    local found = query(self.conn, false, "PRAGMA table_info(downloads)", nil, function(stmt)
        local row = {}
        while stmt:step(row) do
            if row[2] == "date_uploaded" then
                return true
            end
        end
        return false
    end)
    if found then
        self.has_date_uploaded = true
        return BASE_COLUMNS .. ", date_uploaded"
    end
    return BASE_COLUMNS
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
    if p ~= "" and lfs.attributes(p, "mode") ~= "file" then
        return ""
    end
    return p
end

function DownloadsEngine:byPath(file_path)
    if not self:tableExists() then
        return nil
    end
    local cols = self:entryColumns()
    local row = query(self.conn, nil,
        "SELECT " .. cols .. " FROM downloads WHERE path=?", { file_path }, firstRow)
    if not row then
        return nil
    end
    return rowToEntry(row)
end

function DownloadsEngine:remove(source_key, manga_key, chapter_key)
    local path = self:indexedPath(source_key, manga_key, chapter_key)
    if path == "" then
        return true
    end
    if lfs.attributes(path, "mode") == "file" then
        local ok, err = os.remove(path)
        if not ok then
            return false, err
        end
    end
    purgeSidecar(path)
    local deleted = query(self.conn, false,
        "DELETE FROM downloads WHERE source_key=? AND manga_key=? AND chapter_key=?",
        { source_key, manga_key, chapter_key }, function(stmt) stmt:step() return true end)
    if not deleted then
        return false
    end
    return true
end

-- removeManga deletes every downloaded chapter matching (source_key, manga_key)
-- (including canonical slug/id variants), returning how many chapters were removed.
function DownloadsEngine:removeManga(source_key, manga_key, manga_title)
    local removed = 0
    for _idx, e in ipairs(self:list() or {}) do
        if DownloadsEngine.entryMatchesManga(e, source_key, manga_key, manga_title) then
            if self:remove(e.sourceKey, e.mangaKey, e.chapterKey) then
                removed = removed + 1
            end
        end
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
    for _idx, e in ipairs(self:list() or {}) do
        if DownloadsEngine.entryMatchesManga(e, source_key, manga_key) then
            purgeSidecar(e.path)
        end
    end
end

function DownloadsEngine:list()
    if not self:tableExists() then
        return {}
    end
    local cols = self:entryColumns()
    local entries = query(self.conn, nil,
        "SELECT " .. cols .. " FROM downloads ORDER BY downloaded_at DESC", nil,
        function(stmt)
            local out, row = {}, {}
            while stmt:step(row) do
                table.insert(out, rowToEntry(row))
            end
            return out
        end)
    if not entries then
        return nil, _("Could not read the downloads index.")
    end
    return entries
end

-- mangaDownloadStats aggregates valid (still-on-disk) downloaded chapters per
-- manga, indexed by exact key, slug prefix (before '/'), and manga title so
-- lookups from LibraryBrowser, SearchBrowser, and GlobalSearchBrowser are O(1).
function DownloadsEngine:mangaDownloadStats(entries)
    entries = entries or self:list() or {}
    local by_exact = {}
    local by_prefix = {}
    local by_title = {}
    local groups = {}

    for _idx, e in ipairs(entries) do
        if e.path ~= "" and lfs.attributes(e.path, "mode") == "file" then
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
            group.sizeBytes = group.sizeBytes + (e.sizeBytes or 0)
            if (e.downloadedAt or 0) > group.latestAt then
                group.latestAt = e.downloadedAt
            end
            table.insert(group.chapters, e)
        end
    end

    return {
        groups = groups,
        by_exact = by_exact,
        by_prefix = by_prefix,
        by_title = by_title,
    }
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

function DownloadsEngine:totalBytes()
    if not self:tableExists() then
        return 0
    end
    local ok, total = pcall(self.conn.rowexec, self.conn, "SELECT SUM(size_bytes) FROM downloads")
    return ok and tonumber(total) or 0
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
    local removed = {}
    for i = #entries, 1, -1 do
        if total <= limit_bytes then
            break
        end
        local e = entries[i]
        local kept
        if type(keep_path) == "table" then
            kept = keep_path[e.path]
        else
            kept = e.path == keep_path
        end
        if not kept then
            local ok = self:remove(e.sourceKey, e.mangaKey, e.chapterKey)
            if ok then
                total = total - e.sizeBytes
                table.insert(removed, e)
            end
        end
    end
    return removed
end

function DownloadsEngine:removeAllExcept(keep_path)
    for _idx, e in ipairs(self:list() or {}) do
        if e.path ~= keep_path then
            self:remove(e.sourceKey, e.mangaKey, e.chapterKey)
        end
    end
end

return DownloadsEngine
