--[[--
Plugin-local gettext with full trilingual i18n support (English, Chinese, Japanese)
and live runtime language switching.

Usage:
    local _ = require("aidoku_l10n")
    UIManager:show(InfoMessage:new{ text = _("No results.") })

Supported language modes (via _.setLanguage(mode)):
  - "auto"  : follows KOReader's current language (gettext.current_lang)
  - "en"    : English (returns msgid directly without falling through to KOReader's
              global gettext, so English stays pure English even if KOReader's host
              UI is set to Chinese or Japanese)
  - "zh_CN" : Simplified Chinese (l10n/zh_CN/aidoku.po)
  - "zh_TW" : Traditional Chinese (l10n/zh_TW/aidoku.po)
  - "ja"    : Japanese (l10n/ja/aidoku.po)

Why not GetText.loadMO(): KOReader's gettext is a single process-wide table, and
loadMO merges into it -- our msgstrs would silently override KOReader's for shared
msgids ("Remove", "Cancel", "Settings", ...) everywhere in the app, and switching
languages would require restarting KOReader. Parsing .po catalogs into an isolated
in-memory cache avoids collisions and enables instant runtime switching.
]]

local gettext = require("gettext")

local DOMAIN = "aidoku"

local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."

local function unescape(s)
    return (s:gsub("\\(.)", { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }))
end

local function parsePO(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local catalog = {}
    local entry, field, fuzzy = {}, nil, false

    local function flush()
        if not fuzzy and not entry.plural and entry.msgid and entry.msgid ~= ""
            and entry.msgstr and entry.msgstr ~= "" then
            catalog[entry.msgid] = entry.msgstr
        end
        entry, field, fuzzy = {}, nil, false
    end

    for line in f:lines() do
        if line:match("^%s*$") then
            flush()
        elseif line:match("^#,.*fuzzy") then
            fuzzy = true
        elseif line:match("^#") then -- luacheck: ignore 542
            -- comment line
        else
            local key, str = line:match('^(%S+)%s+"(.*)"%s*$')
            if key then
                if key == "msgid" and entry.msgstr then
                    flush()
                end
                if key == "msgid_plural" or key:match("^msgstr%[") then
                    entry.plural = true
                end
                field = key
                entry[field] = unescape(str)
            else
                local cont = line:match('^%s*"(.*)"%s*$')
                if cont and field then
                    entry[field] = entry[field] .. unescape(cont)
                end
            end
        end
    end
    flush()
    f:close()
    return catalog
end

-- Cache parsed catalogs by language code so runtime switching is zero-I/O.
local catalog_cache = {}

local function getCatalogForCode(code)
    if not code or code == "" then
        return nil
    end
    if catalog_cache[code] ~= nil then
        return catalog_cache[code] or nil
    end
    local parsed = parsePO(plugin_dir .. "/l10n/" .. code .. "/" .. DOMAIN .. ".po")
    catalog_cache[code] = parsed or false
    return parsed
end

local function isEnglishCode(lang)
    if not lang or lang == "" or lang == "C" then
        return true
    end
    return lang == "en" or lang:match("^en[_%-]") ~= nil
end

local function candidateCodes(lang)
    if not lang or isEnglishCode(lang) then
        return {}
    end
    -- Normalize common locale variants (e.g. zh-Hans -> zh_CN, zh-Hant/zh_HK -> zh_TW, ja_JP -> ja)
    local norm = lang:gsub("%-", "_")
    local candidates = { norm }
    if norm == "zh" or norm == "zh_Hans" or norm == "zh_SG" then
        table.insert(candidates, "zh_CN")
    elseif norm == "zh_Hant" or norm == "zh_HK" or norm == "zh_MO" then
        table.insert(candidates, "zh_TW")
    end
    local base = norm:match("^(%a+)_")
    if base then
        table.insert(candidates, base)
        if base == "zh" then
            table.insert(candidates, "zh_CN")
        end
    end
    return candidates
end

local function resolveCatalog(lang)
    for _idx, code in ipairs(candidateCodes(lang)) do
        local cat = getCatalogForCode(code)
        if cat then
            return cat, code
        end
    end
    return {}, "en"
end

local active_mode = "auto"
local active_catalog = {}
local active_resolved_lang = "en"

local L10n = {}

function L10n.effectiveLanguage()
    if active_mode ~= "auto" then
        return active_mode
    end
    local sys_lang = gettext.current_lang
    if isEnglishCode(sys_lang) then
        return "en"
    end
    return sys_lang
end

function L10n.setLanguage(mode)
    if mode ~= "en" and mode ~= "zh_CN" and mode ~= "zh_TW" and mode ~= "ja" then
        mode = "auto"
    end
    active_mode = mode
    local target = L10n.effectiveLanguage()
    if isEnglishCode(target) then
        active_catalog = {}
        active_resolved_lang = "en"
    else
        active_catalog, active_resolved_lang = resolveCatalog(target)
    end
end

function L10n.getLanguage()
    return active_mode
end

function L10n.getResolvedLanguage()
    return active_resolved_lang
end

-- Initialize against KOReader's current language on module load; main.lua's
-- Aidoku:init() immediately syncs this with store:language() once Store opens.
L10n.setLanguage("auto")

return setmetatable(L10n, {
    __call = function(_self, msgid)
        if not msgid or msgid == "" then
            return ""
        end
        if active_resolved_lang == "en" then
            return msgid
        end
        local translated = active_catalog[msgid]
        if translated then
            return translated
        end
        -- Only fall back to KOReader's global gettext when following KOReader's
        -- own system language ("auto"); when the user explicitly picked a
        -- different plugin language than KOReader's host UI, falling through to
        -- gettext(msgid) would leak the host UI's language.
        if active_mode == "auto" then
            return gettext(msgid)
        end
        return msgid
    end,
    __index = function(_self, k)
        local v = rawget(L10n, k)
        if v ~= nil then
            return v
        end
        return gettext[k]
    end,
})
