--[[--
Store is the plugin's persistent state: library, read history, manga chapter
counts/canonical keys, and preferences.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local LuaSettings = require("luasettings")
local SQ3 = require("lua-ljsqlite3/init")
local util = require("util")

local Store = {}
Store.__index = Store

local LIBRARY_SCHEMA = [[
    CREATE TABLE IF NOT EXISTS library (
        source_key   TEXT NOT NULL,
        manga_key    TEXT NOT NULL,
        source_path  TEXT NOT NULL,
        title        TEXT NOT NULL,
        cover        TEXT,
        added_at     INTEGER NOT NULL,
        PRIMARY KEY (source_key, manga_key)
    );
    CREATE TABLE IF NOT EXISTS last_read (
        source_key    TEXT NOT NULL,
        manga_key     TEXT NOT NULL,
        last_read_at  INTEGER NOT NULL,
        PRIMARY KEY (source_key, manga_key)
    );
    CREATE TABLE IF NOT EXISTS read_chapters (
        source_key   TEXT NOT NULL,
        manga_key    TEXT NOT NULL,
        chapter_key  TEXT NOT NULL,
        PRIMARY KEY (source_key, manga_key, chapter_key)
    );
    CREATE TABLE IF NOT EXISTS manga_meta (
        source_key    TEXT NOT NULL,
        manga_key     TEXT NOT NULL,
        canonical_key TEXT NOT NULL DEFAULT '',
        chapter_count INTEGER NOT NULL DEFAULT 0,
        updated_at    INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_key, manga_key)
    );
]]

local function pstep(fallback, fn)
    local ok, result = pcall(fn)
    if not ok then
        return fallback
    end
    return result
end

local function migrateLegacyData(settings, db)
    if settings:readSetting("library_migrated_to_sqlite", false) then
        return
    end

    local library = settings:readSetting("library", {})
    local last_read = settings:readSetting("last_read", {})
    local read_chapters = settings:readSetting("read_chapters", {})

    local ok = pcall(function()
        db:exec("BEGIN")

        local lib_stmt = db:prepare([[
            INSERT OR IGNORE INTO library (source_key, manga_key, source_path, title, cover, added_at)
            VALUES (?, ?, ?, ?, ?, ?)
        ]])
        for _, entry in pairs(library) do
            lib_stmt:bind(entry.source_key or "", entry.manga_key, entry.source_path or "",
                entry.title, entry.cover, entry.added_at or 0)
            lib_stmt:step()
            lib_stmt:reset()
        end
        lib_stmt:close()

        local lr_stmt = db:prepare(
            "INSERT OR IGNORE INTO last_read (source_key, manga_key, last_read_at) VALUES (?, ?, ?)")
        for key, read_at in pairs(last_read) do
            local source_key, manga_key = key:match("^(.-)|(.*)$")
            if source_key and manga_key then
                lr_stmt:bind(source_key, manga_key, read_at)
                lr_stmt:step()
                lr_stmt:reset()
            end
        end
        lr_stmt:close()

        local rc_stmt = db:prepare(
            "INSERT OR IGNORE INTO read_chapters (source_key, manga_key, chapter_key) VALUES (?, ?, ?)")
        for key in pairs(read_chapters) do
            local source_key, rest = key:match("^(.-)|(.*)$")
            local manga_key, chapter_key
            if rest then
                manga_key, chapter_key = rest:match("^(.-)|(.*)$")
            end
            if source_key and manga_key and chapter_key then
                rc_stmt:bind(source_key, manga_key, chapter_key)
                rc_stmt:step()
                rc_stmt:reset()
            end
        end
        rc_stmt:close()

        db:exec("COMMIT")
    end)

    if not ok then
        pcall(function() db:exec("ROLLBACK") end)
        return
    end

    settings:delSetting("library")
    settings:delSetting("last_read")
    settings:delSetting("read_chapters")
    settings:saveSetting("library_migrated_to_sqlite", true)
    settings:flush()
end

function Store.new(data_dir)
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/aidoku.lua")

    data_dir = (data_dir or ""):gsub("/+$", "")
    util.makePath(data_dir)

    local ok, db_or_err = pcall(function()
        local db = SQ3.open(data_dir .. "/library.db")
        db:set_busy_timeout(5000)
        if Device:canUseWAL() then
            db:exec("PRAGMA journal_mode=WAL;")
        else
            db:exec("PRAGMA journal_mode=TRUNCATE;")
        end
        db:exec(LIBRARY_SCHEMA)
        return db
    end)
    if not ok then
        error("Aidoku: could not open library database at " .. data_dir .. "/library.db: " .. tostring(db_or_err), 0)
    end
    local db = db_or_err

    migrateLegacyData(settings, db)

    return setmetatable({ settings = settings, db = db }, Store)
end

-- ===== Library (bookmarked manga) =====

function Store:isBookmarked(source_key, manga_key)
    return pstep(false, function()
        local stmt = self.db:prepare("SELECT 1 FROM library WHERE source_key=? AND (manga_key=? OR manga_key LIKE ?) LIMIT 1")
        stmt:bind(source_key, manga_key, tostring(manga_key) .. "/%")
        local row = stmt:step()
        stmt:close()
        if row ~= nil then
            return true
        end
        -- Also match if manga_key is a canonical "<slug>/<id>" form of a bookmarked "<slug>"
        local slug = type(manga_key) == "string" and manga_key:match("^([^/]+)/") or nil
        if slug and slug ~= "" then
            local s2 = self.db:prepare("SELECT 1 FROM library WHERE source_key=? AND manga_key=? LIMIT 1")
            s2:bind(source_key, slug)
            local r2 = s2:step()
            s2:close()
            return r2 ~= nil
        end
        return false
    end)
end

function Store:addBookmark(source_key, source_path, manga_key, title, cover)
    return pstep(false, function()
        local stmt = self.db:prepare([[
            INSERT INTO library (source_key, manga_key, source_path, title, cover, added_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (source_key, manga_key) DO UPDATE SET
                source_path=excluded.source_path, title=excluded.title,
                cover=COALESCE(NULLIF(excluded.cover, ''), library.cover), added_at=excluded.added_at
        ]])
        stmt:bind(source_key, manga_key, source_path, title, cover, os.time())
        stmt:step()
        stmt:close()
        return true
    end)
end

function Store:updateBookmarkCover(source_key, manga_key, cover)
    if not source_key or not manga_key or type(cover) ~= "string" or cover == "" then
        return false
    end
    return pstep(false, function()
        local stmt = self.db:prepare(
            "UPDATE library SET cover=? WHERE source_key=? AND (manga_key=? OR manga_key LIKE ?)")
        stmt:bind(cover, source_key, manga_key, tostring(manga_key) .. "/%")
        stmt:step()
        stmt:close()
        local slug = type(manga_key) == "string" and manga_key:match("^([^/]+)/") or nil
        if slug and slug ~= "" then
            local s2 = self.db:prepare(
                "UPDATE library SET cover=? WHERE source_key=? AND manga_key=?")
            s2:bind(cover, source_key, slug)
            s2:step()
            s2:close()
        end
        return true
    end)
end

function Store:removeBookmark(source_key, manga_key)
    return pstep(false, function()
        local stmt = self.db:prepare("DELETE FROM library WHERE source_key=? AND (manga_key=? OR manga_key LIKE ?)")
        stmt:bind(source_key, manga_key, tostring(manga_key) .. "/%")
        stmt:step()
        stmt:close()
        local slug = type(manga_key) == "string" and manga_key:match("^([^/]+)/") or nil
        if slug and slug ~= "" then
            local s2 = self.db:prepare("DELETE FROM library WHERE source_key=? AND manga_key=?")
            s2:bind(source_key, slug)
            s2:step()
            s2:close()
        end
        return true
    end)
end

function Store:libraryEntries()
    return pstep({}, function()
        local stmt = self.db:prepare(
            "SELECT source_key, manga_key, source_path, title, cover, added_at FROM library ORDER BY added_at ASC")
        local entries = {}
        local row = {}
        while stmt:step(row) do
            table.insert(entries, {
                source_key = row[1],
                manga_key = row[2],
                source_path = row[3],
                title = row[4],
                cover = row[5],
                added_at = tonumber(row[6]) or 0,
            })
        end
        stmt:close()
        return entries
    end)
end

-- ===== Manga metadata (known chapter counts & canonical keys) =====

function Store:recordMangaMeta(source_key, manga_key, canonical_key, chapter_count)
    if not source_key or not manga_key then
        return false
    end
    canonical_key = canonical_key or manga_key
    chapter_count = tonumber(chapter_count) or 0
    return pstep(false, function()
        local stmt = self.db:prepare([[
            INSERT INTO manga_meta (source_key, manga_key, canonical_key, chapter_count, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (source_key, manga_key) DO UPDATE SET
                canonical_key=excluded.canonical_key,
                chapter_count=excluded.chapter_count,
                updated_at=excluded.updated_at
        ]])
        local now = os.time()
        stmt:bind(source_key, manga_key, canonical_key, chapter_count, now)
        stmt:step()
        stmt:reset()
        if canonical_key ~= "" and canonical_key ~= manga_key then
            stmt:bind(source_key, canonical_key, canonical_key, chapter_count, now)
            stmt:step()
        end
        stmt:close()
        return true
    end)
end

function Store:getMangaMetaMap()
    return pstep({}, function()
        local stmt = self.db:prepare("SELECT source_key, manga_key, canonical_key, chapter_count FROM manga_meta")
        local map = {}
        local row = {}
        while stmt:step(row) do
            map[row[1] .. "\0" .. row[2]] = {
                canonical_key = row[3] or "",
                chapter_count = tonumber(row[4]) or 0,
            }
        end
        stmt:close()
        return map
    end)
end

function Store:librarySortOrder()
    return self.settings:readSetting("library_sort_order", "name")
end

function Store:setLibrarySortOrder(order)
    self.settings:saveSetting("library_sort_order", order)
    self.settings:flush()
end

Store.LIBRARY_VIEW_MODES = {
    compact = true,
    list = true,
    grid = true,
}

Store.LANGUAGE_MODES = {
    auto = true,
    en = true,
    zh_CN = true,
    zh_TW = true,
    ja = true,
}

-- language returns one of: "auto" | "en" | "zh_CN" | "zh_TW" | "ja"
function Store:language()
    local lang = self.settings:readSetting("ui_language", "auto")
    if Store.LANGUAGE_MODES[lang] then
        return lang
    end
    return "auto"
end

function Store:setLanguage(lang)
    if not Store.LANGUAGE_MODES[lang] then
        lang = "auto"
    end
    self.settings:saveSetting("ui_language", lang)
    self.settings:flush()
    local ok, l10n = pcall(require, "aidoku_l10n")
    if ok and l10n and type(l10n.setLanguage) == "function" then
        l10n.setLanguage(lang)
    end
end

-- libraryViewMode returns one of:
--   "compact" (title only) | "list" (cover + title) | "grid" (cover grid + small title)
function Store:libraryViewMode()
    local mode = self.settings:readSetting("library_view_mode", "compact")
    if Store.LIBRARY_VIEW_MODES[mode] then
        return mode
    end
    return "compact"
end

function Store:setLibraryViewMode(mode)
    if not Store.LIBRARY_VIEW_MODES[mode] then
        mode = "compact"
    end
    self.settings:saveSetting("library_view_mode", mode)
    self.settings:flush()
end

function Store:lastReadAt(source_key, manga_key)
    return pstep(0, function()
        local stmt = self.db:prepare("SELECT last_read_at FROM last_read WHERE source_key=? AND manga_key=?")
        stmt:bind(source_key, manga_key)
        local row = stmt:step()
        stmt:close()
        if row and tonumber(row[1]) then
            return tonumber(row[1])
        end
        local slug = type(manga_key) == "string" and manga_key:match("^([^/]+)/") or nil
        if slug and slug ~= "" then
            local s2 = self.db:prepare("SELECT last_read_at FROM last_read WHERE source_key=? AND manga_key=?")
            s2:bind(source_key, slug)
            local r2 = s2:step()
            s2:close()
            return (r2 and tonumber(r2[1])) or 0
        end
        return 0
    end)
end

function Store:markLastRead(source_key, manga_key)
    return pstep(false, function()
        local stmt = self.db:prepare([[
            INSERT INTO last_read (source_key, manga_key, last_read_at) VALUES (?, ?, ?)
            ON CONFLICT (source_key, manga_key) DO UPDATE SET last_read_at=excluded.last_read_at
        ]])
        local now = os.time()
        stmt:bind(source_key, manga_key, now)
        stmt:step()
        local slug = type(manga_key) == "string" and manga_key:match("^([^/]+)/") or nil
        if slug and slug ~= "" then
            stmt:reset()
            stmt:bind(source_key, slug, now)
            stmt:step()
        end
        stmt:close()
        return true
    end)
end

-- ===== Read chapters =====

function Store:isChapterRead(source_key, manga_key, chapter_key)
    return pstep(false, function()
        local stmt = self.db:prepare(
            "SELECT 1 FROM read_chapters WHERE source_key=? AND manga_key=? AND chapter_key=? LIMIT 1")
        stmt:bind(source_key, manga_key, chapter_key)
        local row = stmt:step()
        stmt:close()
        if row ~= nil then
            return true
        end
        local slug = type(manga_key) == "string" and manga_key:match("^([^/]+)/") or nil
        if slug and slug ~= "" then
            local s2 = self.db:prepare(
                "SELECT 1 FROM read_chapters WHERE source_key=? AND manga_key=? AND chapter_key=? LIMIT 1")
            s2:bind(source_key, slug, chapter_key)
            local r2 = s2:step()
            s2:close()
            return r2 ~= nil
        end
        return false
    end)
end

function Store:markChapterRead(source_key, manga_key, chapter_key)
    return pstep(false, function()
        local stmt = self.db:prepare(
            "INSERT OR IGNORE INTO read_chapters (source_key, manga_key, chapter_key) VALUES (?, ?, ?)")
        stmt:bind(source_key, manga_key, chapter_key)
        stmt:step()
        stmt:close()
        return true
    end)
end

function Store:markChapterUnread(source_key, manga_key, chapter_key)
    return pstep(false, function()
        local stmt = self.db:prepare(
            "DELETE FROM read_chapters WHERE source_key=? AND manga_key=? AND chapter_key=?")
        stmt:bind(source_key, manga_key, chapter_key)
        stmt:step()
        local slug = type(manga_key) == "string" and manga_key:match("^([^/]+)/") or nil
        if slug and slug ~= "" then
            stmt:reset()
            stmt:bind(source_key, slug, chapter_key)
            stmt:step()
        end
        stmt:close()
        return true
    end)
end

function Store:resetReadChapters(source_key, manga_key)
    return pstep(false, function()
        local stmt = self.db:prepare("DELETE FROM read_chapters WHERE source_key=? AND manga_key=?")
        stmt:bind(source_key, manga_key)
        stmt:step()
        local slug = type(manga_key) == "string" and manga_key:match("^([^/]+)/") or nil
        if slug and slug ~= "" then
            stmt:reset()
            stmt:bind(source_key, slug)
            stmt:step()
        end
        stmt:close()
        return true
    end)
end

-- ===== Preferences =====

-- Legacy sortOrder accessor kept for backward compatibility; backed by chapterSortMode.
function Store:sortOrder()
    local m = self:chapterSortMode()
    if m == "source_asc" or m == "name_asc" or m == "date_asc" then
        return "asc"
    end
    return "desc"
end

function Store:setSortOrder(order)
    self:setChapterSortMode(order == "asc" and "source_asc" or "source_desc")
end

-- chapterSortMode is one of:
--   "source_desc" | "source_asc" | "name_asc" | "name_desc" | "date_desc" | "date_asc"
function Store:chapterSortMode()
    local mode = self.settings:readSetting("chapter_sort_mode", nil)
    if mode and mode ~= "" then
        return mode
    end
    local legacy = self.settings:readSetting("sort_order", "desc")
    return legacy == "asc" and "source_asc" or "source_desc"
end

function Store:setChapterSortMode(mode)
    self.settings:saveSetting("chapter_sort_mode", mode)
    self.settings:flush()
end

-- selectedSearchSources persists { [source_key] = true/false } for Multi-source Search Plus.
-- Returns nil if the user hasn't customized source selection yet (meaning default = all selected).
function Store:selectedSearchSources()
    local saved = self.settings:readSetting("selected_search_sources", nil)
    if type(saved) ~= "table" then
        return nil
    end
    return saved
end

function Store:setSelectedSearchSources(map)
    self.settings:saveSetting("selected_search_sources", map)
    self.settings:flush()
end

function Store:bufferChapters()
    return self.settings:readSetting("buffer_chapters", 0)
end

function Store:setBufferChapters(n)
    self.settings:saveSetting("buffer_chapters", n)
    self.settings:flush()
end

function Store:effectiveBufferChapters()
    local n = self:bufferChapters()
    if self:isEphemeralMode() and n > 1 then
        return 1
    end
    return n
end

function Store:nextChapterMode()
    return self.settings:readSetting("next_chapter_mode", "ask")
end

function Store:setNextChapterMode(mode)
    self.settings:saveSetting("next_chapter_mode", mode)
    self.settings:flush()
end

function Store:flareSolverrHost()
    return self.settings:readSetting("flaresolverr_host", "")
end

function Store:setFlareSolverrHost(host)
    self.settings:saveSetting("flaresolverr_host", host)
    self.settings:flush()
end

function Store:networkConcurrency()
    return self.settings:readSetting("network_concurrency", 0)
end

function Store:setNetworkConcurrency(n)
    self.settings:saveSetting("network_concurrency", n)
    self.settings:flush()
end

function Store:downloadLimitBytes()
    return self.settings:readSetting("download_limit_bytes", 0)
end

function Store:setDownloadLimitBytes(n)
    self.settings:saveSetting("download_limit_bytes", n)
    self.settings:flush()
end

function Store:isEphemeralMode()
    return self.settings:readSetting("ephemeral_mode", false)
end

function Store:setEphemeralMode(enabled)
    self.settings:saveSetting("ephemeral_mode", enabled)
    self.settings:flush()
end

function Store:ephemeralPath()
    return self.settings:readSetting("ephemeral_path", "/dev/shm")
end

function Store:setEphemeralPath(path)
    self.settings:saveSetting("ephemeral_path", path)
    self.settings:flush()
end

Store.DEFAULT_REPO_URL = "https://aidoku-community.github.io/sources/index.min.json"

function Store:repoURL()
    local url = self.settings:readSetting("repo_url", "")
    return url ~= "" and url or Store.DEFAULT_REPO_URL
end

function Store:setRepoURL(url)
    url = url and url:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if url == Store.DEFAULT_REPO_URL then
        url = ""
    end
    self.settings:saveSetting("repo_url", url)
    self.settings:flush()
end

-- ===== Koobone Integration Preferences =====

function Store:kooboneAutoSync()
    return self.settings:readSetting("koobone_auto_sync", true)
end

function Store:setKooboneAutoSync(enabled)
    self.settings:saveSetting("koobone_auto_sync", enabled and true or false)
    self.settings:flush()
end

function Store:kooboneAutoBookmark()
    return self.settings:readSetting("koobone_auto_bookmark", true)
end

function Store:setKooboneAutoBookmark(enabled)
    self.settings:saveSetting("koobone_auto_bookmark", enabled and true or false)
    self.settings:flush()
end

return Store
