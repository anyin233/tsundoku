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

EpubHelper.CHAPTERS_PER_VOLUME = 50
EpubHelper.BOOK_INDEX_FILE = ".tsundoku_book.json"

local MANIFEST_ENTRY = "META-INF/tsundoku.json"
local MAX_MANIFEST_CACHE = 16
local _manifest_cache = {}
local _manifest_order = {}
local _sidecar_cache = {}
local _sidecar_order = {}
local _book_index_cache = {}
local _book_index_order = {}

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
        _book_index_cache = {}
        _book_index_order = {}
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
    if _book_index_cache[norm] then
        _book_index_cache[norm] = nil
        removeOrderKey(_book_index_order, norm)
    end
    local dir = norm:match("^(.*)/[^/]+$")
    if dir and _book_index_cache[dir] then
        _book_index_cache[dir] = nil
        removeOrderKey(_book_index_order, dir)
    end
end

function EpubHelper.isEpub(path)
    return type(path) == "string" and path:lower():sub(-5) == ".epub"
end

function EpubHelper.volumeIndexForOrder(toc_order, volume_size)
    local vsz = (type(volume_size) == "number" and volume_size > 0)
        and math.floor(volume_size) or EpubHelper.CHAPTERS_PER_VOLUME
    local ord = (type(toc_order) == "number" and toc_order >= 1)
        and math.floor(toc_order) or 1
    return math.floor((ord - 1) / vsz) + 1
end

function EpubHelper.isLegacyOversizedEpub(epub_path)
    if not EpubHelper.isEpub(epub_path) then
        return false, nil
    end
    local manifest = EpubHelper.readManifest(epub_path)
    if type(manifest) ~= "table" or type(manifest.chapters) ~= "table" then
        return false, nil
    end
    local vol_idx = tonumber(manifest.volumeIndex) or 0
    if vol_idx == 0 and #manifest.chapters > EpubHelper.CHAPTERS_PER_VOLUME then
        return true, manifest
    end
    return false, manifest
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

local function normalizeBookIndex(dir, raw_idx)
    if type(raw_idx) ~= "table" or type(raw_idx.volumes) ~= "table" then
        return nil
    end
    local volumes = {}
    local flat_chapters = {}
    local chapter_by_key = {}
    local global_idx = 0

    for vi, v in ipairs(raw_idx.volumes) do
        if type(v) == "table" and type(v.file) == "string" and v.file ~= "" and type(v.chapters) == "table" then
            local v_path = normalizePath(dir .. "/" .. v.file)
            local v_idx = tonumber(v.volumeIndex) or vi
            local v_start = tonumber(v.volumeStart) or 0
            local v_end = tonumber(v.volumeEnd) or 0
            local v_chapters = {}
            local first_global = global_idx + 1
            for ci, ch in ipairs(v.chapters) do
                if type(ch) == "table" and type(ch.key) == "string" and ch.key ~= "" then
                    global_idx = global_idx + 1
                    local frag_idx = tonumber(ch.fragIndex) or ci
                    local entry = {
                        key = ch.key,
                        title = (type(ch.title) == "string" and ch.title ~= "") and ch.title or ch.key,
                        tocOrder = tonumber(ch.tocOrder) or 0,
                        volumeIndex = v_idx,
                        volumeStart = v_start,
                        volumeEnd = v_end,
                        epubPath = v_path,
                        fragIndex = frag_idx,
                        globalIndex = global_idx,
                    }
                    table.insert(v_chapters, entry)
                    table.insert(flat_chapters, entry)
                    if not chapter_by_key[ch.key] then
                        chapter_by_key[ch.key] = entry
                    end
                end
            end
            if #v_chapters > 0 then
                table.insert(volumes, {
                    volumeIndex = v_idx,
                    volumeStart = v_start,
                    volumeEnd = v_end,
                    file = v.file,
                    path = v_path,
                    firstGlobalIndex = first_global,
                    chapters = v_chapters,
                })
            end
        end
    end

    if #volumes == 0 or #flat_chapters == 0 then
        return nil
    end

    return {
        sourceKey = type(raw_idx.sourceKey) == "string" and raw_idx.sourceKey or "",
        mangaKey = type(raw_idx.mangaKey) == "string" and raw_idx.mangaKey or "",
        title = type(raw_idx.title) == "string" and raw_idx.title or "",
        volumeSize = tonumber(raw_idx.volumeSize) or EpubHelper.CHAPTERS_PER_VOLUME,
        volumes = volumes,
        chapters = flat_chapters,
        chapter_by_key = chapter_by_key,
    }
end

local function bookManifestMatchesIdentity(m, cur_manifest)
    if not cur_manifest then
        return true
    end
    local sk = type(cur_manifest.sourceKey) == "string" and cur_manifest.sourceKey or ""
    local mk = type(cur_manifest.mangaKey) == "string" and cur_manifest.mangaKey or ""
    if sk ~= "" and mk ~= "" then
        return m.sourceKey == sk and m.mangaKey == mk
    end
    local title = type(cur_manifest.title) == "string" and cur_manifest.title or ""
    if title ~= "" then
        return m.title == title
    end
    return true
end

-- Reads <bookDir>/.tsundoku_book.json (with mtime/size/directory cache) and
-- falls back to scanning sibling EPUB manifests if the sidecar is missing or stale.
function EpubHelper.readBookIndex(epub_path, _downloads_engine)
    if not EpubHelper.isEpub(epub_path) or not ok_lfs or not lfs then
        return nil
    end
    local norm = normalizePath(epub_path)
    local dir = norm:match("^(.*)/[^/]+$")
    if not dir or dir == "" or lfs.attributes(dir, "mode") ~= "directory" then
        return nil
    end

    local epub_files = {}
    local epub_count = 0
    local ok_dir, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok_dir or not iter then
        return nil
    end
    for fname in iter, dir_obj do
        if fname ~= "." and fname ~= ".." and fname:sub(1, 1) ~= "." and EpubHelper.isEpub(fname) then
            epub_files[fname] = true
            epub_count = epub_count + 1
        end
    end
    if epub_count == 0 then
        return nil
    end

    local idx_path = dir .. "/" .. EpubHelper.BOOK_INDEX_FILE
    local idx_attr = lfs.attributes(idx_path)
    local cached = _book_index_cache[dir]
    if cached and cached.epub_count == epub_count then
        if (idx_attr and idx_attr.mode == "file"
            and cached.mtime == idx_attr.modification and cached.size == idx_attr.size)
            or (not idx_attr and not cached.mtime)
        then
            local all_present = true
            for _vi, v in ipairs(cached.book.volumes) do
                if not epub_files[v.file] then
                    all_present = false
                    break
                end
            end
            if all_present then
                return cached.book
            end
        end
    end

    if idx_attr and idx_attr.mode == "file" then
        local f = io.open(idx_path, "rb")
        if f then
            local raw = f:read("*a")
            f:close()
            local ok_dec, decoded = pcall(json.decode, raw)
            if ok_dec and type(decoded) == "table" and type(decoded.volumes) == "table"
                and #decoded.volumes == epub_count
            then
                local all_present = true
                for _vi, v in ipairs(decoded.volumes) do
                    if type(v) ~= "table" or type(v.file) ~= "string" or not epub_files[v.file] then
                        all_present = false
                        break
                    end
                end
                if all_present then
                    local book = normalizeBookIndex(dir, decoded)
                    if book then
                        cachePut(_book_index_cache, _book_index_order, dir, {
                            mtime = idx_attr.modification,
                            size = idx_attr.size,
                            epub_count = epub_count,
                            book = book,
                        })
                        return book
                    end
                end
            end
        end
    end

    -- Self-healing fallback: scan sibling EPUB manifests in dir.
    local cur_manifest = EpubHelper.readManifest(norm)
    local scanned_vols = {}
    local raw_meta = {
        sourceKey = cur_manifest and cur_manifest.sourceKey or "",
        mangaKey = cur_manifest and cur_manifest.mangaKey or "",
        title = cur_manifest and cur_manifest.title or "",
        volumeSize = (cur_manifest and tonumber(cur_manifest.volumeSize)) or EpubHelper.CHAPTERS_PER_VOLUME,
        volumes = scanned_vols,
    }

    for fname in pairs(epub_files) do
        local m = EpubHelper.readManifest(dir .. "/" .. fname)
        if type(m) == "table" and type(m.chapters) == "table" and #m.chapters > 0
            and bookManifestMatchesIdentity(m, cur_manifest)
        then
            if raw_meta.sourceKey == "" and type(m.sourceKey) == "string" then
                raw_meta.sourceKey = m.sourceKey
            end
            if raw_meta.mangaKey == "" and type(m.mangaKey) == "string" then
                raw_meta.mangaKey = m.mangaKey
            end
            if raw_meta.title == "" and type(m.title) == "string" then
                raw_meta.title = m.title
            end
            if tonumber(m.volumeSize) and tonumber(m.volumeSize) > 0 then
                raw_meta.volumeSize = tonumber(m.volumeSize)
            end

            local v_idx = tonumber(m.volumeIndex) or 0
            local v_size = tonumber(m.volumeSize) or raw_meta.volumeSize or EpubHelper.CHAPTERS_PER_VOLUME
            local v_start = tonumber(m.volumeStart) or 0
            local v_end = tonumber(m.volumeEnd) or 0
            if v_idx > 0 and (v_start <= 0 or v_end < v_start) then
                v_start = (v_idx - 1) * v_size + 1
                v_end = v_idx * v_size
            end

            local chs = {}
            for ci, ch in ipairs(m.chapters) do
                if type(ch) == "table" and type(ch.key) == "string" and ch.key ~= "" then
                    table.insert(chs, {
                        key = ch.key,
                        title = ch.title,
                        tocOrder = tonumber(ch.tocOrder) or 0,
                        fragIndex = ci,
                    })
                end
            end
            if #chs > 0 then
                table.insert(scanned_vols, {
                    volumeIndex = v_idx,
                    volumeStart = v_start,
                    volumeEnd = v_end,
                    file = fname,
                    chapters = chs,
                })
            end
        end
    end

    if #scanned_vols == 0 then
        return nil
    end

    table.sort(scanned_vols, function(a, b)
        local az = (a.volumeIndex == 0)
        local bz = (b.volumeIndex == 0)
        if az ~= bz then
            return not az
        end
        local ao = a.chapters[1] and a.chapters[1].tocOrder or 0
        local bo = b.chapters[1] and b.chapters[1].tocOrder or 0
        if ao > 0 and bo > 0 and ao ~= bo then
            return ao < bo
        end
        if a.volumeIndex ~= b.volumeIndex then
            return a.volumeIndex < b.volumeIndex
        end
        return a.file < b.file
    end)

    local book = normalizeBookIndex(dir, raw_meta)
    if book then
        cachePut(_book_index_cache, _book_index_order, dir, {
            mtime = nil,
            size = nil,
            epub_count = epub_count,
            book = book,
        })
    end
    return book
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

local TYPOGRAPHY_EXACT_KEYS = {
    "font_face",
    "font_family_fonts",
    "css",
    "cre_dom_version",
    "floating_punctuation",
    "hyphenation",
    "hyph_force_algorithmic",
    "hyph_soft_hyphens_only",
    "hyph_trust_soft_hyphens",
    "text_lang",
    "text_lang_embedded_langs",
    "partial_rerendering",
}

local function cloneSettingValue(v)
    if type(v) ~= "table" then
        return v
    end
    local copy = {}
    for k, sv in pairs(v) do
        copy[k] = cloneSettingValue(sv)
    end
    return copy
end

-- Copies typography/layout preferences from an already-configured volume's
-- DocSettings onto a brand-new volume's DocSettings so jumping across volumes
-- keeps the reader's font, margins, spacing, and CSS consistent.
function EpubHelper.copyTypographySettings(src_ds, dst_ds)
    if type(src_ds) ~= "table" or type(dst_ds) ~= "table" or type(src_ds.data) ~= "table" then
        return false
    end
    if dst_ds:readSetting("doc_pages") ~= nil or dst_ds:readSetting("font_face") ~= nil then
        return false
    end
    local copied = false
    for _idx, key in ipairs(TYPOGRAPHY_EXACT_KEYS) do
        local v = src_ds.data[key]
        if v ~= nil then
            dst_ds:saveSetting(key, cloneSettingValue(v))
            copied = true
        end
    end
    for k, v in pairs(src_ds.data) do
        if type(k) == "string" and k:sub(1, 5) == "copt_" and v ~= nil then
            dst_ds:saveSetting(k, cloneSettingValue(v))
            copied = true
        end
    end
    return copied
end

-- Resolves the XPointer for chapter_key and persists last_xpointer in DocSettings
-- before opening the EPUB. With opts.preserve_if_matching, keeps an existing
-- XPointer already inside the target DocFragment so Continue restores exact scroll.
function EpubHelper.prepareJumpToChapter(epub_path, chapter_key, opts)
    opts = opts or {}
    if not EpubHelper.isEpub(epub_path) or type(chapter_key) ~= "string" or chapter_key == "" then
        return nil
    end
    local target_idx = tonumber(opts.frag_index)
    if not target_idx or target_idx < 1 then
        local manifest = EpubHelper.readManifest(epub_path)
        if not manifest then
            return nil
        end
        target_idx = EpubHelper.chapterDocFragmentIndex(manifest, chapter_key)
    end
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
            if opts.sync_typography_from then
                EpubHelper.copyTypographySettings(opts.sync_typography_from, ds)
            end
            if ds:readSetting("cre_dom_version") == nil then
                local ok_cre, cre_doc = pcall(require, "document/credocument")
                if ok_cre and cre_doc and type(cre_doc.engineInit) == "function" then
                    local ok_init, cre = pcall(cre_doc.engineInit, cre_doc)
                    if ok_init and cre and type(cre.getLatestDomVersion) == "function" then
                        local ok_ver, latest_ver = pcall(cre.getLatestDomVersion)
                        if ok_ver and type(latest_ver) == "number" and latest_ver > 0 then
                            ds:saveSetting("cre_dom_version", latest_ver)
                        end
                    end
                end
            end
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
