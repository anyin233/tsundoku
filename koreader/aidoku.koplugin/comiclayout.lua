--[[--
ComicLayout: Adaptive KOReader layout injection for CBZ/CBR/CBT/CB7 comic & manga archives.

Detects whether a comic archive is standard page-based manga ("paged") or
long-strip vertical comic ("webtoon") using three complementary signals:
  1. Tsundoku metadata: downloads/index.db (`viewer`) and library.db (`manga_meta.viewer`),
     populated from Aidoku's `models.Viewer` enum and tag heuristics.
  2. Embedded `ComicInfo.xml` header: `<Format>Webtoon</Format>` or webtoon keywords in
     `<Genre>` / `<Tags>` (preserving classification even when files are moved outside
     Tsundoku's downloads directory or imported from external tools).
  3. Multi-page MuPDF geometry sampling: computes the median `height / width` across up to
     3 evenly spaced interior pages (threshold >= 2.10 -> "webtoon", otherwise "paged").

Applied only to unopened comic archives (`document.is_new == true` with neither
`zoom_mode` nor `kopt_page_scroll` set in `doc_settings`), so user per-document changes
are always preserved and non-comic formats (PDF/DjVu/EPUB/MOBI) are untouched.
]]

local DownloadsEngine = require("downloadsengine")
local lfs = require("libs/libkoreader-lfs")

local ComicLayout = {}

ComicLayout.WEBTOON_ASPECT_THRESHOLD = 2.10

local COMIC_EXTENSIONS = {
    cbz = true,
    cbr = true,
    cbt = true,
    cb7 = true,
}

local WEBTOON_KEYWORDS = {
    "webtoon",
    "long strip",
    "longstrip",
    "条漫",
    "條漫",
}

local MAX_SAMPLE_PAGES = 3
local XML_HEAD_READ_BYTES = 8192
local MAX_COMICINFO_BYTES = 65536

local function fileExtension(file)
    if type(file) ~= "string" or file == "" then
        return ""
    end
    local base = file:match("([^/\\]+)$") or file
    local ext = base:match("%.([^%.]+)$")
    return ext and ext:lower() or ""
end

function ComicLayout.isComicArchive(file)
    return COMIC_EXTENSIONS[fileExtension(file)] == true
end

function ComicLayout.isWebtoonTag(tag)
    if type(tag) ~= "string" or tag == "" then
        return false
    end
    local norm = tag:match("^%s*(.-)%s*$"):lower()
    if norm == "" then
        return false
    end
    for _idx, kw in ipairs(WEBTOON_KEYWORDS) do
        if norm:find(kw, 1, true) then
            return true
        end
    end
    return false
end

function ComicLayout.viewerFromManga(manga)
    if type(manga) ~= "table" then
        return 0
    end
    if type(manga.Viewer) == "number" and manga.Viewer > 0 then
        return math.floor(manga.Viewer)
    end
    if type(manga.Tags) == "table" then
        for _idx, tag in ipairs(manga.Tags) do
            if ComicLayout.isWebtoonTag(tag) then
                return 4 -- models.ViewerWebtoon
            end
        end
    end
    return 0
end

function ComicLayout.xmlMatchesWebtoon(xml)
    if type(xml) ~= "string" or xml == "" then
        return false
    end
    if not xml:find("ComicInfo", 1, true) then
        return false
    end
    if xml:find("<Format>%s*[Ww][Ee][Bb][Tt][Oo][Oo][Nn]%s*</Format>") then
        return true
    end
    local genre = xml:match("<Genre>(.-)</Genre>")
    if genre and ComicLayout.isWebtoonTag(genre) then
        return true
    end
    local tags = xml:match("<Tags>(.-)</Tags>")
    if tags and ComicLayout.isWebtoonTag(tags) then
        return true
    end
    return false
end

local function readEntryOneComicInfo(file)
    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not ok_arch or not Archiver or not Archiver.Reader then
        return nil
    end
    local reader = Archiver.Reader:new()
    if not reader:open(file) then
        reader:close()
        return nil
    end
    local xml = nil
    for entry in reader:iterate() do
        if entry.mode == "file" and type(entry.path) == "string" then
            local lower = entry.path:lower()
            local size = tonumber(entry.size) or 0
            if (lower == "comicinfo.xml" or lower:match("/comicinfo%.xml$"))
                and size > 0 and size <= MAX_COMICINFO_BYTES
            then
                xml = reader:extractToMemory(entry.path)
            end
        end
        -- Only inspect entry #1 so opening huge archives remains O(1).
        break
    end
    reader:close()
    return xml
end

function ComicLayout.hasWebtoonComicInfo(file)
    if type(file) ~= "string" or file == "" then
        return false
    end
    local ext = fileExtension(file)
    if ext == "cbz" then
        local f = io.open(file, "rb")
        if f then
            local head = f:read(XML_HEAD_READ_BYTES)
            f:close()
            if head then
                if ComicLayout.xmlMatchesWebtoon(head) then
                    return true
                end
                local head_lower = head:lower()
                -- Only invoke libarchive if entry #1 is ComicInfo.xml AND the closing
                -- tag wasn't already inside the uncompressed 8 KB header prefix.
                if not head_lower:find("comicinfo.xml", 1, true) then
                    return false
                end
                if head_lower:find("</comicinfo>", 1, true) then
                    return false
                end
            end
        end
    end
    local ok, xml = pcall(readEntryOneComicInfo, file)
    if ok and xml then
        return ComicLayout.xmlMatchesWebtoon(xml)
    end
    return false
end

local function buildSamplePageIndices(n)
    if n <= 0 then
        return {}
    end
    if n <= 3 then
        local pages = {}
        for i = 1, n do
            table.insert(pages, i)
        end
        return pages
    end
    local lo, hi = 2, n - 1
    local span = hi - lo + 1
    local count = math.min(MAX_SAMPLE_PAGES, span)
    if count == 1 then
        return { lo }
    end
    local pages = {}
    local seen = {}
    for i = 0, count - 1 do
        local p = lo + math.floor((i * (span - 1)) / (count - 1) + 0.5)
        if p >= 1 and p <= n and not seen[p] then
            seen[p] = true
            table.insert(pages, p)
        end
    end
    return pages
end

function ComicLayout.sampleMedianAspectRatio(document)
    if not document or type(document.getNativePageDimensions) ~= "function" then
        return nil
    end
    local page_count = nil
    if type(document.getPageCount) == "function" then
        local ok, count = pcall(document.getPageCount, document)
        if ok and type(count) == "number" then
            page_count = count
        end
    end
    if not page_count and type(document.info) == "table" then
        page_count = tonumber(document.info.number_of_pages)
    end
    if not page_count or page_count <= 0 then
        return nil
    end

    local ratios = {}
    for _idx, pageno in ipairs(buildSamplePageIndices(page_count)) do
        local ok, dim = pcall(document.getNativePageDimensions, document, pageno)
        if ok and type(dim) == "table" then
            local w = tonumber(dim.w) or 0
            local h = tonumber(dim.h) or 0
            if w > 0 and h > 0 then
                table.insert(ratios, h / w)
            end
        end
    end
    if #ratios == 0 then
        return nil
    end
    table.sort(ratios)
    local mid = math.floor(#ratios / 2) + 1
    if #ratios % 2 == 1 then
        return ratios[mid]
    end
    return (ratios[mid - 1] + ratios[mid]) / 2
end

local function lookupViewerFromStore(file, ctx)
    if not ctx then
        return 0
    end
    local entry = ctx.downloads_engine and ctx.downloads_engine:byPath(file) or nil
    if not entry and type(ctx.persistent_downloads_dir) == "string"
        and ctx.persistent_downloads_dir ~= ""
        and ctx.persistent_downloads_dir ~= ctx.downloads_dir
        and lfs.attributes(ctx.persistent_downloads_dir .. "/index.db", "mode") == "file"
    then
        local persistent_engine = DownloadsEngine.new(ctx.persistent_downloads_dir)
        entry = persistent_engine:byPath(file)
        if persistent_engine.conn then
            pcall(persistent_engine.conn.close, persistent_engine.conn)
        end
    end
    local viewer = (entry and tonumber(entry.viewer)) or 0
    if viewer == 0 and entry and ctx.store and type(ctx.store.mangaViewer) == "function" then
        viewer = tonumber(ctx.store:mangaViewer(entry.sourceKey, entry.mangaKey)) or 0
    end
    return viewer
end

function ComicLayout.detectKind(document, ctx)
    if not document or type(document.file) ~= "string" then
        return "paged"
    end
    -- Signal 1: Tsundoku downloads index / library metadata.
    local viewer = lookupViewerFromStore(document.file, ctx)
    if viewer == 3 or viewer == 4 then
        return "webtoon"
    end
    -- Signal 2: Embedded ComicInfo.xml header.
    if ComicLayout.hasWebtoonComicInfo(document.file) then
        return "webtoon"
    end
    -- Signal 3: Multi-page aspect ratio sampling.
    local median = ComicLayout.sampleMedianAspectRatio(document)
    if median and median >= ComicLayout.WEBTOON_ASPECT_THRESHOLD then
        return "webtoon"
    end
    return "paged"
end

function ComicLayout.applyProfile(doc_settings, profile)
    if not doc_settings then
        return false
    end
    doc_settings:saveSetting("kopt_trim_page", 0)
    doc_settings:saveSetting("kopt_text_wrap", 0)
    doc_settings:saveSetting("kopt_page_opt", 0)
    doc_settings:saveSetting("panel_zoom_enabled", true)

    if profile == "webtoon" then
        doc_settings:saveSetting("kopt_page_scroll", 1)
        doc_settings:saveSetting("kopt_page_gap_height", 0)
        doc_settings:saveSetting("zoom_mode", "pagewidth")
        doc_settings:saveSetting("normal_zoom_mode", "pagewidth")
        doc_settings:saveSetting("kopt_zoom_mode_genus", 4)
        doc_settings:saveSetting("kopt_zoom_mode_type", 1)
    else
        doc_settings:saveSetting("kopt_page_scroll", 0)
        doc_settings:saveSetting("zoom_mode", "page")
        doc_settings:saveSetting("normal_zoom_mode", "page")
        doc_settings:saveSetting("kopt_zoom_mode_genus", 4)
        doc_settings:saveSetting("kopt_zoom_mode_type", 2)
    end
    return true
end

function ComicLayout.applyToDocSettings(doc_settings, document, ctx)
    if not doc_settings or not document or type(document.file) ~= "string" then
        return false, "invalid"
    end
    if not ComicLayout.isComicArchive(document.file) then
        return false, "non_comic"
    end
    if not document.is_new then
        return false, "existing"
    end
    if doc_settings:has("zoom_mode") or doc_settings:has("kopt_page_scroll") then
        return false, "already_configured"
    end

    local mode = (ctx and ctx.store and type(ctx.store.comicReaderMode) == "function")
        and ctx.store:comicReaderMode() or "auto"
    if mode == "off" then
        return false, "off"
    end

    local profile
    if mode == "paged" or mode == "webtoon" then
        profile = mode
    else
        profile = ComicLayout.detectKind(document, ctx)
    end
    ComicLayout.applyProfile(doc_settings, profile)
    return true, profile
end

return ComicLayout
