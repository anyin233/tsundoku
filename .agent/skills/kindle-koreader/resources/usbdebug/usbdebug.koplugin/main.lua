local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local DAEMON_SHM = "/dev/shm/usbdebugd"
local DAEMON_VAR = "/var/tmp/usbdebugd"
local DAEMON_PID = "/var/tmp/usbdebugd.pid"
local DAEMON_LOG = "/var/tmp/usbdebugd.log"
local DAEMON_STATUS = "/var/tmp/usbdebugd.status"

local function readFile(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

local function binArch()
    if jit and jit.arch ~= "arm" then
        return jit.arch
    end
    local f = io.open("/proc/cpuinfo", "r")
    if f then
        for line in f:lines() do
            local ver = line:match("^CPU architecture%s*:%s*(%d+)")
            if ver then
                f:close()
                return tonumber(ver) <= 6 and "armv6" or "armv7"
            end
        end
        f:close()
    end
    return "armv7"
end

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function resolveDaemonDst()
    if util.pathExists("/dev/shm") then
        return DAEMON_SHM
    end
    return DAEMON_VAR
end

local USBDebug = WidgetContainer:extend{
    name = "usbdebug",
    is_doc_only = false,
}

function USBDebug:daemonSrcPath()
    local arch = binArch()
    local candidate = self.path .. "/bin/" .. arch .. "/usbdebugd"
    if util.pathExists(candidate) then
        return candidate
    end
    return self.path .. "/bin/armv7/usbdebugd"
end

function USBDebug:isRunning()
    local pid = tonumber((readFile(DAEMON_PID) or ""):match("(%d+)"))
    if not pid then
        return false
    end
    local cmdline = readFile("/proc/" .. tostring(pid) .. "/cmdline")
    return type(cmdline) == "string" and cmdline:find("usbdebugd", 1, true) ~= nil
end

function USBDebug:installDaemonBinary()
    local src = self:daemonSrcPath()
    if not util.pathExists(src) then
        logger.warn("usbdebug: daemon binary missing at", src)
        return nil
    end
    local dst = resolveDaemonDst()
    local cleanup_legacy = ""
    if dst == DAEMON_SHM then
        -- Reclaim space on the tight 64MB /var tmpfs if upgrading from an older binary location.
        cleanup_legacy = "rm -f " .. shellQuote(DAEMON_VAR) .. " 2>/dev/null || true; "
    end
    local cmd = string.format(
        "%srm -f %s.tmp && cp -f %s %s.tmp && chmod 0755 %s.tmp && mv -f %s.tmp %s",
        cleanup_legacy,
        shellQuote(dst),
        shellQuote(src),
        shellQuote(dst),
        shellQuote(dst),
        shellQuote(dst),
        shellQuote(dst)
    )
    local rc = os.execute(cmd)
    if rc ~= 0 and rc ~= true then
        logger.warn("usbdebug: failed to stage daemon binary, rc=", rc)
        return nil
    end
    return dst
end

function USBDebug:startDaemon(restart)
    local dst = self:installDaemonBinary()
    if not dst then
        return false
    end
    if not restart and self:isRunning() then
        return true
    end
    local prefix = restart and (shellQuote(dst) .. " stop >/dev/null 2>&1; ") or ""
    local cmd = string.format(
        "%snohup %s daemon </dev/null >%s 2>&1 &",
        prefix,
        shellQuote(dst),
        shellQuote(DAEMON_LOG)
    )
    local rc = os.execute(cmd)
    logger.info("usbdebug: launched daemon rc=", rc)
    return true
end

function USBDebug:stopDaemon()
    for _idx, candidate in ipairs({ DAEMON_SHM, DAEMON_VAR }) do
        if util.pathExists(candidate) then
            os.execute(shellQuote(candidate) .. " stop >/dev/null 2>&1")
            return
        end
    end
end

function USBDebug:statusText()
    local running = self:isRunning()
    local lines = {
        running and _("Status: running") or _("Status: stopped"),
    }
    local st = readFile(DAEMON_STATUS)
    if st and st ~= "" then
        table.insert(lines, "\n" .. st:gsub("%s+$", ""))
    end
    local p = io.popen("head -n 1 /sys/class/udc/*/state 2>/dev/null")
    if p then
        local udc = p:read("*a")
        p:close()
        if udc and udc ~= "" then
            table.insert(lines, "\nUDC:\n" .. udc:gsub("%s+$", ""))
        end
    end
    local tail = io.popen("tail -n 8 " .. shellQuote(DAEMON_LOG) .. " 2>/dev/null")
    if tail then
        local log_out = tail:read("*a")
        tail:close()
        if log_out and log_out ~= "" then
            table.insert(lines, "\nLog:\n" .. log_out:gsub("%s+$", ""))
        end
    end
    return table.concat(lines, "\n")
end

function USBDebug:init()
    self.ui.menu:registerToMainMenu(self)
    if not Device:isKindle() then
        return
    end
    local autostart = G_reader_settings:nilOrTrue("usbdebug_autostart")
    if autostart and not self:isRunning() then
        -- Delay slightly so KOReader UI startup finishes cleanly first.
        UIManager:scheduleIn(0.5, function()
            pcall(function()
                self:startDaemon(false)
            end)
        end)
    end
end

function USBDebug:addToMainMenu(menu_items)
    menu_items.usbdebug = {
        text = _("USB Debug (SSH)"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text_func = function()
                    return self:isRunning()
                        and _("Show USB Debug status (running)")
                        or _("Show USB Debug status (stopped)")
                end,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = self:statusText(),
                    })
                end,
            },
            {
                text = _("Autostart USB Debug"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("usbdebug_autostart")
                end,
                callback = function()
                    local cur = G_reader_settings:nilOrTrue("usbdebug_autostart")
                    G_reader_settings:saveSetting("usbdebug_autostart", not cur)
                end,
            },
            {
                text = _("Start / Restart USB Debug"),
                keep_menu_open = true,
                callback = function()
                    local ok = self:startDaemon(true)
                    UIManager:show(InfoMessage:new{
                        text = ok and _("USB Debug started.") or _("Failed to start USB Debug."),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Stop USB Debug"),
                keep_menu_open = true,
                callback = function()
                    self:stopDaemon()
                    UIManager:show(InfoMessage:new{
                        text = _("USB Debug stopped."),
                        timeout = 2,
                    })
                end,
            },
        },
    }
end

local _unused_ds = DataStorage

return USBDebug
