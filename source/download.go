package source

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/ohaiibuzzle/aidokurunner-go/cbz"
	"github.com/ohaiibuzzle/aidokurunner-go/epub"
	"github.com/ohaiibuzzle/aidokurunner-go/models"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime/host"
)

// downloadPage resolves a single Page's content to its raw image bytes,
// handling all three PageContent kinds: URL (HTTP GET, fetched via the
// source's get_image_request and then run through process_page_image if the
// source has one), Image (a host.Store descriptor holding a
// previously-decoded image.Image or raw bytes), and ZipFile (a zip
// downloaded from URL, with the page being one entry inside it, cached in
// zipCache across a chapter's pages). Like upstream, only URL pages are
// processed.
func (s *Source) downloadPage(ctx context.Context, page models.Page, zipCache map[string][]byte) ([]byte, error) {
	switch page.Content.Kind {
	case models.PageContentKindURL:
		return s.downloadURLPage(ctx, page.Content.URL, page.Content.Context)
	case models.PageContentKindImage:
		return s.resolveImageRef(page.Content.ImageRef)
	case models.PageContentKindZipFile:
		return s.downloadZipEntry(ctx, page.Content.URL, page.Content.FilePath, zipCache)
	default:
		return nil, fmt.Errorf("source: page content kind %d has no downloadable image", page.Content.Kind)
	}
}

func (s *Source) resolveImageRef(ref models.ImageRef) ([]byte, error) {
	// Every other GlobalStore consumer frees its descriptor right after use
	// (see the defer i.RemoveValue(...) calls throughout runner.go); this
	// one didn't, so a decoded (uncompressed, often much bigger than the
	// compressed page bytes) image stayed pinned in memory for the rest of
	// the process for every page a descrambling source produced this way.
	defer s.Runner.RemoveValue(ref)
	switch v := s.Runner.Fetch(ref).(type) {
	case []byte:
		return v, nil
	case image.Image:
		var buf bytes.Buffer
		if err := png.Encode(&buf, v); err != nil {
			return nil, fmt.Errorf("source: encoding stored image %d: %w", ref, err)
		}
		return buf.Bytes(), nil
	default:
		return nil, fmt.Errorf("source: image ref %d not found", ref)
	}
}

func (s *Source) downloadZipEntry(ctx context.Context, zipURL, filePath string, cache map[string][]byte) ([]byte, error) {
	data, ok := cache[zipURL]
	if !ok {
		var err error
		data, err = s.downloadURL(ctx, zipURL)
		if err != nil {
			return nil, fmt.Errorf("source: downloading zip %s: %w", zipURL, err)
		}
		if cache != nil {
			cache[zipURL] = data
		}
	}

	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("source: opening zip %s: %w", zipURL, err)
	}
	for _, f := range zr.File {
		if f.Name != filePath {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("source: opening %s in zip %s: %w", filePath, zipURL, err)
		}
		defer rc.Close()
		// The entry's declared size is the zip's say-so: bound what it
		// actually inflates to (a few-KB entry can expand to GBs).
		return host.ReadAllLimited(rc, host.MaxResponseBytes)
	}
	return nil, fmt.Errorf("source: entry %q not found in zip %s", filePath, zipURL)
}

// DownloadChapterCBZ downloads every page of chapter, in order, to a CBZ at
// outputPath (auto-generated from the manga/chapter title if ""). The base
// filename is always run through sanitizeFilename, even when outputPath is
// caller-supplied -- a manga/chapter title baked into that path can contain
// characters illegal on e-reader filesystems like FAT32/exFAT.
//
// mangaDirName, if given, inserts a new sanitized directory by that name
// between outputPath's (caller-owned, untouched) directory and the chapter
// file, since this function can't otherwise tell a title-derived segment
// needing sanitizing apart from a real caller-controlled directory.
//
// onProgress, if non-nil, is called after each page (1-indexed current,
// total). Returns the path written to. Pages stream straight to disk rather
// than buffering the whole chapter, to avoid OOM on memory-constrained
// devices (e.g. Kindle).
func (s *Source) DownloadChapterCBZ(ctx context.Context, manga models.Manga, chapter models.Chapter, outputPath, mangaDirName string, onProgress func(current, total int)) (string, error) {
	pages, err := s.GetPageList(ctx, manga, chapter)
	if err != nil {
		return "", fmt.Errorf("source: getting page list: %w", err)
	}
	return s.WriteChapterCBZFromPages(ctx, manga, chapter, pages, outputPath, mangaDirName, onProgress)
}

// WriteChapterCBZFromPages downloads image pages from an already-fetched page
// list and streams them into a CBZ archive at outputPath.
func (s *Source) WriteChapterCBZFromPages(ctx context.Context, manga models.Manga, chapter models.Chapter, pages []models.Page, outputPath, mangaDirName string, onProgress func(current, total int)) (string, error) {
	if len(pages) == 0 {
		return "", fmt.Errorf("source: chapter %q has no pages", chapter.Key)
	}

	var err error
	outputPath, err = ResolveOutputPath(outputPath, mangaDirName, manga, chapter)
	if err != nil {
		return "", err
	}
	w, err := cbz.NewWriter(outputPath, len(pages))
	if err != nil {
		return "", err
	}

	comicInfo, err := buildComicInfo(manga, chapter, len(pages)).Marshal()
	if err != nil {
		w.Abort()
		return "", fmt.Errorf("source: building ComicInfo.xml: %w", err)
	}
	if err := w.WriteComicInfo(comicInfo); err != nil {
		w.Abort()
		return "", err
	}

	zipCache := make(map[string][]byte)
	for i, page := range pages {
		img, err := s.downloadPage(ctx, page, zipCache)
		if err != nil {
			w.Abort()
			return "", fmt.Errorf("source: downloading page %d/%d: %w", i+1, len(pages), err)
		}
		if err := w.WritePage(img); err != nil {
			w.Abort()
			return "", fmt.Errorf("source: writing page %d/%d: %w", i+1, len(pages), err)
		}
		if onProgress != nil {
			onProgress(i+1, len(pages))
		}
	}

	if err := w.Close(); err != nil {
		return "", err
	}
	return outputPath, nil
}

// IsTextPages reports whether a chapter's pages carry text content rather than
// downloadable images.
func IsTextPages(pages []models.Page) bool {
	if len(pages) == 0 {
		return false
	}
	for _, p := range pages {
		if p.Content.Kind != models.PageContentKindText {
			return false
		}
	}
	return true
}

// JoinTextPages concatenates PageContentKindText pages into a single chapter body.
func JoinTextPages(pages []models.Page) string {
	var parts []string
	for _, p := range pages {
		if p.Content.Kind == models.PageContentKindText && p.Content.Text != "" {
			parts = append(parts, p.Content.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func resolveBookDir(outputPath, mangaDirName string) string {
	sub := sanitizeFilename(mangaDirName)
	var dir string
	if outputPath != "" {
		dir, _ = filepath.Split(outputPath)
	}
	if mangaDirName != "" && sub != "" {
		cleanDir := filepath.Clean(dir)
		if filepath.Base(cleanDir) != sub {
			dir = filepath.Join(dir, sub)
		} else {
			dir = cleanDir
		}
	}
	return dir
}

// ResolveBookEPUBPath computes the canonical single-book EPUB path for manga:
// <outputDir>/<sanitized mangaDirName>/<sanitized mangaLabel>.epub.
// If outputPath already points to an existing .epub file or already ends in
// <sanitized mangaDirName>/<filename>, it returns that path idempotently
// without nesting mangaDirName a second time.
func ResolveBookEPUBPath(outputPath, mangaDirName string, manga models.Manga) (string, error) {
	sub := sanitizeFilename(mangaDirName)
	if outputPath != "" && strings.EqualFold(filepath.Ext(outputPath), ".epub") {
		cleanOut := filepath.Clean(outputPath)
		isRootPlaceholder := filepath.Base(cleanOut) == "book.epub" && mangaDirName != "" && sub != "" && filepath.Base(filepath.Dir(cleanOut)) != sub
		if !isRootPlaceholder {
			if st, err := os.Stat(cleanOut); err == nil && !st.IsDir() {
				return cleanOut, nil
			}
		}
	}

	base := sanitizeFilename(MangaLabel(manga))
	if base == "" {
		base = "book"
	}
	filename := base + ".epub"
	fullPath := filepath.Join(resolveBookDir(outputPath, mangaDirName), filename)
	if parent := filepath.Dir(fullPath); parent != "." && parent != "" {
		if err := os.MkdirAll(parent, 0o755); err != nil {
			return "", fmt.Errorf("source: creating %s: %w", parent, err)
		}
	}
	return fullPath, nil
}

// ResolveVolumeEPUBPath computes the canonical sharded volume EPUB path for
// manga: <outputDir>/<sanitized mangaDirName>/<sanitized title [0001-0050]>.epub.
func ResolveVolumeEPUBPath(outputPath, mangaDirName string, manga models.Manga, volumeIndex, volumeSize int) (string, error) {
	if volumeSize <= 0 {
		volumeSize = epub.DefaultChaptersPerVolume
	}
	if volumeIndex < 1 {
		volumeIndex = 1
	}
	_, start, end := epub.VolumeForOrder((volumeIndex-1)*volumeSize+1, volumeSize)

	base := MangaLabel(manga)
	if base == "" {
		base = "book"
	}
	filename := sanitizeFilename(base+epub.VolumeRangeSuffix(start, end)) + ".epub"
	if filename == ".epub" {
		filename = "book" + epub.VolumeRangeSuffix(start, end) + ".epub"
	}

	fullPath := filepath.Join(resolveBookDir(outputPath, mangaDirName), filename)
	if parent := filepath.Dir(fullPath); parent != "." && parent != "" {
		if err := os.MkdirAll(parent, 0o755); err != nil {
			return "", fmt.Errorf("source: creating %s: %w", parent, err)
		}
	}
	return fullPath, nil
}

// CanonicalReadingKeys mirrors chapterorder.lua's orderedByOriginalTOC to
// return chapter keys in ascending reading order (oldest-first). When
// numbered chapters contain duplicate ChapterNumber values (e.g., multi-volume
// web novels that restart numbering per volume), raw positional 1 -> N order is
// preserved so volumes do not interleave.
func CanonicalReadingKeys(chapters []models.Chapter) []string {
	n := len(chapters)
	if n == 0 {
		return nil
	}
	positional := make([]models.Chapter, n)
	for i := 0; i < n; i++ {
		positional[i] = chapters[n-1-i]
	}

	type indexedChapter struct {
		ch  models.Chapter
		pos int
	}
	var numbered []indexedChapter
	seen := make(map[float32]struct{}, n)
	allUnique := true
	for i, c := range positional {
		if c.ChapterNumber != nil {
			if _, dup := seen[*c.ChapterNumber]; dup {
				allUnique = false
				break
			}
			seen[*c.ChapterNumber] = struct{}{}
			numbered = append(numbered, indexedChapter{ch: c, pos: i})
		}
	}

	if !allUnique || len(numbered) == 0 {
		keys := make([]string, n)
		for i, c := range positional {
			keys[i] = c.Key
		}
		return keys
	}

	sort.Slice(numbered, func(i, j int) bool {
		ni, nj := *numbered[i].ch.ChapterNumber, *numbered[j].ch.ChapterNumber
		if ni != nj {
			return ni < nj
		}
		return numbered[i].pos < numbered[j].pos
	})

	keys := make([]string, 0, n)
	ni := 0
	for _, c := range positional {
		if c.ChapterNumber != nil {
			keys = append(keys, numbered[ni].ch.Key)
			ni++
		} else {
			keys = append(keys, c.Key)
		}
	}
	return keys
}

// BuildEPUBMeta converts a models.Manga into epub.BookMeta.
func BuildEPUBMeta(sourceKey string, manga models.Manga) epub.BookMeta {
	meta := epub.BookMeta{
		SourceKey: sourceKey,
		MangaKey:  manga.Key,
		Title:     MangaLabel(manga),
		Authors:   manga.Authors,
		Language:  "zh",
	}
	if manga.Description != nil {
		meta.Description = *manga.Description
	}
	return meta
}

// BuildChapterInput converts a models.Chapter and text body into an epub.ChapterInput.
func BuildChapterInput(chapter models.Chapter, text string, tocOrder int) epub.ChapterInput {
	var dateUploaded *int64
	if chapter.DateUploaded != nil {
		ts := chapter.DateUploaded.Unix()
		dateUploaded = &ts
	}
	return epub.ChapterInput{
		Key:           chapter.Key,
		Title:         ChapterLabel(chapter),
		Text:          text,
		ChapterNumber: chapter.ChapterNumber,
		VolumeNumber:  chapter.VolumeNumber,
		DateUploaded:  dateUploaded,
		TOCOrder:      tocOrder,
	}
}

var webtoonTagKeywords = []string{
	"webtoon",
	"long strip",
	"longstrip",
	"条漫",
	"條漫",
}

// EffectiveViewer returns manga.Viewer when known, or infers ViewerWebtoon
// from manga.Tags when the source left ViewerUnknown.
func EffectiveViewer(manga models.Manga) models.Viewer {
	if manga.Viewer != models.ViewerUnknown {
		return manga.Viewer
	}
	for _, tag := range manga.Tags {
		norm := strings.ToLower(strings.TrimSpace(tag))
		if norm == "" {
			continue
		}
		for _, kw := range webtoonTagKeywords {
			if strings.Contains(norm, kw) {
				return models.ViewerWebtoon
			}
		}
	}
	return models.ViewerUnknown
}

// buildComicInfo maps the manga/chapter fields that translate onto
// ComicInfo.xml honestly -- see cbz.ComicInfo's doc comment for how
// EffectiveViewer maps onto Format and Manga.
func buildComicInfo(manga models.Manga, chapter models.Chapter, pageCount int) cbz.ComicInfo {
	info := cbz.ComicInfo{
		Series:    manga.Title,
		Genre:     strings.Join(manga.Tags, ", "),
		Writer:    strings.Join(manga.Authors, ", "),
		PageCount: pageCount,
	}
	switch EffectiveViewer(manga) {
	case models.ViewerRightToLeft:
		info.Manga = "YesAndRightToLeft"
	case models.ViewerLeftToRight:
		info.Manga = "No"
	case models.ViewerVertical, models.ViewerWebtoon:
		info.Format = "Webtoon"
	}
	if chapter.Title != nil {
		info.Title = *chapter.Title
	}
	if manga.Description != nil {
		info.Summary = *manga.Description
	}
	if len(manga.Artists) > 0 {
		artists := strings.Join(manga.Artists, ", ")
		info.Penciller = artists
		info.CoverArtist = artists
	}
	if chapter.ChapterNumber != nil {
		info.Number = formatComicInfoNumber(*chapter.ChapterNumber)
	}
	if chapter.VolumeNumber != nil {
		info.Volume = formatComicInfoNumber(*chapter.VolumeNumber)
	}
	if chapter.URL != nil {
		info.Web = *chapter.URL
	} else if manga.URL != nil {
		info.Web = *manga.URL
	}
	if chapter.Language != nil {
		info.LanguageISO = *chapter.Language
	}
	if len(chapter.Scanlators) > 0 {
		info.ScanInformation = strings.Join(chapter.Scanlators, ", ")
	}
	if chapter.DateUploaded != nil {
		y, m, d := chapter.DateUploaded.Date()
		info.Year, info.Month, info.Day = y, int(m), d
	}
	return info
}

// formatComicInfoNumber renders a ComicInfo Number/Volume value, dropping a
// pointless ".0" for whole numbers -- the same convention ChapterLabel
// already uses for display.
func formatComicInfoNumber(n float32) string {
	if n == float32(int64(n)) {
		return strconv.FormatInt(int64(n), 10)
	}
	return strconv.FormatFloat(float64(n), 'g', -1, 32)
}

func defaultCBZName(manga models.Manga, chapter models.Chapter) string {
	return sanitizeFilename(fmt.Sprintf("%s - %s", MangaLabel(manga), ChapterLabel(chapter))) + ".cbz"
}

// ResolveOutputPath computes the final, sanitized path DownloadChapterCBZ
// will write to and makes sure its directory exists, creating a
// mangaDirName subdirectory along the way if one was requested. Exported so
// a caller can learn the real path before the download (e.g. to steer clear
// of a filename another chapter already owns); passing its result back to
// DownloadChapterCBZ with mangaDirName "" resolves to the same path, since
// sanitizing is idempotent.
func ResolveOutputPath(outputPath, mangaDirName string, manga models.Manga, chapter models.Chapter) (string, error) {
	if outputPath == "" {
		outputPath = defaultCBZName(manga, chapter)
	} else {
		dir, base := filepath.Split(outputPath)
		if mangaDirName != "" {
			dir = filepath.Join(dir, sanitizeFilename(mangaDirName))
		}
		// The whole name, extension included: an unsanitized extension could
		// carry FAT-illegal chars and slip past the byte cap. truncateFilename
		// keeps the tail, so a normal ".cbz" survives truncation.
		outputPath = filepath.Join(dir, sanitizeFilename(base))
	}
	if dir := filepath.Dir(outputPath); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return "", fmt.Errorf("source: creating %s: %w", dir, err)
		}
	}
	return outputPath, nil
}

// MangaLabel is manga's display title, falling back to its key when it has
// none.
func MangaLabel(manga models.Manga) string {
	if manga.Title != "" {
		return manga.Title
	}
	return manga.Key
}

// ChapterLabel is chapter's display label: its own title if it has one,
// else "Chapter N" from ChapterNumber, else its key. Title takes priority
// over ChapterNumber (matching the KOReader plugin's own chapterLabel in
// mangabrowser.lua, which this must agree with for a chapter's displayed
// name to be consistent between the plugin's UI and a downloads index
// entry recorded by the "download" command).
func ChapterLabel(chapter models.Chapter) string {
	if chapter.Title != nil && *chapter.Title != "" {
		return *chapter.Title
	}
	if chapter.ChapterNumber != nil {
		n := *chapter.ChapterNumber
		if n == float32(int64(n)) {
			return fmt.Sprintf("Chapter %d", int64(n))
		}
		return fmt.Sprintf("Chapter %g", n)
	}
	return chapter.Key
}

var filenameSanitizer = strings.NewReplacer(
	"/", "-",
	"\\", "-",
	":", "-",
	"*", "-",
	"?", "-",
	"\"", "'",
	"<", "-",
	">", "-",
	"|", "-",
)

// sanitizeFilename is the single authoritative point that turns a
// manga/chapter title into a safe path component. filenameSanitizer only
// strips characters illegal on FAT32/exFAT -- "." and ".." contain none of
// those, so they'd otherwise pass through untouched. ResolveOutputPath's
// mangaDirName is used as a bare path component with nothing appended to
// neutralize that (unlike the chapter filename, which always gets a
// ".cbz" suffix), so a manga title of exactly ".." there would resolve
// outside the downloads directory via filepath.Join. Reject both here so
// every caller is safe, not just the ones that happen to append a fixed
// suffix.
func sanitizeFilename(s string) string {
	s = filenameSanitizer.Replace(s)
	// ASCII control characters (0x00-0x1F, 0x7F) are illegal on the same
	// FAT32/exFAT filesystems filenameSanitizer targets, but contain none of
	// the punctuation it replaces, so they'd otherwise pass through
	// untouched and can still fail cbz.Writer.Close()'s os.Rename. Dropped
	// rather than replaced with a placeholder -- a run of them shouldn't
	// inflate the filename with dashes.
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7F {
			return -1
		}
		return r
	}, s)
	// Trim only after dropping control characters: trimming first left
	// "Omake \x01" as "Omake " here and "Omake" on a second pass, so
	// ResolveOutputPath's result didn't survive DownloadChapterCBZ's re-sanitize.
	s = truncateFilename(strings.TrimSpace(s))
	if s == "." || s == ".." {
		return "-"
	}
	return s
}

// maxFilenameBytes keeps a sanitized name under ext4's 255-byte NAME_MAX
// (and FAT32/exFAT's 255 UTF-16 units, never more than the UTF-8 byte
// count) with room left for UnusedPath's " [xxxxxxxx]" and ".cbz".
const maxFilenameBytes = 200

// truncateFilename shortens an over-long name to head + " ~hash~ " + tail,
// cut on rune boundaries. Keeping the tail preserves the plugin's
// " [source_key]" manga-dir suffix (so two sources' copies of one long title
// stay apart), and the hash of the full name keeps two long titles that
// share a prefix and suffix apart. Deterministic, so the same title always
// maps to the same name; names that fit are returned untouched.
func truncateFilename(s string) string {
	if len(s) <= maxFilenameBytes {
		return s
	}
	const tailBytes = 48
	sum := sha256.Sum256([]byte(s))
	mid := " ~" + hex.EncodeToString(sum[:4]) + "~ "
	head := maxFilenameBytes - tailBytes - len(mid)
	for head > 0 && !utf8.RuneStart(s[head]) {
		head--
	}
	tail := len(s) - tailBytes
	for tail < len(s) && !utf8.RuneStart(s[tail]) {
		tail++
	}
	return strings.TrimRight(s[:head], " ") + mid + strings.TrimLeft(s[tail:], " ")
}
