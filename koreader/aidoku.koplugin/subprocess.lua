--[[--
Generic "shell out to a bundled binary, decode JSON stdout" runner, used by
engine.lua to talk to aidoku-run. downloadsengine.lua and store.lua's
library/history methods do NOT use this -- they talk to their own SQLite
files directly via lua-ljsqlite3, synchronously, no subprocess involved.

Every synchronous method here calls Trapper:dismissablePopen() (or a custom
coroutine loop for live progress), which must run inside a coroutine started
by Trapper:wrap() to show progress/allow cancellation -- see ui/trapper.lua.
Runner:spawnAsync() instead starts a non-blocking background subprocess for
DownloadQueue's event-loop polling.
]]

local TrapWidget = require("ui/widget/trapwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = ffiUtil.template
local _ = require("aidoku_l10n")

local Runner = {}
Runner.__index = Runner

function Runner.new(bin_path)
    return setmetatable({ bin_path = bin_path }, Runner)
end

-- isAvailable reports whether the bundled binary exists at bin_path (it
-- won't until koreader/build.sh has cross-compiled and bundled it).
function Runner:isAvailable()
    return lfs.attributes(self.bin_path, "mode") == "file"
end

local function shellQuote(s)
    local escaped = tostring(s):gsub("'", "'\\''")
    return "'" .. escaped .. "'"
end
Runner.shellQuote = shellQuote

-- command_exists_cache memoizes commandExists() results for the life of the
-- process -- a device doesn't gain or lose binaries mid-session, and this
-- can otherwise run once per download.
local command_exists_cache = {}

local function commandExists(name)
    if command_exists_cache[name] == nil then
        local found = false
        local f = io.popen("command -v " .. shellQuote(name) .. " >/dev/null 2>&1 && echo yes")
        if f then
            found = f:read("*l") == "yes"
            f:close()
        end
        command_exists_cache[name] = found
    end
    return command_exists_cache[name]
end

local function buildCommand(bin_path, stderr_path, args, env, low_priority)
    local parts = {}
    if env then
        for k, v in pairs(env) do
            table.insert(parts, k .. "=" .. shellQuote(v))
        end
    end
    if low_priority and commandExists("nice") then
        table.insert(parts, "nice")
        table.insert(parts, "-n")
        table.insert(parts, "19")
    end
    table.insert(parts, shellQuote(bin_path))
    for _idx, a in ipairs(args) do
        table.insert(parts, shellQuote(a))
    end
    table.insert(parts, "2>" .. shellQuote(stderr_path))
    return table.concat(parts, " ") .. '; echo "__rc=$?"'
end

local function errorMessage(stderr)
    local last_error, last_line
    for line in stderr:gmatch("[^\n]+") do
        if line:match("%S") then
            last_line = line
            local msg = line:match("^error: (.*)")
            if msg then
                last_error = msg
            end
        end
    end
    return last_error or last_line
end

-- parseDownloadProgress scans stderr text for the latest "[download] page N/M"
-- line emitted by aidoku-run during page-by-page CBZ creation.
local function parseDownloadProgress(text)
    local cur, tot
    for c, t in (text or ""):gmatch("%[download%] page (%d+)/(%d+)") do
        cur, tot = tonumber(c), tonumber(t)
    end
    return cur, tot
end
Runner.parseDownloadProgress = parseDownloadProgress

local function collectCoverIndices(text, seen, ready)
    for idx_str in (text or ""):gmatch("%[cover%] (%d+)\r?\n") do
        local idx = tonumber(idx_str)
        if idx and not seen[idx] then
            seen[idx] = true
            table.insert(ready, idx)
        end
    end
end
Runner.collectCoverIndices = collectCoverIndices

local function decodeProcessResult(cmd, raw_output, stderr)
    local body, rc = (raw_output or ""):match("^(.-)__rc=(%d+)%s*$")
    local output = (body or ""):gsub("%s+$", "")
    if rc ~= "0" then
        logger.warn("aidoku: command failed (exit " .. tostring(rc) .. "):", cmd, stderr, output)
        return nil, errorMessage(stderr) or _("command failed")
    end
    if output == "" then
        logger.warn("aidoku: command failed:", cmd, stderr)
        return nil, errorMessage(stderr) or _("command produced no output")
    end
    return output, nil
end

local function scheduleReap(pid, parent_read_fd)
    local collect
    collect = function()
        if ffiUtil.isSubProcessDone(pid) then
            if parent_read_fd then
                pcall(ffiUtil.readAllFromFD, parent_read_fd)
                parent_read_fd = nil
            end
        else
            if parent_read_fd and ffiUtil.getNonBlockingReadSize(parent_read_fd) ~= 0 then
                pcall(ffiUtil.readAllFromFD, parent_read_fd)
                parent_read_fd = nil
            end
            UIManager:scheduleIn(2, collect)
        end
    end
    UIManager:scheduleIn(1, collect)
end

-- spawnAsync launches aidoku-run in a forked child process without blocking
-- KOReader's UI loop. Callers poll handle:poll() via UIManager:scheduleIn()
-- to read incremental page progress ("[download] page N/M") and completion.
function Runner:spawnAsync(args, env, low_priority, cleanup_files)
    local stderr_path = os.tmpname()
    local cmd = buildCommand(self.bin_path, stderr_path, args, env, low_priority)

    local pid, parent_read_fd = ffiUtil.runInSubProcess(function(_child_pid, child_write_fd)
        local pipe = io.popen(cmd, "r")
        local out = ""
        if pipe then
            out = pipe:read("*a") or ""
            pipe:close()
        end
        ffiUtil.writeToFD(child_write_fd, out, true)
    end, true)

    local function cleanupFiles()
        os.remove(stderr_path)
        for _idx, p in ipairs(cleanup_files or {}) do
            os.remove(p)
        end
        cleanup_files = nil
    end

    if not pid then
        cleanupFiles()
        return nil, parent_read_fd or _("command failed")
    end

    local handle = {
        pid = pid,
        fd = parent_read_fd,
        stderr_path = stderr_path,
        stderr_offset = 0,
        stderr_tail = "",
        current_page = 0,
        total_pages = 0,
        cover_seen = {},
        cover_ready = {},
        finished = false,
    }

    function handle:readProgress()
        local f = io.open(self.stderr_path, "r")
        if not f then
            return
        end
        if self.stderr_offset > 0 then
            f:seek("set", self.stderr_offset)
        end
        local chunk = f:read("*a")
        local pos = f:seek()
        f:close()
        if chunk and chunk ~= "" then
            self.stderr_offset = pos or (self.stderr_offset + #chunk)
            local combined = self.stderr_tail .. chunk
            local cur, tot = parseDownloadProgress(combined)
            if cur and tot then
                self.current_page = cur
                self.total_pages = tot
            end
            collectCoverIndices(combined, self.cover_seen, self.cover_ready)
            self.stderr_tail = combined:sub(math.max(1, #combined - 128))
        end
    end

    function handle:drainReadyCovers()
        if #self.cover_ready == 0 then
            return nil
        end
        local out = self.cover_ready
        self.cover_ready = {}
        return out
    end

    function handle:poll()
        if self.finished then
            return "done"
        end
        self:readProgress()

        local done = ffiUtil.isSubProcessDone(self.pid)
        local has_data = self.fd and ffiUtil.getNonBlockingReadSize(self.fd) ~= 0
        if not done and not has_data then
            return "running", self.current_page, self.total_pages
        end

        self.finished = true
        local raw_out = ""
        if self.fd then
            raw_out = ffiUtil.readAllFromFD(self.fd) or ""
            self.fd = nil
        end
        if not done then
            scheduleReap(self.pid, nil)
        end

        local full_stderr = ""
        local sf = io.open(self.stderr_path, "r")
        if sf then
            full_stderr = sf:read("*a") or ""
            sf:close()
        end
        local cur, tot = parseDownloadProgress(full_stderr)
        if cur and tot then
            self.current_page = cur
            self.total_pages = tot
        end
        collectCoverIndices(full_stderr, self.cover_seen, self.cover_ready)
        cleanupFiles()

        local out, err = decodeProcessResult(cmd, raw_out, full_stderr)
        if not out then
            return "error", nil, err
        end
        return "done", out, nil
    end

    function handle:cancel()
        if self.finished then
            return
        end
        self.finished = true
        ffiUtil.terminateSubProcess(self.pid)
        local fd = self.fd
        self.fd = nil
        scheduleReap(self.pid, fd)
        cleanupFiles()
    end

    return handle
end

function Runner:exec(args, progress_text, env, low_priority)
    local stderr_path = os.tmpname()
    local cmd = buildCommand(self.bin_path, stderr_path, args, env, low_priority)

    local completed, output = Trapper:dismissablePopen(cmd, progress_text)
    local stderr = ""
    local f = io.open(stderr_path, "r")
    if f then
        stderr = f:read("*a") or ""
        f:close()
    end
    os.remove(stderr_path)
    if not completed then
        return nil, _("Cancelled")
    end

    return decodeProcessResult(cmd, output, stderr)
end

-- execDownload runs a foreground download inside a Trapper coroutine while
-- polling stderr for "[download] page N/M" and updating the TrapWidget text
-- live so the user sees exact page progress and can tap anywhere to cancel.
function Runner:execDownload(args, progress_prefix, env, low_priority, cleanup_files)
    local co = coroutine.running()
    if not co or not progress_prefix then
        local out, err = self:exec(args, progress_prefix, env, low_priority)
        for _idx, p in ipairs(cleanup_files or {}) do
            os.remove(p)
        end
        return out, err
    end

    local handle, spawn_err = self:spawnAsync(args, env, low_priority, cleanup_files)
    if not handle then
        return nil, spawn_err
    end

    local last_shown = progress_prefix
    local trap_widget = TrapWidget:new{
        text = last_shown,
    }
    trap_widget.dismiss_callback = function()
        coroutine.resume(co, false)
    end
    UIManager:show(trap_widget)
    UIManager:forceRePaint()

    local result_out, result_err
    local cancelled = false

    while true do
        local timer_fn = function()
            coroutine.resume(co, true)
        end
        UIManager:scheduleIn(0.35, timer_fn)
        local go_on = coroutine.yield()
        if not go_on then
            UIManager:unschedule(timer_fn)
            handle:cancel()
            cancelled = true
            break
        end

        local state, a, b = handle:poll()
        if state == "running" then
            if a and b and b > 0 then
                local pct = math.floor((a * 100) / b)
                local updated_text = T(_("%1 (%2/%3 pages, %4%)"), progress_prefix, a, b, pct)
                if updated_text ~= last_shown then
                    last_shown = updated_text
                    UIManager:close(trap_widget)
                    trap_widget = TrapWidget:new{
                        text = last_shown,
                        dismiss_callback = function()
                            coroutine.resume(co, false)
                        end,
                    }
                    UIManager:show(trap_widget)
                    UIManager:setDirty(trap_widget, "ui")
                end
            end
        elseif state == "done" then
            result_out = a
            break
        else
            result_err = b
            break
        end
    end

    UIManager:close(trap_widget)
    UIManager:setDirty("all", "ui")

    if cancelled then
        return nil, _("Cancelled")
    end
    return result_out, result_err
end

-- execJSON is exec() plus decoding stdout as JSON.
function Runner:execJSON(args, progress_text, env)
    local output, err = self:exec(args, progress_text, env)
    if not output then
        return nil, err
    end
    local ok, decoded = pcall(json.decode, output)
    if not ok then
        logger.warn("aidoku: could not decode JSON output:", output)
        return nil, _("Invalid response from aidoku-run")
    end
    return decoded
end

return Runner
