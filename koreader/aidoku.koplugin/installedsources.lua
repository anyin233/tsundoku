--[[--
Lists installed .aix sources in a sources directory, as
{text = "<display name> (<languages>)", mandatory = "v<version>",
name = "<display name>", path = "<sources_dir>/<file>.aix",
key = "<source's manifest id>, or nil if unreadable>", version = <int, or nil if unreadable>}
entries -- shared by sourcesbrowser.lua, globalsearchbrowser.lua,
librarybrowser.lua (findByKey), and repobrowser.lua.

Manifests are cached in memory keyed by (path, modification, size) and fetched
in bulk via engine:manifests(sources_dir) on a cache miss, so listing 20+
installed sources takes ~0ms warm and a single ~35ms subprocess cold instead
of 20+ sequential subprocess spawns.
]]

local lfs = require("libs/libkoreader-lfs")

local InstalledSources = {}

-- path -> { mtime = number, size = number, manifest = table|false }
local manifest_cache = {}

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
end

function InstalledSources.list(sources_dir, engine)
    local files = {}
    local any_miss = false
    if lfs.attributes(sources_dir, "mode") ~= "directory" then
        return {}
    end
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

    if any_miss and engine then
        local batch = engine.manifests and engine:manifests(sources_dir) or nil
        if type(batch) == "table" then
            local by_path = {}
            for _idx, item in ipairs(batch) do
                if type(item) == "table" and item.path then
                    by_path[item.path] = item
                end
            end
            for _idx, f in ipairs(files) do
                local item = by_path[f.path]
                manifest_cache[f.path] = {
                    mtime = f.mtime,
                    size = f.size,
                    manifest = (item and item.key and item.key ~= "") and item or false,
                }
            end
        else
            for _idx, f in ipairs(files) do
                local cached = manifest_cache[f.path]
                if not cached or cached.mtime ~= f.mtime or cached.size ~= f.size then
                    local m = engine:manifest(f.path)
                    manifest_cache[f.path] = {
                        mtime = f.mtime,
                        size = f.size,
                        manifest = m or false,
                    }
                end
            end
        end
    end

    local sources = {}
    for _idx, f in ipairs(files) do
        local cached = manifest_cache[f.path]
        local manifest = cached and cached.manifest or nil
        table.insert(sources, buildEntry(f.entry, f.path, manifest))
    end
    table.sort(sources, function(a, b) return a.text < b.text end)
    return sources
end

function InstalledSources.findByKey(sources_dir, engine, source_key)
    for _, source in ipairs(InstalledSources.list(sources_dir, engine)) do
        if source.key == source_key then
            return source
        end
    end
    return nil
end

return InstalledSources
