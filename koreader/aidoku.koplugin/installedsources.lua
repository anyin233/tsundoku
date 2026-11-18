--[[--
Lists installed .aix sources in a sources directory, as
{text = "<display name> (<languages>)", mandatory = "v<version>",
name = "<display name>", path = "<sources_dir>/<file>.aix",
key = "<source's manifest id>, or nil if unreadable>", version = <int, or nil if unreadable>}
entries -- shared by sourcesbrowser.lua, globalsearchbrowser.lua,
librarybrowser.lua (findByKey), and repobrowser.lua.

Manifests are cached in memory and persisted under settings (`aidoku_manifests_cache.lua`)
keyed by (path, modification, size). Cache misses read `Payload/source.json` directly
in-process via `ffi/archiver` (falling back to `engine:manifests` only if libarchive is
unavailable), reducing listing 20+ installed sources from a ~310ms subprocess spawn
to <2ms warm / <5ms cold with zero UI stalls or blocking io.popen warnings.
]]

local json = require("json")
local lfs = require("libs/libkoreader-lfs")

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_ls, LuaSettings = pcall(require, "luasettings")
local ok_arch, Archiver = pcall(require, "ffi/archiver")

local MAX_MANIFEST_BYTES = 262144

local InstalledSources = {}

-- path -> { mtime = number, size = number, manifest = table|false }
local manifest_cache = {}
local persisted_loaded = false
local persisted_store = nil

-- sources_dir -> { dir_mtime = number, list = array, by_key = map }
local dir_cache = {}

local function getPersistedStore()
    if persisted_loaded then
        return persisted_store
    end
    persisted_loaded = true
    if ok_ds and DataStorage and ok_ls and LuaSettings then
        local ok, st = pcall(LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/aidoku_manifests_cache.lua")
        if ok and st then
            persisted_store = st
            local saved = st:readSetting("entries")
            if type(saved) == "table" then
                for k, v in pairs(saved) do
                    if type(k) == "string" and type(v) == "table" and not manifest_cache[k] then
                        manifest_cache[k] = {
                            mtime = tonumber(v.mtime) or 0,
                            size = tonumber(v.size) or 0,
                            manifest = type(v.manifest) == "table" and v.manifest or false,
                        }
                    end
                end
            end
        end
    end
    return persisted_store
end

local function flushPersistedStore()
    local st = getPersistedStore()
    if not st then
        return
    end
    local dump = {}
    for k, v in pairs(manifest_cache) do
        if type(v) == "table" then
            dump[k] = {
                mtime = v.mtime,
                size = v.size,
                manifest = type(v.manifest) == "table" and v.manifest or false,
            }
        end
    end
    st:saveSetting("entries", dump)
    st:flush()
end

local function parseManifestJSON(raw)
    if type(raw) ~= "string" or raw == "" or #raw > MAX_MANIFEST_BYTES then
        return nil
    end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    local info = (type(decoded.info) == "table" and decoded.info) or decoded
    local key = type(info.id) == "string" and info.id
        or (type(info.key) == "string" and info.key) or ""
    if key == "" then
        return nil
    end
    local name = type(info.name) == "string" and info.name or ""
    local version = type(info.version) == "number" and math.floor(info.version) or tonumber(info.version)
    local languages = nil
    if type(info.languages) == "table" then
        languages = {}
        for _idx, lang in ipairs(info.languages) do
            if type(lang) == "string" and lang ~= "" then
                table.insert(languages, lang)
            end
        end
        if #languages == 0 then
            languages = nil
        end
    elseif type(info.lang) == "string" and info.lang ~= "" then
        languages = { info.lang }
    end
    return {
        key = key,
        name = name,
        version = version,
        languages = languages,
    }
end

local function readManifestInProcess(aix_path)
    if lfs.attributes(aix_path, "mode") == "directory" then
        for _idx, rel in ipairs({ "/Payload/source.json", "/source.json" }) do
            local f = io.open(aix_path .. rel, "rb")
            if f then
                local raw = f:read("*a")
                f:close()
                local parsed = parseManifestJSON(raw)
                if parsed then
                    return parsed
                end
            end
        end
        return nil
    end
    if not (ok_arch and Archiver and Archiver.Reader) then
        return nil
    end
    local reader = Archiver.Reader:new()
    if not reader:open(aix_path) then
        reader:close()
        return nil
    end
    local raw = nil
    for entry in reader:iterate() do
        if entry.mode == "file" and type(entry.path) == "string" then
            local p = entry.path:gsub("^%./", "")
            local sz = tonumber(entry.size) or 0
            if (p == "Payload/source.json" or p == "source.json") and sz > 0 and sz <= MAX_MANIFEST_BYTES then
                raw = reader:extractToMemory(entry.path)
                break
            end
        end
    end
    reader:close()
    return parseManifestJSON(raw)
end

local function displayName(filename, manifest)
    if not manifest or type(manifest.name) ~= "string" or manifest.name == "" then
        return filename:gsub("%.aix$", "")
    end
    return manifest.name
end

local function displayText(name, manifest)
    local langs = manifest and type(manifest.languages) == "table" and table.concat(manifest.languages, ", ") or ""
    return langs ~= "" and (name .. " (" .. langs .. ")") or name
end

local function buildEntry(filename, path, manifest)
    local key = nil
    if manifest and type(manifest.key) == "string" and manifest.key ~= "" then
        key = manifest.key
    end
    local name = displayName(filename, manifest)
    local version = manifest and type(manifest.version) == "number" and manifest.version or nil
    return {
        text = displayText(name, manifest),
        mandatory = version and ("v" .. tostring(version)) or nil,
        name = name,
        path = path,
        key = key,
        version = version,
    }
end

function InstalledSources.invalidateCache()
    manifest_cache = {}
    dir_cache = {}
    persisted_loaded = true
end

function InstalledSources.list(sources_dir, engine)
    if type(sources_dir) ~= "string" or sources_dir == "" then
        return {}
    end
    getPersistedStore()

    local dir_attr = lfs.attributes(sources_dir)
    if not dir_attr or dir_attr.mode ~= "directory" then
        return {}
    end
    local dir_mtime = dir_attr.modification or 0

    local cached_dir = dir_cache[sources_dir]
    if cached_dir and cached_dir.dir_mtime == dir_mtime and dir_mtime > 0
        and math.abs(os.difftime(os.time(), dir_mtime)) > 2
    then
        local valid = true
        for _idx, f in ipairs(cached_dir.files) do
            local attr = lfs.attributes(f.path)
            if not attr or (attr.modification or 0) ~= f.mtime or (attr.size or 0) ~= f.size then
                valid = false
                break
            end
        end
        if valid then
            local copy = {}
            for i, s in ipairs(cached_dir.list) do
                copy[i] = s
            end
            return copy
        end
    end

    local files = {}
    local any_miss = false
    for entry in lfs.dir(sources_dir) do
        if entry:match("%.aix$") then
            local path = sources_dir .. "/" .. entry
            local attr = lfs.attributes(path)
            local mtime = attr and attr.modification or 0
            local size = attr and attr.size or 0
            local cached = manifest_cache[path]
            if not cached or cached.mtime ~= mtime or cached.size ~= size then
                any_miss = true
            end
            table.insert(files, { entry = entry, path = path, mtime = mtime, size = size })
        end
    end

    if any_miss then
        local unresolved = {}
        local cache_updated = false
        for _idx, f in ipairs(files) do
            local cached = manifest_cache[f.path]
            if not cached or cached.mtime ~= f.mtime or cached.size ~= f.size then
                local m = readManifestInProcess(f.path)
                if m then
                    manifest_cache[f.path] = {
                        mtime = f.mtime,
                        size = f.size,
                        manifest = m,
                    }
                    cache_updated = true
                else
                    table.insert(unresolved, f)
                end
            end
        end

        -- Fallback to Go CLI only if ffi/archiver wasn't available or couldn't decode an entry.
        if #unresolved > 0 and engine then
            local batch = engine.manifests and engine:manifests(sources_dir) or nil
            if type(batch) == "table" then
                local by_path = {}
                for _idx, item in ipairs(batch) do
                    if type(item) == "table" and item.path then
                        by_path[item.path] = item
                    end
                end
                for _idx, f in ipairs(unresolved) do
                    local item = by_path[f.path]
                    manifest_cache[f.path] = {
                        mtime = f.mtime,
                        size = f.size,
                        manifest = (item and type(item.key) == "string" and item.key ~= "") and item or false,
                    }
                    cache_updated = true
                end
            else
                for _idx, f in ipairs(unresolved) do
                    local m = engine:manifest(f.path)
                    manifest_cache[f.path] = {
                        mtime = f.mtime,
                        size = f.size,
                        manifest = (m and type(m.key) == "string" and m.key ~= "") and m or false,
                    }
                    cache_updated = true
                end
            end
        else
            for _idx, f in ipairs(unresolved) do
                manifest_cache[f.path] = {
                    mtime = f.mtime,
                    size = f.size,
                    manifest = false,
                }
                cache_updated = true
            end
        end

        if cache_updated then
            flushPersistedStore()
        end
    end

    local sources = {}
    local by_key = {}
    for _idx, f in ipairs(files) do
        local cached = manifest_cache[f.path]
        local manifest = cached and cached.manifest or nil
        local s = buildEntry(f.entry, f.path, manifest)
        table.insert(sources, s)
        if s.key and not by_key[s.key] then
            by_key[s.key] = s
        end
    end
    table.sort(sources, function(a, b) return a.text < b.text end)

    dir_cache[sources_dir] = {
        dir_mtime = dir_mtime,
        files = files,
        list = sources,
        by_key = by_key,
    }

    local copy = {}
    for i, s in ipairs(sources) do
        copy[i] = s
    end
    return copy
end

function InstalledSources.findByKey(sources_dir, engine, source_key)
    if type(source_key) ~= "string" or source_key == "" then
        return nil
    end
    InstalledSources.list(sources_dir, engine)
    local cached_dir = dir_cache[sources_dir]
    return cached_dir and cached_dir.by_key[source_key] or nil
end

return InstalledSources
