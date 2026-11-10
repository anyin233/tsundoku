#!/usr/bin/env bash
# Headless offscreen KOReader widget -> PNG renderer on real Kindle hardware.
#
# Runs a user-supplied Lua snippet in an isolated KOReader LuaJIT process with:
#   - Real Kindle FreeType / HarfBuzz / Noto CJK fonts and 300 DPI metrics
#   - An offscreen Blitbuffer.TYPE_BB8 canvas (`OFFSCREEN_BB`, `SCREEN_W`, `SCREEN_H`)
#   - Isolated /tmp settings directory (never mutates live /mnt/us/koreader/settings)
#   - Zero writes to /dev/fb0 (safe while the user is reading or downloading)
#
# Your Lua snippet receives globals `OFFSCREEN_BB`, `SCREEN_W`, `SCREEN_H`:
# simply construct your KOReader widget and call `widget:paintTo(OFFSCREEN_BB, 0, 0)`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 2 ]]; then
    cat >&2 <<'EOF'
Usage:
  KINDLE_HOST=192.168.x.x kindle_offscreen_render.sh <render_snippet.lua> <local_out.png> [width] [height] [dpi]

Example render_snippet.lua:
  package.path = "plugins/aidoku.koplugin/?.lua;" .. package.path
  local InfoMessage = require("ui/widget/infomessage")
  local msg = InfoMessage:new{ text = "Hello E-Ink Offscreen!" }
  msg:paintTo(OFFSCREEN_BB, 100, 300)
EOF
    exit 2
fi

SNIPPET_FILE="$1"
LOCAL_OUT="$2"
WIDTH="${3:-1272}"
HEIGHT="${4:-1696}"
DPI="${5:-300}"

if [[ ! -f "$SNIPPET_FILE" ]]; then
    echo "error: Lua snippet file not found: $SNIPPET_FILE" >&2
    exit 1
fi

REMOTE_TMP="/tmp/ko_offscreen_$$"

{
    cat <<EOF
require("setupkoenv")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")

SCREEN_W, SCREEN_H = ${WIDTH}, ${HEIGHT}
local DPI = ${DPI}
OFFSCREEN_BB = Blitbuffer.new(SCREEN_W, SCREEN_H, Blitbuffer.TYPE_BB8)
OFFSCREEN_BB:fill(Blitbuffer.COLOR_WHITE)

local fake_screen = setmetatable({
    bb = OFFSCREEN_BB,
    dpi = DPI,
    getWidth = function() return SCREEN_W end,
    getHeight = function() return SCREEN_H end,
    getSize = function() return Geom:new{ w = SCREEN_W, h = SCREEN_H } end,
    getDPI = function() return DPI end,
    scaleBySize = function(_, px) return math.floor(px * (DPI / 167) + 0.5) end,
    scaleByDPI = function(_, px) return math.floor(px * (DPI / 167) + 0.5) end,
    getScaleFactor = function() return DPI / 167 end,
    getRotationMode = function() return 0 end,
    isPortrait = function() return SCREEN_W <= SCREEN_H end,
}, { __index = function() return function() end end })

local fake_device = setmetatable({
    screen = fake_screen,
    isTouchDevice = function() return true end,
    hasMultitouch = function() return true end,
    canUseWAL = function() return true end,
    isKindle = function() return true end,
    home_dir = "/mnt/us",
    powerd = setmetatable({}, { __index = function() return function() return 100 end end }),
    input = setmetatable({ event_map = {} }, { __index = function() return function() end end }),
}, { __index = function() return function() return false end end })

package.loaded["device"] = fake_device
require("document/canvascontext"):init(fake_device)

os.execute("mkdir -p '${REMOTE_TMP}/settings'")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("${REMOTE_TMP}/settings.reader.lua")
local DataStorage = require("datastorage")
DataStorage.getSettingsDir = function() return "${REMOTE_TMP}/settings" end

-- User render snippet begins
EOF
    cat "$SNIPPET_FILE"
    cat <<EOF

-- User render snippet ends
OFFSCREEN_BB:writePNG("${REMOTE_TMP}/out.png")
OFFSCREEN_BB:free()
EOF
} | "$SCRIPT_DIR/kindle_ssh.sh" exec "cd /mnt/us/koreader && ./luajit - >/dev/null && cat '${REMOTE_TMP}/out.png'; rc=\$?; rm -rf '${REMOTE_TMP}'; exit \$rc" > "$LOCAL_OUT"

echo "Rendered offscreen PNG -> $LOCAL_OUT"
