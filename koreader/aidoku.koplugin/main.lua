--[[--
Aidoku plugin: browse Aidoku manga source repositories, search and download
chapters as CBZ via a bundled aidoku-run binary (see cmd/aidoku-run in the
parent Go repo), and read them in KOReader.
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher") -- luacheck:ignore
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local T = require("ffi/util").template
local _ = require("aidoku_l10n")

local ChapterCache = require("chaptercache")
local ChapterOrder = require("chapterorder")
local ComicLayout = require("comiclayout")
local DownloadQueue = require("downloadqueue")
local DownloadsEngine = require("downloadsengine")
local Engine = require("engine")
local EpubHelper = require("epubhelper")
local InstalledSources = require("installedsources")
local KooboneSync = require("koobonesync")
local OpenWidgets = require("openwidgets")
local SimpleUIBridge = require("simpleui_bridge")
local Store = require("store")

local Aidoku = WidgetContainer:extend{
    name = "aidoku",
    is_doc_only = false,
}

-- binArch returns the plugin's bin/ subdirectory for the running device.
-- jit.arch (LuaJIT's arch name) matches Go's GOARCH for arm64 and x86-64
-- ("x64"), but unlike GOARCH it doesn't distinguish ARM versions -- it
-- reports "arm" on both armv6 and armv7 hardware. koreader/build.sh ships
-- separate armv6/armv7 binaries (older Kindles -- Kindle 4, Touch, PW1 --
-- are ARMv6; newer Kindles and Kobos are ARMv7), so on "arm" we read
-- /proc/cpuinfo's "CPU architecture" line to pick between them, falling
-- back to the more common armv7 if that's ever unavailable/unparseable.
local function binArch()
    if jit.arch ~= "arm" then
        return jit.arch
    end
    local cpuinfo = io.open("/proc/cpuinfo", "r")
    if cpuinfo then
        for line in cpuinfo:lines() do
            local ver = line:match("^CPU architecture%s*:%s*(%d+)")
            if ver then
                cpuinfo:close()
                return tonumber(ver) <= 6 and "armv6" or "armv7"
            end
        end
        cpuinfo:close()
    end
    return "armv7"
end

-- dataSubdir builds a path under DataStorage's data dir, stripped of a
-- leading "./" -- DataStorage:getDataDir() can return the bare "." on
-- devices that exec a relative "./reader.lua" (confirmed on a real
-- Kindle), and KOReader's own recorded document paths never carry "./",
-- so leaving it in self.downloads_dir silently breaks every
-- `file:sub(1, #self.downloads_dir) == self.downloads_dir` prefix check
-- below and in nextchapter.lua (read-marking, auto-advance, Library
-- return all no-op with no error). Stripping it here is a no-op for I/O
-- itself.
local function dataSubdir(name)
    local base = DownloadsEngine.fullDataDir() .. "/aidoku"
    if type(name) == "string" and name ~= "" then
        return base .. "/" .. name
    end
    return base
end

function Aidoku:init()
    self.sources_dir = dataSubdir("sources")
    self.settings_dir = dataSubdir("settings")
    self.covers_dir = dataSubdir("covers")
    util.makePath(self.sources_dir)
    util.makePath(self.settings_dir)
    util.makePath(self.covers_dir)

    -- self.path is set by KOReader's plugin loader to this plugin's own
    -- directory; bin_arch (see binArch() above) names match the targets
    -- koreader/build.sh produces ("armv6"/"armv7" for Kindles/Kobos,
    -- "arm64"/"x64" for aarch64/x86-64 devices and desktops).
    local bin_arch = binArch()
    -- Kept on self (not just the local above) so other top-level screens
    -- (see librarybrowser.lua's "aidoku = self" threading) can build the
    -- same "aidoku-koplugin-<bin_arch>-*" asset name the release workflow
    -- uses, without duplicating binArch()'s /proc/cpuinfo probing.
    self.bin_arch = bin_arch
    self.store = Store.new(dataSubdir(""))
    if type(_.setLanguage) == "function" then
        _.setLanguage(self.store:language())
    end
    self.engine = Engine.new(self.path .. "/bin/" .. bin_arch .. "/aidoku-run", function()
        local concurrency = self.store:networkConcurrency()
        return {
            FLARESOLVERR_HOST = self.store:flareSolverrHost(),
            AIDOKU_SETTINGS_DIR = self.settings_dir,
            NETWORK_CONCURRENCY = concurrency > 0 and tostring(concurrency) or "",
        }
    end)

    -- Must run after self.store exists -- see refreshDownloadsDir()'s own doc
    -- comment for why this isn't just done once here.
    self:refreshDownloadsDir()
    if self.document and self.ui and self.ui.doc_settings then
        self:applyAdaptiveComicSettings(self.ui.doc_settings, self.document)
    end
    self:ensureBuiltinSources()

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:registerFileDialogButtons()
    self:hookEndOfBook()
    self:hookShowFileManager()
    self:hookClose()
    self.simpleui_active = SimpleUIBridge.setup(self)
    self:openPendingLibrary()
end

-- refreshDownloadsDir (re)computes self.downloads_dir/self.downloads_engine
-- to either the normal data dir or Ephemeral Mode's RAM-disk path,
-- depending on the current setting. Called from init() and again from
-- settingsbrowser.lua's toggleEphemeralMode() so the toggle redirects
-- downloads immediately rather than only on the next plugin-instance
-- construction.
function Aidoku:refreshDownloadsDir()
    -- Kept on self so settingsbrowser.lua can refuse it as the Ephemeral path.
    self.persistent_downloads_dir = dataSubdir("downloads")
    self.downloads_dir = self.store:isEphemeralMode()
        and self.store:ephemeralPath() or self.persistent_downloads_dir
    util.makePath(self.downloads_dir)
    self.downloads_engine = DownloadsEngine.new(self.downloads_dir, self.engine)
    DownloadQueue:setContext({
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        downloads_dir = self.downloads_dir,
    })
end

-- applyAdaptiveComicSettings seeds sane KOReader paging/zoom defaults onto
-- unopened comic archives (CBZ/CBR/CBT/CB7) regardless of whether they were
-- opened from Tsundoku or KOReader's built-in library/FileManager.
function Aidoku:applyAdaptiveComicSettings(doc_settings, document)
    return ComicLayout.applyToDocSettings(doc_settings, document, {
        store = self.store,
        downloads_engine = self.downloads_engine,
        downloads_dir = self.downloads_dir,
        persistent_downloads_dir = self.persistent_downloads_dir,
    })
end

-- Also hook DocSettingsLoad idempotently without returning true so downstream
-- plugins (such as docsettingtweak.koplugin) continue receiving the event.
function Aidoku:onDocSettingsLoad(doc_settings, document)
    self:applyAdaptiveComicSettings(doc_settings, document)
end

local _builtin_sources_checked = {}

-- ensureBuiltinSources copies bundled first-party Aidoku sources (such as
-- `kox-v1.aix`) from `<plugin>/builtin_sources/` into `<data_dir>/aidoku/sources/`
-- when not yet installed or when a newer built-in version ships with an update.
function Aidoku:ensureBuiltinSources(force)
    local cache_key = tostring(self.path) .. "\0" .. tostring(self.sources_dir)
    if not force and _builtin_sources_checked[cache_key] then
        return
    end
    _builtin_sources_checked[cache_key] = true
    local lfs = require("libs/libkoreader-lfs")
    local builtin_dir = self.path .. "/builtin_sources"
    if lfs.attributes(builtin_dir, "mode") ~= "directory" then
        return
    end
    for entry in lfs.dir(builtin_dir) do
        local id, ver_str = entry:match("^(.+)%-v(%d+)%.aix$")
        if id and ver_str then
            local builtin_ver = tonumber(ver_str) or 1
            local installed_max = 0
            local older_files = {}
            for cur in lfs.dir(self.sources_dir) do
                local cid, cver_str = cur:match("^(.+)%-v(%d+)%.aix$")
                if cid == id then
                    local cver = tonumber(cver_str) or 0
                    if cver > installed_max then
                        installed_max = cver
                    end
                    if cver < builtin_ver then
                        table.insert(older_files, self.sources_dir .. "/" .. cur)
                    end
                end
            end
            if installed_max < builtin_ver then
                local src_f = io.open(builtin_dir .. "/" .. entry, "rb")
                if src_f then
                    local data = src_f:read("*a")
                    src_f:close()
                    local dst_path = self.sources_dir .. "/" .. entry
                    local tmp_path = dst_path .. ".tmp"
                    local dst_f = io.open(tmp_path, "wb")
                    if dst_f then
                        local ok = dst_f:write(data)
                        ok = dst_f:close() and ok
                        if ok and os.rename(tmp_path, dst_path) then
                            for _i, old_p in ipairs(older_files) do
                                os.remove(old_p)
                            end
                            local InstalledSources = require("installedsources")
                            InstalledSources.invalidateCache()
                        else
                            os.remove(tmp_path)
                        end
                    end
                end
            end
        end
    end
end

-- markCurrentChapterRead flags self.document's chapter as read (see
-- store.lua's read_chapters), independent of next_chapter_mode -- unlike
-- nextchapter.lua's own byPath lookup, this must run even when
-- auto-advance is off, so it's a separate lookup rather than something
-- threaded through NextChapter.handle(). downloads_engine:byPath() is a
-- synchronous SQLite read (see downloadsengine.lua), so no Trapper:wrap()
-- coroutine is needed here.
function Aidoku:syncCurrentEpubProgress(inclusive)
    local file = self.document and self.document.file
    if not file or not EpubHelper.isEpub(file) or not DownloadsEngine.isUnder(file, self.downloads_dir) then
        return
    end
    local entry = self.downloads_engine and self.downloads_engine:byPath(file)
    if entry then
        local synced = EpubHelper.syncReadChapters(file, self.store, entry.sourceKey, entry.mangaKey, {
            inclusive = inclusive,
            ui = self.ui,
        })
        if synced and synced > 0 then
            SimpleUIBridge.invalidate()
        end
    end
end

function Aidoku:markCurrentChapterRead()
    local file = self.document and self.document.file
    if not file or not DownloadsEngine.isUnder(file, self.downloads_dir) then
        return
    end
    if EpubHelper.isEpub(file) then
        self:syncCurrentEpubProgress(true)
        return
    end
    local entry = self.downloads_engine:byPath(file)
    if entry then
        self.store:markChapterRead(entry.sourceKey, entry.mangaKey, entry.chapterKey)
        SimpleUIBridge.invalidate()
    end
end

-- hookEndOfBook wires up auto-advance to the next chapter. Only applies
-- inside ReaderUI (self.document is only set there, not FileManager).
--
-- Can't suppress ReaderStatus's own "end of document" pop-up via a
-- same-named event handler here -- it's registered before plugins and
-- never returns true, so propagation always reaches it regardless. Instead
-- this monkey-patches its onEndOfBook method directly: ours runs first and
-- falls through to the original when the document isn't one of ours.
function Aidoku:hookEndOfBook()
    if not self.document or not self.ui.status then
        return
    end
    local original_on_end_of_book = self.ui.status.onEndOfBook
    self.ui.status.onEndOfBook = function(status_self, ...)
        self:markCurrentChapterRead()
        local NextChapter = require("nextchapter")
        local handled = NextChapter.handle({
            engine = self.engine,
            store = self.store,
            downloads_engine = self.downloads_engine,
            downloads_dir = self.downloads_dir,
            sources_dir = self.sources_dir,
            ui = self.ui,
            open_callback = function(path) self.ui:switchDocument(path) end,
            reload_callback = function(xp)
                if self.ui.reloadDocument then
                    self.ui:reloadDocument()
                end
                if xp then
                    EpubHelper.jumpOpenDocument(self.ui, xp)
                end
            end,
        }, self.document.file)
        if handled then
            return true
        end
        return original_on_end_of_book(status_self, ...)
    end
end

-- hookShowFileManager makes every "back to Files" path return to Aidoku's
-- own Library screen instead of KOReader's raw file browser, when the
-- chapter being closed is one of ours. Every such path (onHome, the
-- end-of-document pop-up, the top-bar file-browser icon) funnels through
-- ReaderUI:showFileManager(file), so hooking that one method (same
-- monkey-patch technique as hookEndOfBook) covers all of them.
--
-- showFileManager tears down this plugin instance and spins up a new
-- FileManager (and, since is_doc_only = false, a new Aidoku instance for
-- it) -- with no direct way to hand that future instance a "reopen the
-- Library" instruction, this leaves a note in pendinglibrary.lua (a
-- require()-cached table, shared across the teardown/recreate boundary)
-- for its init() to act on -- see openPendingLibrary() below.
function Aidoku:hookShowFileManager()
    if not self.document then
        return
    end
    local original_show_file_manager = self.ui.showFileManager
    self.ui.showFileManager = function(ui_self, file, ...)
        self:syncCurrentEpubProgress(false)
        file = file or (self.document and self.document.file)
        local pending = require("pendinglibrary")
        local from_tsundoku = pending.from_tsundoku
        pending.from_tsundoku = false
        if from_tsundoku and file and DownloadsEngine.isUnder(file, self.downloads_dir) then
            pending.open = true
        else
            pending.open = false
        end
        return original_show_file_manager(ui_self, file, ...)
    end
end

-- hookClose closes any Aidoku screen still open (openwidgets.lua) right
-- before self.ui closes -- covers Exit, Restart, and the Reader<->
-- FileManager handoff, all of which route through onClose(). Each Aidoku
-- screen is its own top-level UIManager widget, not a child of self.ui, so
-- drilling from one into another leaves ancestors buried on the window
-- stack; UIManager's run loop only stops once that stack is fully empty,
-- so a leftover screen silently blocks KOReader from quitting (see
-- openwidgets.lua). Applies to both FileManager and ReaderUI instances,
-- unlike the ReaderUI-only hooks above.
function Aidoku:hookClose()
    local original_on_close = self.ui.onClose
    self.ui.onClose = function(ui_self, ...)
        self:syncCurrentEpubProgress(false)
        OpenWidgets.closeAll()
        return original_on_close(ui_self, ...)
    end
end

-- Reopens the Library screen on top of a freshly shown FileManager when a
-- previous ReaderUI instance's hookShowFileManager() (above) requested it.
function Aidoku:openPendingLibrary()
    if self.document then
        return
    end
    local pending = require("pendinglibrary")
    pending.from_tsundoku = false
    if not pending.open then
        return
    end
    pending.open = false
    UIManager:nextTick(function() self:onAidokuBrowseSources() end)
end

function Aidoku:registerFileDialogButtons()
    if self.document or not self.ui or type(self.ui.addFileDialogButtons) ~= "function" then
        return
    end
    self.ui:addFileDialogButtons("aidoku_open_series", function(file, _is_file)
        if not DownloadsEngine.isUnder(file, self.downloads_dir) then
            return nil
        end
        return {{
            {
                text = _.brandName() .. " · " .. _("Open Manga Series"),
                callback = function()
                    local fm = FileManager.instance or self.ui
                    if fm then
                        for _idx, comp in ipairs({ fm.file_chooser, fm.filesearcher, fm.history, fm.collections }) do
                            if comp and comp.file_dialog then
                                UIManager:close(comp.file_dialog)
                            end
                        end
                    end
                    self:openSeriesForFile(file, true)
                end,
            },
        }}
    end)
end

function Aidoku:onDispatcherRegisterActions()
    local prefix = _.brandName() .. ": "
    Dispatcher:registerAction("aidoku_browse_sources", {
        category = "none",
        event = "AidokuBrowseSources",
        title = prefix .. _("Manga Library"),
        general = true,
    })
    Dispatcher:registerAction("tsundoku_search", {
        category = "none",
        event = "TsundokuSearch",
        title = prefix .. _("Search Manga"),
        general = true,
    })
    Dispatcher:registerAction("tsundoku_koobone_sync", {
        category = "none",
        event = "TsundokuSyncKoobone",
        title = prefix .. _("Refresh Koobone"),
        general = true,
    })
    Dispatcher:registerAction("tsundoku_koobone", {
        category = "none",
        event = "TsundokuKoobone",
        title = prefix .. _("Koobone Shelf"),
        general = true,
    })
    Dispatcher:registerAction("tsundoku_downloads", {
        category = "none",
        event = "TsundokuDownloads",
        title = prefix .. _("Downloads"),
        general = true,
    })
end

function Aidoku:ensureReady()
    if not self.engine:isAvailable() then
        UIManager:show(InfoMessage:new{
            text = _("aidoku-run binary not found. Rebuild the plugin with koreader/build.sh."),
        })
        return false
    end
    if not self.downloads_engine:isAvailable() then
        UIManager:show(InfoMessage:new{
            text = _("Could not open the downloads database. Is storage writable?"),
        })
        return false
    end
    return true
end

function Aidoku:buildMainMenuItems()
    local items = {}
    local cur_file = self.document and self.document.file
    if cur_file and DownloadsEngine.isUnder(cur_file, self.downloads_dir) then
        local series = SimpleUIBridge.findSeriesByPath(cur_file)
        local title_label = series and series.title or _("Current Manga")
        table.insert(items, {
            text = T(_("Current: %1"), title_label),
            callback = function()
                self:openSeriesForFile(cur_file, true)
            end,
        })
        table.insert(items, {
            text = _("Next Chapter"),
            callback = function()
                self:stepCurrentMangaChapter(1)
            end,
        })
        table.insert(items, {
            text = _("Previous Chapter"),
            callback = function()
                self:stepCurrentMangaChapter(-1)
            end,
            separator = true,
        })
    end

    table.insert(items, {
        text = _("Manga Library"),
        callback = function()
            self:onAidokuBrowseSources()
        end,
    })
    table.insert(items, {
        text = _("Search Manga"),
        callback = function()
            self:onTsundokuSearch(true)
        end,
    })
    table.insert(items, {
        text = _("Refresh Koobone"),
        callback = function()
            self:onTsundokuSyncKoobone()
        end,
    })
    table.insert(items, {
        text = _("Koobone Shelf"),
        callback = function()
            self:onTsundokuKoobone()
        end,
        separator = true,
    })
    table.insert(items, {
        text = _("Downloads"),
        callback = function()
            self:onTsundokuDownloads()
        end,
    })
    table.insert(items, {
        text = _("Manga Sources"),
        callback = function()
            self:onTsundokuSources()
        end,
    })
    table.insert(items, {
        text = _("Settings"),
        callback = function()
            self:onTsundokuSettings()
        end,
    })
    return items
end

function Aidoku:addToMainMenu(menu_items)
    menu_items.aidoku = {
        sorting_hint = "tools",
        text = _.brandName(),
        text_func = function()
            return _.brandName()
        end,
        sub_item_table_func = function()
            return self:buildMainMenuItems()
        end,
    }
end

function Aidoku:onShow()
    return self:onAidokuBrowseSources()
end

-- Every entry into Library -- a fresh open from the FileManager menu, or
-- the Reader->FileManager handoff reopening it via openPendingLibrary()
-- above -- wipes chaptercache.lua, so a manga's chapter list refreshes for
-- real next time it's opened rather than staying pinned to whatever was
-- cached from an earlier read session. See chaptercache.lua's own note for
-- why it stays valid across chapter-to-chapter advances within one session.
function Aidoku:onAidokuBrowseSources()
    ChapterCache.clear()
    if not self:ensureReady() then
        return
    end

    local LibraryBrowser = require("librarybrowser")
    UIManager:show(LibraryBrowser:new{
        aidoku = self,
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        settings_dir = self.settings_dir,
        covers_dir = self.covers_dir,
        downloads_dir = self.downloads_dir,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
    })
end

function Aidoku:onTsundokuSearch(prompt_immediately)
    if not self:ensureReady() then
        return
    end
    local GlobalSearchBrowser = require("globalsearchbrowser")
    UIManager:show(GlobalSearchBrowser:new{
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        downloads_dir = self.downloads_dir,
        prompt_immediately = prompt_immediately ~= false,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        refresh_callback = function()
            SimpleUIBridge.invalidate()
            SimpleUIBridge.refreshSimpleUIScreens(false)
        end,
    })
end

function Aidoku:onTsundokuKoobone()
    if not self:ensureReady() then
        return
    end
    local KooboneBrowser = require("koobonebrowser")
    UIManager:show(KooboneBrowser:new{
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        downloads_dir = self.downloads_dir,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        refresh_callback = function()
            SimpleUIBridge.invalidate()
            SimpleUIBridge.refreshSimpleUIScreens(false)
        end,
    })
end

function Aidoku:onTsundokuSyncKoobone(on_done)
    if not self:ensureReady() then
        if type(on_done) == "function" then
            pcall(on_done, nil, "not_ready")
        end
        return
    end
    if not KooboneSync.hasCredentials(self.settings_dir) then
        UIManager:show(Notification:new{
            text = _("Please log in to Koobone first."),
            timeout = 2.5,
        })
        self:onTsundokuKoobone()
        if type(on_done) == "function" then
            pcall(on_done, nil, "no_credentials")
        end
        return
    end

    UIManager:show(Notification:new{
        text = _("Syncing Koobone subscriptions…"),
        timeout = 2,
    })

    KooboneSync:manualSync({
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        downloads_dir = self.downloads_dir,
        sources_dir = self.sources_dir,
        settings_dir = self.settings_dir,
        covers_dir = self.covers_dir,
        on_cover_ready = function()
            SimpleUIBridge.invalidate()
            SimpleUIBridge.refreshSimpleUIScreens(false)
        end,
    }, {
        on_already_running = function()
            UIManager:show(Notification:new{
                text = _("Koobone sync is already running…"),
                timeout = 2,
            })
        end,
        on_complete = function(stats, err)
            SimpleUIBridge.invalidate()
            SimpleUIBridge.refreshSimpleUIScreens(false)
            if err and err ~= "no_credentials" then
                UIManager:show(Notification:new{
                    text = T(_("Koobone sync failed: %1"), tostring(err)),
                    timeout = 3,
                })
            elseif stats then
                local msg
                if (stats.newly_queued or 0) > 0 then
                    msg = T(_("Koobone: queued %1 new chapters."), stats.newly_queued)
                elseif (stats.bookmarked or 0) > 0 then
                    msg = T(_("Koobone: added %1 series to library."), stats.bookmarked)
                else
                    msg = T(_("Koobone is up to date (%1 items)."), stats.total or 0)
                end
                UIManager:show(Notification:new{
                    text = msg,
                    timeout = 2.5,
                })
            end
            if type(on_done) == "function" then
                pcall(on_done, stats, err)
            end
        end,
    })
end

function Aidoku:onTsundokuDownloads()
    if not self:ensureReady() then
        return
    end
    local DownloadsBrowser = require("downloadsbrowser")
    UIManager:show(DownloadsBrowser:new{
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        downloads_dir = self.downloads_dir,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
    })
end

function Aidoku:onTsundokuSources()
    if not self:ensureReady() then
        return
    end
    local SourcesBrowser = require("sourcesbrowser")
    UIManager:show(SourcesBrowser:new{
        aidoku = self,
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        downloads_dir = self.downloads_dir,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
    })
end

function Aidoku:onTsundokuSettings()
    if not self:ensureReady() then
        return
    end
    local SettingsBrowser = require("settingsbrowser")
    UIManager:show(SettingsBrowser:new{
        aidoku = self,
        engine = self.engine,
        store = self.store,
        downloads_engine = self.downloads_engine,
        ui = self.ui,
        sources_dir = self.sources_dir,
        downloads_dir = self.downloads_dir,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        refresh_callback = function()
            SimpleUIBridge.invalidate()
            SimpleUIBridge.refreshSimpleUIScreens(false)
        end,
    })
end

function Aidoku:openSeriesObject(series, offline_first)
    if not self:ensureReady() then
        return
    end
    if not series then
        self:onAidokuBrowseSources()
        return
    end
    Trapper:wrap(function()
        local source_key = series.source_key or ""
        local source_path = series.source_path or ""
        local source_name = source_key ~= "" and source_key or _.brandName()
        if source_key ~= "" then
            local found = InstalledSources.findByKey(self.sources_dir, self.engine, source_key)
            if found then
                source_path = found.path
                source_name = found.name
            end
        end
        local manga_key = (series.dl_group and type(series.dl_group.mangaKey) == "string" and series.dl_group.mangaKey ~= "")
            and series.dl_group.mangaKey or (series.manga_key or "")
        local MangaBrowser = require("mangabrowser")
        UIManager:show(MangaBrowser:new{
            engine = self.engine,
            store = self.store,
            downloads_engine = self.downloads_engine,
            ui = self.ui,
            sources_dir = self.sources_dir,
            source_path = source_path,
            source_key = source_key,
            source_name = source_name,
            downloads_dir = self.downloads_dir,
            offline_first = offline_first ~= false,
            manga = {
                Key = manga_key,
                Title = series.title,
                Cover = series.cover_url ~= "" and series.cover_url or nil,
            },
            is_popout = false,
            is_borderless = true,
            title_bar_fm_style = true,
            refresh_callback = function()
                SimpleUIBridge.invalidate()
                SimpleUIBridge.refreshSimpleUIScreens(false)
            end,
        })
    end)
end

function Aidoku:openSeriesForFile(filepath, offline_first)
    local series = SimpleUIBridge.findSeriesByPath(filepath)
    if series then
        self:openSeriesObject(series, offline_first)
        return
    end
    local entry = self.downloads_engine and self.downloads_engine:byPath(filepath)
    if entry then
        self:openSeriesObject({
            source_key = entry.sourceKey,
            source_path = entry.sourcePath,
            manga_key = entry.mangaKey,
            title = entry.mangaTitle,
            dl_group = { mangaKey = entry.mangaKey },
        }, offline_first)
        return
    end
    self:onAidokuBrowseSources()
end

function Aidoku:stepCurrentMangaChapter(delta)
    if not self.document or not self.document.file then
        return
    end
    if EpubHelper.isEpub(self.document.file) then
        local manifest = EpubHelper.readManifest(self.document.file)
        if not manifest or type(manifest.chapters) ~= "table" or #manifest.chapters == 0 then
            UIManager:show(InfoMessage:new{ text = _("No adjacent downloaded chapters found."), timeout = 2 })
            return
        end
        local xp = EpubHelper.currentXPointer(self.document.file, self.ui)
        local cur_idx = EpubHelper.parseDocFragmentIndex(xp) or 1
        local target_idx = cur_idx + (delta or 1)
        if target_idx < 1 or target_idx > #manifest.chapters then
            UIManager:show(Notification:new{
                text = (delta or 1) > 0 and _("Already at latest downloaded chapter.") or _("Already at first downloaded chapter."),
                timeout = 2,
            })
            return
        end
        if (delta or 1) > 0 then
            local cur_ch = manifest.chapters[cur_idx]
            local entry = self.downloads_engine and self.downloads_engine:byPath(self.document.file)
            if cur_ch and cur_ch.key and cur_ch.key ~= "" and entry then
                self.store:markChapterRead(entry.sourceKey, entry.mangaKey, cur_ch.key)
                SimpleUIBridge.invalidate()
            end
        end
        EpubHelper.jumpOpenDocument(self.ui, string.format("/body/DocFragment[%d]/body", target_idx))
        return
    end
    local series = SimpleUIBridge.findSeriesByPath(self.document.file)
    if not series or not series.chapters or #series.chapters == 0 then
        UIManager:show(InfoMessage:new{ text = _("No adjacent downloaded chapters found."), timeout = 2 })
        return
    end
    local norm_cur = DownloadsEngine.normalizePath(self.document.file)
    local cur_idx
    for idx, ch in ipairs(series.chapters) do
        if DownloadsEngine.normalizePath(ch.path) == norm_cur then
            cur_idx = idx
            break
        end
    end
    if not cur_idx then
        return
    end
    local target_idx = cur_idx + (delta or 1)
    local target = series.chapters[target_idx]
    if not target or not target.path then
        UIManager:show(Notification:new{
            text = (delta or 1) > 0 and _("Already at latest downloaded chapter.") or _("Already at first downloaded chapter."),
            timeout = 2,
        })
        return
    end
    if (delta or 1) > 0 then
        self:markCurrentChapterRead()
    end
    self.ui:switchDocument(target.path)
end

return Aidoku
