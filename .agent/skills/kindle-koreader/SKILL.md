---
name: kindle-koreader
description: Operate, deploy to, visually test, and debug a physical Kindle running KOReader over SSH. Use when connecting to a Kindle over SSH, capturing E-Ink framebuffer screenshots, injecting touch taps/holds/swipes, rendering KOReader widgets offscreen, or developing/debugging `.koplugin` Lua and Go binaries on Kindle hardware.
---

# Kindle + KOReader Device Operations & Visual Testing

Deterministic workflow for driving a physical Kindle running KOReader's SSH server (`dropbear`), deploying `.koplugin` bundles, capturing E-Ink screenshots, injecting touch gestures, and verifying UI changes without disrupting active user sessions.

Bundled scripts live in [`scripts/`](scripts/) relative to this `SKILL.md`:
- `scripts/kindle_ssh.sh` — SSH command runner and clean macOS-to-Kindle `tar` deployer
- `scripts/kindle_screenshot.py` — Zero-dependency `/dev/fb0` → PNG capture & pixel-diff bounding-box locator
- `scripts/kindle_touch.sh` — Multi-Touch Type B (`pt_mt` + `BTN_TOUCH`) tap, long-press, and swipe injector via KOReader's `luajit` FFI
- `scripts/kindle_offscreen_render.sh` — Headless KOReader widget → PNG renderer (never touches `/dev/fb0` or the live session)

For KOReader Lua, `lua-ljsqlite3`, `json` null-sentinel, background subprocess, and i18n pitfalls, read [`koreader-lua-pitfalls.md`](koreader-lua-pitfalls.md).

---

## Environment Variables

Set target coordinates once per shell session (defaults: `KINDLE_PORT=2222`, `KINDLE_USER=root`):

```bash
export KINDLE_HOST="192.168.x.x"
export KINDLE_PORT="2222"
```

---

## Core Workflow

### Step 1: Probe & Observe Before Acting (Mandatory)

1. Verify SSH reachability, architecture, and running KOReader processes:
   ```bash
   scripts/kindle_ssh.sh exec "uname -m; grep 'CPU architecture' /proc/cpuinfo | head -1; ps | grep reader.lua"
   ```
   - **Note on CPU arch**: Newer Kindles (e.g., PW5/PW6 on Bellatrix4) run a **32-bit `armv7l` userland** even on 64-bit SoCs. Cross-compile Go binaries with `CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 -trimpath -ldflags="-s -w"`.
2. Capture the current screen **before** touching or restarting anything:
   ```bash
   python3 scripts/kindle_screenshot.py capture /tmp/kindle_before.png
   ```
3. Read `/tmp/kindle_before.png` visually.
   - **Active-session guardrail**: If the user is actively reading or running a background download queue, **do not restart `reader.lua` or inject screen taps**. Deploy files in place and verify UI via **Step 5 (Offscreen Rendering)** instead.

### Step 2: Deploy Plugin Files Safely

KOReader plugins live at `/mnt/us/koreader/plugins/<name>.koplugin`.

```bash
scripts/kindle_ssh.sh deploy ./aidoku.koplugin /mnt/us/koreader/plugins/aidoku.koplugin
```

Key constraints enforced by `kindle_ssh.sh`:
- **Never pass `-o BatchMode=yes`** to SSH: KOReader's passwordless Dropbear uses empty-password auth, which `BatchMode=yes` rejects with `Permission denied (publickey,password)`.
- **Always set `COPYFILE_DISABLE=1`** on macOS `tar`: prevents `._*` AppleDouble resource-fork files from littering `/mnt/us` (FAT32/vfat).
- **Never back up directories into `/mnt/us/<backup>` or `/tmp/<large>`**: `/mnt/us/*` folders appear directly in KOReader's File Manager, and `/tmp` is a small RAM `tmpfs`. Store small temporary backups under `/var/tmp/` and clean them up when done.
- **Keep binary pipes clean**: macOS Homebrew OpenSSH may print an `ssh_askpass` warning on `stderr`; never merge remote `2>&1` into binary `stdout` pipes (`gzip`, `tar`, `cat`).

### Step 3: Visual Capture & Exact Coordinate Discovery

Never guess touch coordinates by eye on high-DPI (300 DPI, e.g., `1272×1696`) E-Ink panels.

1. Capture a baseline screenshot:
   ```bash
   python3 scripts/kindle_screenshot.py capture /tmp/s0.png
   ```
2. Find horizontal row separators / toolbar icon clusters, or diff two screenshots (`s0.png` vs `s1.png`) after opening a modal/keyboard to get exact pixel bounding boxes:
   ```bash
   python3 scripts/kindle_screenshot.py lines /tmp/s0.png
   python3 scripts/kindle_screenshot.py diff /tmp/s0.png /tmp/s1.png
   ```

### Step 4: Inject Touch Gestures (`tap` / `hold` / `swipe`)

```bash
scripts/kindle_touch.sh tap 60 55              # Tap top-left hamburger icon
scripts/kindle_touch.sh hold 500 415           # 900ms long-press on a list row
scripts/kindle_touch.sh swipe 600 1200 600 400 # Vertical swipe
```

Why raw `evdev` scripts often fail on Kindle (handled automatically by `kindle_touch.sh`):
- Kindle touch controllers (`pt_mt`, Multi-Touch Protocol B) + KOReader's `snow_protocol` handler ignore contacts unless **both** a fresh non-repeating `ABS_MT_TRACKING_ID (0x39)` **and** `EV_KEY BTN_TOUCH (0x14a = 1 -> 0)` are emitted around the contact lifecycle.
- `kindle_touch.sh` auto-discovers the touchscreen `/dev/input/eventX` node from `/proc/bus/input/devices` and drives it through `/mnt/us/koreader/luajit`'s built-in `ffi` (no `evtest` or C compiler needed on device).

### Step 5: Restarting KOReader vs. Offscreen Rendering

Lua `require()` caches loaded `.koplugin` modules in memory. For live changes to take effect:

- **Option A — Offscreen Headless Render (Preferred when user session is busy, or for rapid multi-language UI checks)**:
  Renders real KOReader widgets (`Menu`, `TitleBar`, `Blitbuffer.TYPE_BB8`, Kindle 300 DPI FreeType/HarfBuzz fonts) into `/tmp/*.png` in a separate `luajit` process **without touching `/dev/fb0` or live SQLite/LuaSettings**:
  ```bash
  scripts/kindle_offscreen_render.sh my_render_snippet.lua /tmp/preview.png
  ```

- **Option B — Clean KOReader Restart (Only when screen is idle)**:
  KOReader's launch wrapper (`/var/tmp/koreader.sh`) loops **only while `./reader.lua` exits with code `85`**.
  - **Never run `killall -9 reader.lua`**: exit code != 85 breaks the wrapper loop and drops back to the native Kindle UI.
  - Restart cleanly via KOReader's UI (**Power → Restart**, which calls `UIManager:restartKOReader()` -> `quit(85)`), or via KOReader HTTP Inspector if enabled (`GET /koreader/UIManager/restartKOReader/`), then check `/mnt/us/koreader/crash.log` for clean plugin load.

---

## Running Standalone KOReader Lua / SQLite Inspection via SSH

Always `cd /mnt/us/koreader` and `require("setupkoenv")` first so `libs/lib*.so` (`libsqlite3`, `libblitbuffer`, `libfreetype`, `libkoreader-lfs`) resolve properly:

```bash
scripts/kindle_ssh.sh exec "cd /mnt/us/koreader && ./luajit -e '
require(\"setupkoenv\")
local SQ3 = require(\"lua-ljsqlite3/init\")
local db = SQ3.open(\"/mnt/us/koreader/aidoku/library.db\")
local stmt = db:prepare(\"SELECT source_key, title FROM library\")
local row = {}
while stmt:step(row) do print(row[1], row[2]) end
stmt:close(); db:close()
'"
```

Tail `/mnt/us/koreader/crash.log` after every plugin reload to verify zero Lua tracebacks or plugin loader warnings.
