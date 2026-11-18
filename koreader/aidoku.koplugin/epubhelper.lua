-- Pure-Lua helpers for Tsundoku's single-book EPUB 2 archives.
--
-- Handles:
--   1. Fast Central Directory lookup of META-INF/tsundoku.json without spawning a subprocess.
--   2. 1-based /body/DocFragment[k] spine-index mapping & XPointer remapping across repacks.
--   3. Reading progress sync from crengine last_xpointer into store.lua's read_chapters table.
--   4. Chapter jumping both before ReaderUI opens an EPUB and inside an open ReaderUI.

local ok_ds, DocSettings = pcall(require, "docsettings")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
local json = require("json")

local EpubHelper = {}

local MANIFEST_ENTRY = "META-INF/tsundoku.json"
local MAX_MANIFEST_CACHE = 16
local _manifest_cache = {}
local _manifest_order = {}
local _sidecar_cache = {}
local _sidecar_order = {}

local function cachePut(cache, order, key, entry)
    if not cache[key] then
        while #order >= MAX_MANIFEST_CACHE do
            local oldest = table.remove(order, 1)
            cache[oldest] = nil
        end
        table.insert(order, key)
    end
    cache[key] = entry
end

local function removeOrderKey(order, key)
    for i = #order, 1, -1 do
        if order[i] == key then
            table.remove(order, i)
        end
    end
end

function EpubHelper.invalidateCache(epub_path)
    if not epub_path then
        _manifest_cache = {}
        _manifest_order = {}
        _sidecar_cache = {}
        _sidecar_order = {}
        return
    end
    local norm = normalizePath(epub_path)
    if _manifest_cache[norm] then
        _manifest_cache[norm] = nil
        removeOrderKey(_manifest_order, norm)
    end
    if _sidecar_cache[norm] then
        _sidecar_cache[norm] = nil
        removeOrderKey(_sidecar_order, norm)
    end
end

local function u16(s, idx)
    local b1, b2 = s:byte(idx, idx + 1)
    if not b2 then
        return nil
    end
    return b1 + b2 * 256
end

local function u32(s, idx)
    local b1, b2, b3, b4 = s:byte(idx, idx + 3)
    if not b4 then
        return nil
    end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function normalizePath(path)
    if type(path) ~= "string" then
        return ""
    end
    local clean = path:gsub("//+", "/")
    if #clean > 1 and clean:sub(-1) == "/" then
        clean = clean:sub(1, -2)
    end
    return clean
end

function EpubHelper.isEpub(path)
    return type(path) == "string" and path:lower():sub(-5) == ".epub"
end

-- Locate and decode META-INF/tsundoku.json via the ZIP End-of-Central-Directory
-- and Central Directory records so >64KB Central Directories work reliably.
function EpubHelper.readManifest(epub_path)
    if not EpubHelper.isEpub(epub_path) then
        return nil, "not an epub path"
    end
    local norm = normalizePath(epub_path)
    local attr = ok_lfs and lfs and lfs.attributes(norm)
    if attr and attr.mode == "file" then
        local cached = _manifest_cache[norm]
        if cached and cached.mtime == attr.modification and cached.size == attr.size then
            return cached.manifest
        end
    end
    local f, err = io.open(epub_path, "rb")
    if not f then
        return nil, err
    end
    local size = f:seek("end")
    if not size or size < 22 then
        f:close()
        return nil, "invalid zip archive"
    end

    local tail_len = math.min(size, 65557)
    f:seek("set", size - tail_len)
    local tail = f:read(tail_len)
    if not tail or #tail < 22 then
        f:close()
        return nil, "failed reading zip tail"
    end

    local eocd_pos
    for pos = #tail - 21, 1, -1 do
        if tail:byte(pos) == 0x50
            and tail:byte(pos + 1) == 0x4b
            and tail:byte(pos + 2) == 0x05
            and tail:byte(pos + 3) == 0x06
        then
            local comment_len = u16(tail, pos + 20)
            if comment_len and (pos + 21 + comment_len == #tail) then
                eocd_pos = pos
                break
            end
        end
    end
    if not eocd_pos then
        f:close()
        return nil, "EOCD record not found"
    end

    local cd_size = u32(tail, eocd_pos + 12)
    local cd_offset = u32(tail, eocd_pos + 16)
    if not cd_size or not cd_offset or cd_size == 0 or cd_offset + cd_size > size then
        f:close()
        return nil, "invalid central directory bounds"
    end

    f:seek("set", cd_offset)
    local cd = f:read(cd_size)
    if not cd or #cd < cd_size then
        f:close()
        return nil, "failed reading central directory"
    end

    local off = 1
    while off + 45 <= #cd do
        if cd:sub(off, off + 3) ~= "PK\1\2" then
            break
        end
        local comp_method = u16(cd, off + 10)
        local uncomp_size = u32(cd, off + 24)
        local name_len = u16(cd, off + 28)
        local extra_len = u16(cd, off + 30)
        local comment_len = u16(cd, off + 32)
        local local_off = u32(cd, off + 42)
        local name = cd:sub(off + 46, off + 45 + name_len)

        if name == MANIFEST_ENTRY then
            if comp_method ~= 0 then
                f:close()
                return nil, "compressed manifest not supported"
            end
            f:seek("set", local_off)
            local lh = f:read(30)
            if not lh or #lh < 30 or lh:sub(1, 4) ~= "PK\3\4" then
                f:close()
                return nil, "invalid local file header"
            end
            local lh_name_len = u16(lh, 27)
            local lh_extra_len = u16(lh, 29)
            local data_off = local_off + 30 + lh_name_len + lh_extra_len
            f:seek("set", data_off)
            local raw = f:read(uncomp_size)
            f:close()
            if not raw or #raw < uncomp_size then
                return nil, "truncated manifest entry"
            end
            local ok_dec, manifest = pcall(json.decode, raw)
            if not ok_dec or type(manifest) ~= "table" then
                return nil, "invalid manifest json"
            end
            if attr and attr.mode == "file" then
                cachePut(_manifest_cache, _manifest_order, norm, {
                    mtime = attr.modification,
                    size = attr.size,
                    manifest = manifest,
                })
            end
            return manifest
        end

        off = off + 46 + name_len + extra_len + comment_len
    end

    f:close()
    return nil, "manifest entry not found"
end

function EpubHelper.manifestKeys(manifest)
    local keys = {}
    if type(manifest) == "table" and type(manifest.chapters) == "table" then
        for _idx, ch in ipairs(manifest.chapters) do
            if type(ch) == "table" and type(ch.key) == "string" and ch.key ~= "" then
                table.insert(keys, ch.key)
            end
        end
    end
    return keys
end

function EpubHelper.chapterDocFragmentIndex(manifest, chapter_key)
    if type(manifest) ~= "table" or type(manifest.chapters) ~= "table" or type(chapter_key) ~= "string" then
        return nil
    end
    local map = manifest._key_to_idx
    if not map then
        map = {}
        for idx, ch in ipairs(manifest.chapters) do
            if type(ch) == "table" and type(ch.key) == "string" and ch.key ~= "" and not map[ch.key] then
                map[ch.key] = idx
            end
        end
        manifest._key_to_idx = map
    end
    return map[chapter_key]
end

function EpubHelper.chapterAtDocFragmentIndex(manifest, idx)
    if type(manifest) ~= "table" or type(manifest.chapters) ~= "table" or type(idx) ~= "number" then
        return nil
    end
    return manifest.chapters[idx]
end

function EpubHelper.parseDocFragmentIndex(xpointer)
    if type(xpointer) ~= "string" then
        return nil
    end
    local idx_str = xpointer:match("^/body/DocFragment%[(%d+)%]")
    if idx_str then
        return tonumber(idx_str)
    end
    if xpointer == "/body/DocFragment" or xpointer:match("^/body/DocFragment/") then
        return 1
    end
    return nil
end

local function splitXPointer(xp)
    if type(xp) ~= "string" then
        return nil, nil
    end
    local idx_str, suffix = xp:match("^/body/DocFragment%[(%d+)%](.*)$")
    if idx_str and (suffix == "" or suffix:sub(1, 1) == "/") then
        return tonumber(idx_str), suffix
    end
    local bare_suffix = xp:match("^/body/DocFragment(/.*)$")
    if bare_suffix then
        return 1, bare_suffix
    end
    if xp == "/body/DocFragment" then
        return 1, ""
    end
    return nil, nil
end

-- Mirrors epub.RemapXPointerString in Go so XPointers in non-adjacent
-- DocSettings ("dir" / "hash" modes) remap identically to <stem>.sdr.
function EpubHelper.remapXPointer(xp, old_keys, new_keys)
    if type(xp) ~= "string" or type(old_keys) ~= "table" or type(new_keys) ~= "table"
        or #old_keys == 0 or #new_keys == 0
    then
        return xp
    end
    local old_idx, suffix = splitXPointer(xp)
    if not old_idx or old_idx < 1 or old_idx > #old_keys then
        return xp
    end

    local new_index = {}
    for i, k in ipairs(new_keys) do
        new_index[k] = i
    end

    local key = old_keys[old_idx]
    local target = new_index[key]
    if target then
        return string.format("/body/DocFragment[%d]%s", target, suffix)
    end

    for i = old_idx + 1, #old_keys do
        local fallback = new_index[old_keys[i]]
        if fallback then
            return string.format("/body/DocFragment[%d]/body", fallback)
        end
    end
    return string.format("/body/DocFragment[%d]/body", #new_keys)
end

local function keysShifted(old_keys, new_keys)
    if type(old_keys) ~= "table" or type(new_keys) ~= "table" or #old_keys == 0 or #new_keys == 0 then
        return false
    end
    if #new_keys < #old_keys then
        return true
    end
    for i = 1, #old_keys do
        if old_keys[i] ~= new_keys[i] then
            return true
        end
    end
    return false
end

function EpubHelper.sidecarDirAdjacent(epub_path)
    if type(epub_path) ~= "string" or epub_path == "" then
        return ""
    end
    local base = epub_path:gsub("%.[^/%.]+$", "")
    if base == "" then
        base = epub_path
    end
    return normalizePath(base .. ".sdr")
end

-- Returns true when KOReader stores this book's sidecar next to the .epub file
-- (<stem>.sdr/metadata.epub.lua), which Go's RemapAdjacentSDR already updates.
function EpubHelper.usesAdjacentSidecar(epub_path)
    if ok_ds and DocSettings and DocSettings.getSidecarDir then
        local ok_dir, dir = pcall(DocSettings.getSidecarDir, DocSettings, epub_path)
        if ok_dir and type(dir) == "string" and dir ~= "" then
            return normalizePath(dir) == EpubHelper.sidecarDirAdjacent(epub_path)
        end
    end
    if G_reader_settings and G_reader_settings.readSetting then
        return G_reader_settings:readSetting("document_metadata_folder", "doc") == "doc"
    end
    return true
end

local function remapValueXPointers(val, old_keys, new_keys)
    local t = type(val)
    if t == "string" then
        if val:sub(1, 17) == "/body/DocFragment" then
            local remapped = EpubHelper.remapXPointer(val, old_keys, new_keys)
            return remapped, remapped ~= val
        end
        return val, false
    elseif t == "table" then
        local changed = false
        for k, v in pairs(val) do
            local new_v, sub_changed = remapValueXPointers(v, old_keys, new_keys)
            if sub_changed then
                val[k] = new_v
                changed = true
            end
        end
        return val, changed
    end
    return val, false
end

local function openExistingDocSettings(epub_path)
    if not ok_ds or not DocSettings or not DocSettings.open then
        return nil
    end
    if DocSettings.getSidecarFile and ok_lfs and lfs then
        local ok_sf, sf = pcall(DocSettings.getSidecarFile, DocSettings, epub_path)
        if ok_sf and type(sf) == "string" and sf ~= "" then
            if lfs.attributes(sf, "mode") ~= "file" then
                return nil
            end
        end
    end
    local ok_open, ds = pcall(DocSettings.open, DocSettings, epub_path)
    if not ok_open or not ds then
        return nil
    end
    return ds
end

-- Updates KOReader DocSettings XPointers when spine indices changed and the
-- sidecar is not already owned on-disk by Go's RemapAdjacentSDR.
function EpubHelper.remapDocSettings(epub_path, old_keys, new_keys, sdr_already_remapped)
    if not EpubHelper.isEpub(epub_path) or not keysShifted(old_keys, new_keys) then
        return false
    end
    local adjacent = EpubHelper.usesAdjacentSidecar(epub_path)
    if adjacent and sdr_already_remapped ~= false then
        -- Go's UpsertChapters and RemoveChapters always call RemapAdjacentSDR on
        -- <stem>.sdr/metadata.epub.lua; skipping here prevents double-remapping.
        return false
    end
    local ds = openExistingDocSettings(epub_path)
    if not ds or type(ds.data) ~= "table" or next(ds.data) == nil then
        return false
    end

    local changed = false
    for _, key in ipairs({ "last_xpointer", "bookmarks", "annotations" }) do
        local v = ds:readSetting(key)
        if v ~= nil then
            local new_v, c = remapValueXPointers(v, old_keys, new_keys)
            if c then
                ds:saveSetting(key, new_v)
                changed = true
            end
        end
    end
    if changed and ds.flush then
        pcall(ds.flush, ds)
        EpubHelper.invalidateCache(epub_path)
    end
    return changed
end

function EpubHelper.currentXPointer(epub_path, ui)
    local norm = normalizePath(epub_path)
    if ui and ui.document and normalizePath(ui.document.file) == norm then
        local pct
        if ui.doc_settings and ui.doc_settings.readSetting then
            local ok_p, p = pcall(ui.doc_settings.readSetting, ui.doc_settings, "percent_finished")
            if ok_p then
                pct = tonumber(p)
            end
        end
        if ui.document.getXPointer then
            local ok_xp, xp = pcall(ui.document.getXPointer, ui.document)
            if ok_xp and type(xp) == "string" and xp ~= "" then
                return xp, pct
            end
        end
        if ui.doc_settings and ui.doc_settings.readSetting then
            local ok_xp, xp = pcall(ui.doc_settings.readSetting, ui.doc_settings, "last_xpointer")
            if ok_xp and type(xp) == "string" and xp ~= "" then
                return xp, pct
            end
        end
    end

    if not ok_ds or not DocSettings or not DocSettings.open then
        return nil, nil
    end
    local sf
    local cached = _sidecar_cache[norm]
    if cached and cached.sf then
        sf = cached.sf
    elseif DocSettings.getSidecarFile then
        local ok_sf, resolved = pcall(DocSettings.getSidecarFile, DocSettings, epub_path)
        if ok_sf and type(resolved) == "string" and resolved ~= "" then
            sf = resolved
        end
    end
    if sf and ok_lfs and lfs then
        local attr = lfs.attributes(sf)
        if not attr or attr.mode ~= "file" then
            if cached then
                _sidecar_cache[norm] = nil
                removeOrderKey(_sidecar_order, norm)
            end
            return nil, nil
        end
        if cached and cached.sf == sf and cached.mtime == attr.modification and cached.size == attr.size then
            return cached.xp, cached.pct
        end
        local ok_open, ds = pcall(DocSettings.open, DocSettings, epub_path)
        if not ok_open or not ds then
            return nil, nil
        end
        local xp_raw = ds:readSetting("last_xpointer")
        local xp = (type(xp_raw) == "string" and xp_raw ~= "") and xp_raw or nil
        local pct = tonumber(ds:readSetting("percent_finished"))
        cachePut(_sidecar_cache, _sidecar_order, norm, {
            sf = sf,
            mtime = attr.modification,
            size = attr.size,
            xp = xp,
            pct = pct,
        })
        return xp, pct
    end

    local ds = openExistingDocSettings(epub_path)
    if not ds then
        return nil, nil
    end
    local xp = ds:readSetting("last_xpointer")
    local pct = tonumber(ds:readSetting("percent_finished"))
    return (type(xp) == "string" and xp ~= "") and xp or nil, pct
end

-- Marks chapters up to the reader's current /body/DocFragment[k] position as read
-- in Tsundoku's store (strictly prior chapters mid-book; inclusive at end of book).
function EpubHelper.syncReadChapters(epub_path, store, source_key, manga_key, opts)
    opts = opts or {}
    if not EpubHelper.isEpub(epub_path) or not store or not source_key or not manga_key then
        return 0
    end
    local xp, pct = EpubHelper.currentXPointer(epub_path, opts.ui)
    local idx = EpubHelper.parseDocFragmentIndex(xp)
    if not idx and not (opts.inclusive and pct and pct >= 0.98) then
        return 0
    end
    local manifest = EpubHelper.readManifest(epub_path)
    if not manifest or type(manifest.chapters) ~= "table" or #manifest.chapters == 0 then
        return 0
    end
    if not idx then
        idx = #manifest.chapters
    end

    local max_idx
    if opts.inclusive or (pct and pct >= 0.99 and idx >= #manifest.chapters) then
        max_idx = math.min(idx, #manifest.chapters)
    else
        max_idx = math.min(idx - 1, #manifest.chapters)
    end
    if max_idx < 1 then
        return 0
    end

    local to_mark = {}
    for i = 1, max_idx do
        local ch = manifest.chapters[i]
        if type(ch) == "table" and type(ch.key) == "string" and ch.key ~= "" then
            if not store:isChapterRead(source_key, manga_key, ch.key) then
                table.insert(to_mark, ch.key)
            end
        end
    end
    if #to_mark == 0 then
        return 0
    end
    if store.markChaptersReadBatch then
        store:markChaptersReadBatch(source_key, manga_key, to_mark)
    else
        for _i, key in ipairs(to_mark) do
            store:markChapterRead(source_key, manga_key, key)
        end
    end
    return #to_mark
end

-- Resolves the XPointer for chapter_key and persists last_xpointer in DocSettings
-- before opening the EPUB. With opts.preserve_if_matching, keeps an existing
-- XPointer already inside the target DocFragment so Continue restores exact scroll.
function EpubHelper.prepareJumpToChapter(epub_path, chapter_key, opts)
    opts = opts or {}
    if not EpubHelper.isEpub(epub_path) or type(chapter_key) ~= "string" or chapter_key == "" then
        return nil
    end
    local manifest = EpubHelper.readManifest(epub_path)
    if not manifest then
        return nil
    end
    local target_idx = EpubHelper.chapterDocFragmentIndex(manifest, chapter_key)
    if not target_idx then
        return nil
    end
    local target_xp = string.format("/body/DocFragment[%d]/body", target_idx)

    if opts.preserve_if_matching then
        local cur_xp = EpubHelper.currentXPointer(epub_path, opts.ui)
        local cur_idx = EpubHelper.parseDocFragmentIndex(cur_xp)
        if cur_idx == target_idx and type(cur_xp) == "string" and cur_xp ~= "" then
            return cur_xp, target_idx, true
        end
    end

    if ok_ds and DocSettings and DocSettings.open then
        local ok_open, ds = pcall(DocSettings.open, DocSettings, epub_path)
        if ok_open and ds then
            ds:saveSetting("last_xpointer", target_xp)
            if ds.flush then
                pcall(ds.flush, ds)
                EpubHelper.invalidateCache(epub_path)
            end
        end
    end
    return target_xp, target_idx, false
end

function EpubHelper.jumpOpenDocument(ui, xpointer)
    if not ui or type(xpointer) ~= "string" or xpointer == "" then
        return false
    end
    local ok_ev, Event = pcall(require, "ui/event")
    if ok_ev and Event and ui.handleEvent then
        ui:handleEvent(Event:new("GotoXPointer", xpointer))
        return true
    end
    return false
end

return EpubHelper
