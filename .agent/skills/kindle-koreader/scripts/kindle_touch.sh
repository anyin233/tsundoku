#!/usr/bin/env bash
# Inject tap, long-press (hold), or swipe gestures onto a Kindle touchscreen via
# KOReader's bundled LuaJIT FFI.
#
# Automatically discovers the Multi-Touch input device from /proc/bus/input/devices
# and emits both a unique ABS_MT_TRACKING_ID and EV_KEY BTN_TOUCH (0x14a), which
# Kindle KOReader's snow_protocol / MT Type B state machine requires.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
Usage:
  KINDLE_HOST=192.168.x.x kindle_touch.sh tap   <x> <y>
  KINDLE_HOST=192.168.x.x kindle_touch.sh hold  <x> <y> [duration_ms]
  KINDLE_HOST=192.168.x.x kindle_touch.sh swipe <x1> <y1> <x2> <y2> [steps]
EOF
    exit 2
}

if [[ $# -lt 3 ]]; then
    usage
fi

MODE="$1"
shift

case "$MODE" in
    tap|hold)
        X1="$1"; Y1="$2"; X2="$1"; Y2="$2"
        EXTRA="${3:-900}"
        ;;
    swipe)
        if [[ $# -lt 4 ]]; then usage; fi
        X1="$1"; Y1="$2"; X2="$3"; Y2="$4"
        EXTRA="${5:-12}"
        ;;
    *)
        usage
        ;;
esac

"$SCRIPT_DIR/kindle_ssh.sh" exec "/mnt/us/koreader/luajit - '$MODE' '$X1' '$Y1' '$X2' '$Y2' '$EXTRA'" <<'LUA_EOF'
local ffi = require("ffi")
ffi.cdef[[
struct timeval { long tv_sec; long tv_usec; };
struct input_event { struct timeval time; uint16_t type; uint16_t code; int32_t value; };
int open(const char *pathname, int flags);
long write(int fd, const void *buf, size_t count);
int close(int fd);
int usleep(unsigned int usec);
int getpid(void);
]]
local C = ffi.C

local function findTouchDevice()
    local f = io.open("/proc/bus/input/devices", "r")
    if f then
        local block = ""
        for line in f:lines() do
            if line == "" then
                if block:match("ABS=2[6e]18000") or block:match("pt_mt") or block:match("cyttsp") or block:match("fts") or block:match("goodix") then
                    local ev = block:match("event(%d+)")
                    if ev then
                        f:close()
                        return "/dev/input/event" .. ev
                    end
                end
                block = ""
            else
                block = block .. "\n" .. line
            end
        end
        f:close()
    end
    return "/dev/input/event1"
end

local mode  = arg[1]
local x1    = tonumber(arg[2]) or 0
local y1    = tonumber(arg[3]) or 0
local x2    = tonumber(arg[4]) or x1
local y2    = tonumber(arg[5]) or y1
local extra = tonumber(arg[6]) or 900

local dev = findTouchDevice()
local fd = C.open(dev, 1) -- O_WRONLY
assert(fd >= 0, "failed to open touch input device: " .. tostring(dev))

local ev = ffi.new("struct input_event[1]")
local function emit(t, c, v)
    ev[0].type = t
    ev[0].code = c
    ev[0].value = v
    C.write(fd, ev, ffi.sizeof(ev))
end

-- Unique tracking ID per gesture so MT Type B never coalesces consecutive taps
local tid = ((C.getpid() * 31 + math.floor(os.clock() * 1000)) % 30000) + 1

-- EV_ABS=3, EV_KEY=1, EV_SYN=0
-- ABS_MT_SLOT=0x2f, ABS_MT_TOUCH_MAJOR=0x30, ABS_MT_POSITION_X=0x35, ABS_MT_POSITION_Y=0x36, ABS_MT_TRACKING_ID=0x39
-- BTN_TOUCH=0x14a
emit(3, 0x2f, 0)
emit(3, 0x39, tid)
emit(3, 0x35, x1)
emit(3, 0x36, y1)
emit(3, 0x30, 5)
emit(1, 0x14a, 1)
emit(0, 0, 0)

if mode == "tap" then
    C.usleep(85000)
elseif mode == "hold" then
    C.usleep(math.max(500, extra) * 1000)
elseif mode == "swipe" then
    local steps = math.max(3, math.floor(extra))
    for i = 1, steps do
        C.usleep(18000)
        local cx = math.floor(x1 + (x2 - x1) * (i / steps) + 0.5)
        local cy = math.floor(y1 + (y2 - y1) * (i / steps) + 0.5)
        emit(3, 0x2f, 0)
        emit(3, 0x35, cx)
        emit(3, 0x36, cy)
        emit(0, 0, 0)
    end
    C.usleep(25000)
end

emit(3, 0x2f, 0)
emit(3, 0x39, -1)
emit(1, 0x14a, 0)
emit(0, 0, 0)
C.close(fd)
LUA_EOF
