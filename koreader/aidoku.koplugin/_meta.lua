local function resolveLang()
    local g = _G.G_reader_settings
    if g and type(g.readSetting) == "function" then
        local lang = g:readSetting("language")
        if type(lang) == "string" and lang ~= "" then
            return lang
        end
    end
    local ok, gettext = pcall(require, "gettext")
    if ok and gettext and type(gettext.current_lang) == "string" then
        return gettext.current_lang
    end
    return ""
end

local lang = resolveLang()
local is_kanji_brand = lang:match("^zh") ~= nil or lang:match("^ja") ~= nil

local fullname = is_kanji_brand and "積読" or "Tsundoku"
local description
if lang:match("^ja") then
    description = "積読（Tsundoku）— 漫画ソース検索・一括ダウンロード・Koobone 同期・シリーズ管理。"
elseif lang:match("^zh_TW") or lang:match("^zh_HK") or lang:match("^zh_Hant") then
    description = "積読 (Tsundoku) — 漫畫書源檢索、離線囤漫、Koobone 訂閱同步與系列叢書管理。"
elseif lang:match("^zh") then
    description = "積読 (Tsundoku) — 漫画书源检索、离线囤漫、Koobone 订阅同步与系列丛书管理。"
else
    description = "Tsundoku — Manga repository browser, batch CBZ downloader, Koobone bookshelf sync, and series management."
end

return {
    fullname = fullname,
    description = description,
}
