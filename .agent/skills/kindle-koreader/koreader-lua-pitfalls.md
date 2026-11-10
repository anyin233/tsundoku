# KOReader Lua, SQLite, Subprocess & i18n Pitfalls Reference

Battle-tested engineering rules for developing KOReader plugins (`.koplugin`) on resource-constrained Kindle Linux (`armv7l` / `armv6l`, 256MB–1GB RAM, FAT32 `/mnt/us`).

---

## 1. JSON Decoding (`null` Function Sentinel)

KOReader's `json.decode` decodes JSON `null` into a **Lua function sentinel**, NOT `nil`.
In Lua, functions are truthy (`if obj.Cover then` evaluates to **true** on JSON `null`!).

- **Wrong**:
  ```lua
  local title = chapter.Title or chapter.Key       -- returns function sentinel if Title is null!
  local items = result.Entries or {}               -- returns function sentinel if Entries is null!
  ```
- **Right**:
  ```lua
  local title = (type(chapter.Title) == "string" and chapter.Title ~= "") and chapter.Title or chapter.Key
  local items = type(result.Entries) == "table" and result.Entries or {}
  local num   = type(chapter.ChapterNumber) == "number" and chapter.ChapterNumber or nil
  ```
- When re-encoding Lua tables back to JSON (`json.encode`), recursively strip `type(v) == "function"` keys first, and omit empty array tables (`next(t) == nil`) where Go expects `[]T` (`json.encode({})` emits `"{}"`, which fails Go slice unmarshaling).

---

## 2. `lua-ljsqlite3` & Kindle Kernel Constraints

1. **`tonumber()` everything**: `lua-ljsqlite3` returns `INTEGER` columns either as Lua strings or LuaJIT FFI `int64_t` cdata (`13912401LL`). Comparing cdata or strings directly with Lua numbers causes subtle bugs or errors. Always coerce via `tonumber(row[i]) or 0`.
2. **Gate WAL behind `Device:canUseWAL()`**: Older Kindle kernels fail `mmap` on `/mnt/us` (`vfat`/FUSE) when `PRAGMA journal_mode=WAL` is forced unconditionally.
   ```lua
   db:set_busy_timeout(5000)
   if Device:canUseWAL() then
       db:exec("PRAGMA journal_mode=WAL;")
   else
       db:exec("PRAGMA journal_mode=TRUNCATE;")
   end
   ```
3. **Wrap UI queries in `pcall`**: Concurrent CLI/background writes can briefly contend on SQLite locks; wrap `prepare`/`bind`/`step` in a helper returning a safe fallback, and always close statements.

---

## 3. FAT32 (`/mnt/us`) Path & Filename Rules

- Strip leading `./` from `DataStorage:getDataDir()`: on Kindles launched via `./reader.lua`, `getDataDir()` returns `"."`, while KOReader's `document.file` paths are normalized without `"./"`, breaking prefix checks if unstripped.
- Sanitize archive/folder names against FAT32-illegal characters (`/ \ : * ? " < > |`, ASCII `0x00–0x1F`, trailing spaces/dots, `.` and `..`), and cap UTF-8 byte length (`<= 200` bytes) on rune boundaries.

---

## 4. Subprocesses: Foreground `Trapper` vs. Background Non-Blocking Queue

- **Foreground cancellable calls**: `Trapper:dismissablePopen(cmd, progress_text)` **must** run inside `Trapper:wrap(function() ... end)`. Outside a coroutine it falls back to blocking `io.popen()` and freezes the E-Ink UI.
- **Background non-blocking queues**: Do **not** use `Trapper:dismissablePopen` for background downloads or cover fetching — even an invisible `TrapWidget` sits on `UIManager`'s modal stack and can swallow or delay reader page-turn taps.
  - Instead, spawn via `local pid, parent_read_fd = ffiUtil.runInSubProcess(function(_pid, child_write_fd) ... end, true)`.
  - Poll via `UIManager:scheduleIn(0.35, pollFn)` using `ffiUtil.isSubProcessDone(pid)` and `ffiUtil.getNonBlockingReadSize(parent_read_fd)`.
  - Terminate on cancel via `ffiUtil.terminateSubProcess(pid)` (sends `SIGKILL` to process group `-pid` because `runInSubProcess` calls `setpgid(0, 0)`), and schedule a reaper loop until `isSubProcessDone(pid)` returns `true` so no zombie processes accumulate.
  - Guard device sleep during long background queues with `UIManager:preventStandby()` / `UIManager:allowStandby()`.

---

## 5. E-Ink Rendering & Widget Lifecycle

1. **Track top-level `Menu` screens**: Full-screen `Menu` subclasses pushed via `UIManager:show(...)` sit independently on `UIManager`'s window stack. Track them in a stack (`OpenWidgets`) and close all of them in a `self.ui.onClose` hook — otherwise an orphaned screen prevents KOReader from exiting or restarting!
2. **Throttle live progress repaints**: On E-Ink, coalesce rapid progress updates (`0.35s–0.45s` debounce via `UIManager:scheduleIn`) and mark dirty with `"ui"` (`UIManager:setDirty(widget, "ui")`) to avoid full-screen flashes.
3. **RenderImage scaling**: `RenderImage:scaleBlitBuffer(bb, w, h)` may free or retain the source `Blitbuffer` depending on dimensions; check `if scaled_bb ~= raw_bb then pcall(function() raw_bb:free() end) end` and dispose LRU-evicted `Blitbuffer`s explicitly to stay well within 256MB–512MB RAM limits.
4. **ASCII/BMP-safe glyphs**: KOReader's default `cfont` (`NotoSans` + CJK fallback) renders `✓`, `✗`, `★`, `▶`, `■`, `□`, `«`, `»`, `[✓]`, `[ ]` crisply, whereas multi-color emoji (`🔍`, `⚙`, `⏳`) may render as tofu boxes on Kindle firmware fonts.

---

## 6. Plugin-Local i18n (`gettext` Isolation & Live Language Switching)

1. **Never shadow `_`**: When `local _ = require("aidoku_l10n")` is in scope, **never** write `for _, item in ipairs(list)` — inside that loop `_` becomes the integer loop index, crashing `_("...")` with `attempt to call local '_' (a number value)`. Always write `for _idx, item in ipairs(list)`.
2. **Avoid `GetText.loadMO()` for shared msgids**: KOReader's `gettext` is a single global table; `loadMO` overwrites host translations (`"Cancel"`, `"Remove"`, `"Settings"`) app-wide and gets wiped on language change. Parse plugin `.po` catalogs into a plugin-local table instead.
3. **Avoid host-language bleed**: When a user explicitly selects a plugin language (`"en"`, `"ja"`, `"zh_CN"`, `"zh_TW"`) rather than `"auto"`, do **not** fall back to KOReader's global `gettext(msgid)` on cache miss (especially for `"en"`, where msgids have no `.mo` entry in KOReader and falling through to `gettext` when the host is Chinese turns English strings back into Chinese!).
4. **No load-time static `_()`**: Never bake `title = _("Library")` into `Menu:extend{ ... }` or module-level tables (`local LABELS = { off = _("Off") }`). Compute them inside `:init()` and `:refresh()` (updating `self.title_bar:setTitle(...)`) so runtime language switching updates open screens immediately without restarting KOReader.
