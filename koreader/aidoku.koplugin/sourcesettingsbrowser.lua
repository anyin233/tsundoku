--[[--
SourceSettingsBrowser: renders a source's settings tree, supporting:
- Standard Aidoku `login` (basic email/username + password login & logout)
- `button` actions (triggers `handle_notification` and refreshes dynamic settings)
- `select`, `picker`, `multi-select`, `switch`, and `text` settings
- Native first-class Kox.moe (`kox`) user status card (ID, nickname, Lv level,
  VIP expiry, phone verification, remaining/monthly/daily/VIP/free quotas,
  Koobone storage & book counts, and one-tap jump to Koobone Bookshelf).
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local OpenWidgets = require("openwidgets")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local SourceSettingsBrowser = Menu:extend{}

local SUPPORTED_TYPES = {
    select = true,
    picker = true,
    ["multi-select"] = true,
    switch = true,
    text = true,
    login = true,
    button = true,
}

local function array(t)
    return type(t) == "table" and t or {}
end

local function formatMB(mb)
    mb = tonumber(mb) or 0
    if mb >= 1024 then
        return string.format("%.1f GB (%.0f MB)", mb / 1024, mb)
    end
    return string.format("%.1f MB", mb)
end

local function formatBytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes <= 0 then
        return "0 MB"
    end
    local mb = bytes / (1024 * 1024)
    if mb >= 1024 then
        return string.format("%.1f GB", mb / 1024)
    end
    return string.format("%.1f MB", mb)
end

local function flatten(settings, prefix, out, source_key)
    out = out or {}
    for _idx, setting in ipairs(array(settings)) do
        local key = type(setting.Key) == "string" and setting.Key or ""
        -- When viewing native `kox`, we render our rich native Kox status card at the
        -- top, so skip the duplicate dynamic `status.*` rows meant for third-party Aidoku hosts.
        local skip_kox_dup = (source_key == "kox") and (key:sub(1, 7) == "status.")
        if not skip_kox_dup then
            local label = prefix ~= "" and (prefix .. ": " .. setting.Title) or setting.Title
            if setting.Type == "group" and setting.Group then
                local next_prefix = (type(setting.Title) == "string" and setting.Title ~= "") and setting.Title or prefix
                flatten(setting.Group.Items, next_prefix, out, source_key)
            elseif setting.Type == "page" and setting.Page then
                local next_prefix = (type(setting.Title) == "string" and setting.Title ~= "") and setting.Title or prefix
                flatten(setting.Page.Items, next_prefix, out, source_key)
            elseif SUPPORTED_TYPES[setting.Type] then
                table.insert(out, { setting = setting, label = label })
            end
        end
    end
    return out
end

function SourceSettingsBrowser:init()
    self.title = T(_("%1 settings"), self.source_text or "")
    self.entries = {}
    self.values = {}
    self.login_users = {}
    self.kox_status = nil
    self.item_table = {}
    Menu.init(self)
    OpenWidgets.push(self)
    UIManager:nextTick(function() self:reload() end)
end

function SourceSettingsBrowser:onCloseWidget()
    Menu.onCloseWidget(self)
    OpenWidgets.remove(self)
end

function SourceSettingsBrowser:isKoxSource()
    return self.source_key == "kox"
end

function SourceSettingsBrowser:reload(fetch_live_kox)
    Trapper:wrap(function()
        if not self.source_key and self.source_path then
            local m = self.engine:manifest(self.source_path)
            if type(m) == "table" and type(m.key) == "string" then
                self.source_key = m.key
            end
        end

        if self:isKoxSource() then
            local st = self.engine:koxStatus(not fetch_live_kox)
            if type(st) == "table" then
                if st.logged_in and (not st.uin or st.uin == "") and not fetch_live_kox then
                    st = self.engine:koxStatus(false) or st
                end
                self.kox_status = st
            end
        end

        local schema, err = self.engine:settingsList(self.source_path)
        if not schema then
            UIManager:show(InfoMessage:new{ text = T(_("Could not load settings:\n%1"), err) })
            return
        end
        self.entries = flatten(schema, "", nil, self.source_key)
        self.values = {}
        self.login_users = {}
        for _idx, entry in ipairs(self.entries) do
            local s = entry.setting
            if s.Type == "login" then
                local uname = self.engine:settingsGet(self.source_path, s.Key .. ".username")
                if type(uname) == "string" and uname ~= "" then
                    self.login_users[s.Key] = uname
                end
            elseif s.Key and s.Key ~= "" and s.Type ~= "button" then
                self.values[s.Key] = self.engine:settingsGet(self.source_path, s.Key)
            end
        end
        self:refresh()
    end)
end

local function selectDisplay(setting, value)
    local box = setting.Select or setting.Picker
    box = type(box) == "table" and box or {}
    local vals = array(box.Values)
    local titles = array(box.Titles)
    if type(value) == "string" and value ~= "" then
        for i, v in ipairs(vals) do
            if v == value then
                return titles[i] or v
            end
        end
        return value
    end
    return _("not set")
end

local function summary(setting, value, login_user)
    if setting.Type == "switch" then
        return (value == true) and _("On") or _("Off")
    elseif setting.Type == "multi-select" then
        if type(value) == "table" and #value > 0 then
            return table.concat(value, ", ")
        end
        return _("none")
    elseif setting.Type == "select" or setting.Type == "picker" then
        return selectDisplay(setting, value)
    elseif setting.Type == "login" then
        if type(login_user) == "string" and login_user ~= "" then
            return T(_("Logged in (%1)"), login_user)
        end
        return _("Not logged in")
    elseif setting.Type == "button" then
        return ">"
    else -- "text"
        if type(value) == "string" and value ~= "" then
            local sec = type(setting.Text) == "table" and setting.Text.Secure == true
            if sec then
                return "••••••••"
            end
            return value
        end
        return _("not set")
    end
end

function SourceSettingsBrowser:appendKoxStatusSection(item_table)
    local st = self.kox_status
    local logged_in = type(st) == "table" and st.logged_in == true

    table.insert(item_table, {
        text = _("── Kox.moe Account & Quota ──"),
        bold = true,
        dim = true,
        is_placeholder = true,
    })

    if not logged_in then
        table.insert(item_table, {
            text = _("Account status"),
            mandatory = _("Not logged in"),
            is_kox_login_action = true,
        })
        return
    end

    local acct = (type(st.nickname) == "string" and st.nickname ~= "") and st.nickname
        or (type(st.email) == "string" and st.email ~= "" and st.email)
        or tostring(st.uin or "")
    if type(st.uin) == "string" and st.uin ~= "" and acct ~= st.uin then
        acct = acct .. " (ID: " .. st.uin .. ")"
    end

    local lv_str = string.format("Lv%d", tonumber(st.level) or 0)
    if st.is_vip then
        if type(st.vip_expire) == "string" and st.vip_expire ~= "" then
            lv_str = lv_str .. " · VIP (" .. st.vip_expire .. ")"
        else
            lv_str = lv_str .. " · VIP"
        end
    end
    if st.phone_verified then
        lv_str = lv_str .. " · " .. _("Verified")
    end

    table.insert(item_table, {
        text = _("User"),
        mandatory = acct,
        is_kox_status_detail = true,
    })
    table.insert(item_table, {
        text = _("Level & VIP"),
        mandatory = lv_str,
        is_kox_status_detail = true,
    })
    table.insert(item_table, {
        text = _("Remaining quota"),
        mandatory = formatMB(st.quota_remaining_mb),
        is_kox_status_detail = true,
    })
    table.insert(item_table, {
        text = _("Used quota (Today / Month)"),
        mandatory = string.format("%.1fM / %.1fM", tonumber(st.quota_today_used_mb) or 0, tonumber(st.quota_month_used_mb) or 0),
        is_kox_status_detail = true,
    })
    if st.koobone_active then
        table.insert(item_table, {
            text = _("Koobone Bookshelf"),
            mandatory = T(_("%1 vol · %2 / %3 >"),
                tonumber(st.koobone_vol_count) or 0,
                formatBytes(st.koobone_quota_used_bytes),
                formatBytes(st.koobone_quota_max_bytes)),
            is_open_koobone = true,
        })
    else
        table.insert(item_table, {
            text = _("Open Koobone Bookshelf"),
            mandatory = ">",
            is_open_koobone = true,
        })
    end
    table.insert(item_table, {
        text = _("Refresh account & quota status"),
        mandatory = "↻",
        is_kox_refresh = true,
    })
    table.insert(item_table, {
        text = "",
        dim = true,
        is_placeholder = true,
    })
end

function SourceSettingsBrowser:showKoxStatusPopup()
    local st = self.kox_status
    if type(st) ~= "table" or not st.logged_in then
        return
    end
    local lines = {
        T(_("User ID: %1"), tostring(st.uin or "-")),
        T(_("Nickname: %1"), (type(st.nickname) == "string" and st.nickname ~= "") and st.nickname or "-"),
        T(_("Email: %1"), (type(st.email) == "string" and st.email ~= "") and st.email or "-"),
        T(_("Level: Lv%1%2"), tonumber(st.level) or 0, st.is_vip and (" (VIP → " .. tostring(st.vip_expire or "") .. ")") or ""),
        T(_("Phone Verified: %1"), st.phone_verified and _("Yes") or _("No")),
        "",
        T(_("Total Remaining Quota: %1"), formatMB(st.quota_remaining_mb)),
        T(_("Monthly Free Quota: %1 / %2 left"), formatMB(st.quota_free_left_mb), formatMB(st.quota_free_total_mb)),
    }
    if st.is_vip then
        table.insert(lines, T(_("Monthly VIP Quota: %1 / %2 left"), formatMB(st.quota_vip_left_mb), formatMB(st.quota_vip_total_mb)))
    end
    table.insert(lines, T(_("Used Today: %1 · Used This Month: %2"), formatMB(st.quota_today_used_mb), formatMB(st.quota_month_used_mb)))
    if type(st.quota_reset_day) == "string" and st.quota_reset_day ~= "" then
        table.insert(lines, T(_("Quota Reset: %1"), st.quota_reset_day))
    end
    if st.koobone_active then
        table.insert(lines, "")
        table.insert(lines, T(_("Koobone Books: %1 · Storage: %2 / %3"),
            tonumber(st.koobone_vol_count) or 0,
            formatBytes(st.koobone_quota_used_bytes),
            formatBytes(st.koobone_quota_max_bytes)))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function SourceSettingsBrowser:refresh()
    local item_table = {}
    if self:isKoxSource() then
        self:appendKoxStatusSection(item_table)
    end

    for _idx, entry in ipairs(self.entries) do
        local s = entry.setting
        local value = self.values[s.Key]
        local login_u = self.login_users[s.Key]
        if s.Type == "button" then
            table.insert(item_table, {
                text = entry.label,
                mandatory = ">",
                entry = entry,
            })
        else
            table.insert(item_table, {
                text = entry.label,
                mandatory = summary(s, value, login_u),
                entry = entry,
            })
        end
    end

    if #item_table == 0 then
        table.insert(item_table, { text = _("This source has no configurable settings."), dim = true, is_placeholder = true })
    end
    self.item_table = item_table
    self:updateItems()
end

function SourceSettingsBrowser:setValue(key, cli_type, values, display_value, refreshes_settings)
    Trapper:wrap(function()
        local _res, err = self.engine:settingsSet(self.source_path, key, cli_type, values)
        if err and not _res then
            UIManager:show(InfoMessage:new{ text = T(_("Could not save setting:\n%1"), err) })
            return
        end
        self.values[key] = display_value
        if refreshes_settings or (self:isKoxSource() and key == "url") then
            self:reload(true)
        else
            self:refresh()
        end
    end)
end

function SourceSettingsBrowser:pickSelect(entry)
    local setting = entry.setting
    local sel = setting.Select or setting.Picker
    sel = type(sel) == "table" and sel or {}
    local rows = {}
    local cur = self.values[setting.Key]
    for i, option in ipairs(array(sel.Values)) do
        local display = array(sel.Titles)[i] or option
        local mark = (cur == option) and "✓ " or ""
        table.insert(rows, { text = mark .. display, value = option })
    end
    local picker
    picker = Menu:new{
        title = entry.label,
        item_table = rows,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu, item)
            UIManager:close(picker)
            self:setValue(setting.Key, "select", { item.value }, item.value)
            return true
        end,
        onCloseWidget = function(self_picker)
            Menu.onCloseWidget(self_picker)
            OpenWidgets.remove(self_picker)
        end,
    }
    OpenWidgets.push(picker)
    UIManager:show(picker)
end

function SourceSettingsBrowser:pickMultiselect(entry)
    local setting = entry.setting

    local function isSelected(selected, option)
        for _idx, v in ipairs(selected) do
            if v == option then return true end
        end
        return false
    end

    local multi = type(setting.Multiselect) == "table" and setting.Multiselect or {}
    local function buildRows(selected)
        local rows = {}
        for i, option in ipairs(array(multi.Values)) do
            local display = array(multi.Titles)[i] or option
            local marker = isSelected(selected, option) and "✓ " or ""
            table.insert(rows, { text = marker .. display, value = option })
        end
        return rows
    end

    local selected = {}
    local current = self.values[setting.Key]
    if type(current) == "table" then
        for _idx, v in ipairs(current) do table.insert(selected, v) end
    end

    local picker
    picker = Menu:new{
        title = entry.label,
        item_table = buildRows(selected),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        onMenuSelect = function(_menu, item)
            if isSelected(selected, item.value) then
                local next_selected = {}
                for _idx, v in ipairs(selected) do
                    if v ~= item.value then table.insert(next_selected, v) end
                end
                selected = next_selected
            else
                table.insert(selected, item.value)
            end
            picker.item_table = buildRows(selected)
            picker:updateItems()
            self:setValue(setting.Key, "multiselect", selected, selected)
            return true
        end,
        onCloseWidget = function(self_picker)
            Menu.onCloseWidget(self_picker)
            OpenWidgets.remove(self_picker)
        end,
    }
    OpenWidgets.push(picker)
    UIManager:show(picker)
end

function SourceSettingsBrowser:promptText(entry)
    local setting = entry.setting
    local current = self.values[setting.Key]
    local dialog
    dialog = InputDialog:new{
        title = entry.label,
        input = type(current) == "string" and current or "",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Set"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    self:setValue(setting.Key, "text", { text }, text)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SourceSettingsBrowser:promptBasicLogin(setting, label)
    local login_cfg = type(setting and setting.Login) == "table" and setting.Login or {}
    local use_email = (setting == nil) or (login_cfg.UseEmail == true)
    local key = (setting and setting.Key and setting.Key ~= "") and setting.Key or "login"

    local dialog
    dialog = MultiInputDialog:new{
        title = label or _("Sign In"),
        fields = {
            {
                text = self.login_users[key] or "",
                hint = use_email and _("Email address") or _("Username"),
            },
            {
                text = "",
                text_type = "password",
                hint = _("Password"),
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Log In"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local username = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local password = fields[2] or ""
                    UIManager:close(dialog)
                    if username == "" or password == "" then
                        UIManager:show(InfoMessage:new{ text = _("Please enter both account and password."), timeout = 2 })
                        return
                    end
                    Trapper:wrap(function()
                        if self:isKoxSource() then
                            local st, err = self.engine:koxLogin(username, password)
                            if not st then
                                UIManager:show(InfoMessage:new{ text = T(_("Login failed:\n%1"), err or _("Invalid credentials")) })
                                return
                            end
                            self.kox_status = st
                            self.login_users[key] = username
                            self:reload(false)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Logged in as %1 (Lv%2 · Quota: %3)"),
                                    (type(st.nickname) == "string" and st.nickname ~= "") and st.nickname or username,
                                    tonumber(st.level) or 0,
                                    formatMB(st.quota_remaining_mb)),
                                timeout = 2.5,
                            })
                        else
                            local res, err = self.engine:sourceLogin(self.source_path, key, username, password)
                            if not res or res.ok ~= true then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Login failed:\n%1"), err or _("Invalid username or password.")),
                                })
                                return
                            end
                            self:reload(false)
                            UIManager:show(InfoMessage:new{ text = _("Logged in successfully."), timeout = 2 })
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SourceSettingsBrowser:promptLogout(setting)
    local key = (setting and setting.Key and setting.Key ~= "") and setting.Key or "login"
    local notif = (setting and type(setting.Notification) == "string" and setting.Notification ~= "")
        and setting.Notification or key
    local logout_title = (setting and type(setting.Login) == "table" and type(setting.Login.LogoutTitle) == "string" and setting.Login.LogoutTitle ~= "")
        and setting.Login.LogoutTitle or _("Log Out")

    UIManager:show(ConfirmBox:new{
        text = T(_("Log out from %1?"), self.source_text or self.source_key or ""),
        ok_text = logout_title,
        ok_callback = function()
            Trapper:wrap(function()
                if self:isKoxSource() then
                    self.engine:koxLogout()
                    self.kox_status = { logged_in = false }
                else
                    self.engine:sourceLogout(self.source_path, key, notif)
                end
                self.login_users[key] = nil
                self:reload(false)
                UIManager:show(InfoMessage:new{ text = _("Logged out."), timeout = 1.5 })
            end)
        end,
    })
end

function SourceSettingsBrowser:openKooboneBrowser()
    local ok, KooboneBrowser = pcall(require, "koobonebrowser")
    if not ok or not KooboneBrowser then
        return
    end
    UIManager:show(KooboneBrowser:new{
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        downloads_dir = self.downloads_dir,
        source_path = self.source_path,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        refresh_callback = self.refresh_callback,
    })
end

function SourceSettingsBrowser:onMenuSelect(item)
    if item.is_placeholder then
        return true
    end
    if item.is_kox_login_action then
        self:promptBasicLogin(nil, _("Log in to Kox.moe"))
        return true
    elseif item.is_kox_status_detail then
        self:showKoxStatusPopup()
        return true
    elseif item.is_kox_refresh then
        self:reload(true)
        return true
    elseif item.is_open_koobone then
        self:openKooboneBrowser()
        return true
    end

    local entry = item.entry
    local setting = entry.setting
    if setting.Type == "switch" then
        local value = self.values[setting.Key] == true
        self:setValue(setting.Key, "toggle", { value and "false" or "true" }, not value)
    elseif setting.Type == "select" or setting.Type == "picker" then
        self:pickSelect(entry)
    elseif setting.Type == "multi-select" then
        self:pickMultiselect(entry)
    elseif setting.Type == "login" then
        local logged_in = (self.login_users[setting.Key] ~= nil)
            or (self:isKoxSource() and self.kox_status and self.kox_status.logged_in == true)
        if logged_in then
            self:promptLogout(setting)
        else
            local method = type(setting.Login) == "table" and setting.Login.Method or "basic"
            if method ~= "basic" then
                UIManager:show(InfoMessage:new{
                    text = _("This source uses browser login. Import cookies.txt in Settings → Import cookies."),
                })
            else
                self:promptBasicLogin(setting, entry.label)
            end
        end
    elseif setting.Type == "button" then
        local notif = type(setting.Notification) == "string" and setting.Notification or setting.Key
        if notif and notif ~= "" then
            Trapper:wrap(function()
                if self:isKoxSource() and notif == "refresh_status" then
                    self:reload(true)
                else
                    self.engine:sourceNotify(self.source_path, notif)
                    self:reload(false)
                end
            end)
        end
    else -- "text"
        self:promptText(entry)
    end
    return true
end

return SourceSettingsBrowser
