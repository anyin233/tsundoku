// Package epub creates and incrementally edits single-book EPUB 2 archives
// tuned for low-power e-ink devices (e.g. Kindle + KOReader crengine).
//
// Every archive entry uses zip.Store (no deflate compression) so both Go
// incremental repacking and on-device KOReader parsing avoid zlib CPU
// overhead. Unchanged chapter XHTML files are copied directly from the old
// archive via zip.File.OpenRaw / zip.Writer.CreateRaw, and only META-INF,
// OPF, NCX, and added/updated chapters are written fresh before an atomic
// rename into place.
//
// Spine items map 1:1 with ManifestChapters (no extra cover XHTML in <spine>),
// keeping KOReader's 1-indexed /body/DocFragment[k] XPointers aligned with
// chapter order.
package epub

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/ohaiibuzzle/aidokurunner-go/internal/fsutil"
)

const (
	// DefaultChaptersPerVolume is the fixed chapter cap per sharded EPUB
	// volume so crengine cold-opens stay sub-second on e-ink hardware.
	DefaultChaptersPerVolume = 50
	// BookIndexFilename is the per-book directory index read by Tsundoku's
	// full-book TOC hook to display chapters across all volumes at once.
	BookIndexFilename = ".tsundoku_book.json"

	manifestEntryPath = "META-INF/tsundoku.json"
	containerPath     = "META-INF/container.xml"
	opfEntryPath      = "OEBPS/content.opf"
	ncxEntryPath      = "OEBPS/toc.ncx"
	cssEntryPath      = "OEBPS/style.css"
	tempPattern       = ".epub-*.tmp"
	manifestVersion   = 2
)

// BookMeta holds book-level metadata embedded in OPF, NCX, and tsundoku.json.
type BookMeta struct {
	SourceKey   string
	MangaKey    string
	Title       string
	Authors     []string
	Description string
	Language    string
	VolumeIndex int
	VolumeSize  int
	VolumeStart int
	VolumeEnd   int
}

// ChapterInput supplies one chapter's content and ordering hints to UpsertChapters.
type ChapterInput struct {
	Key           string
	Title         string
	Text          string
	ChapterNumber *float32
	VolumeNumber  *float32
	DateUploaded  *int64
	TOCOrder      int // 1-based position in the source's original reading-order TOC, or 0 if unknown
}

// ManifestChapter is the persisted chapter record inside META-INF/tsundoku.json.
// Its slice index (0-based) in BookManifest.Chapters corresponds 1:1 to
// KOReader's /body/DocFragment[index+1] and the <spine> order in content.opf.
type ManifestChapter struct {
	Key           string   `json:"key"`
	Title         string   `json:"title"`
	Href          string   `json:"href"`
	ChapterNumber *float32 `json:"chapterNumber,omitempty"`
	VolumeNumber  *float32 `json:"volumeNumber,omitempty"`
	DateUploaded  *int64   `json:"dateUploaded,omitempty"`
	TOCOrder      int      `json:"tocOrder,omitempty"`
}

// BookManifest is stored in META-INF/tsundoku.json for fast O(1) TOC/spine
// inspection from both Go and KOReader Lua without parsing OPF/NCX XML.
type BookManifest struct {
	Version     int               `json:"version"`
	SourceKey   string            `json:"sourceKey"`
	MangaKey    string            `json:"mangaKey"`
	Title       string            `json:"title"`
	Authors     []string          `json:"authors,omitempty"`
	Description string            `json:"description,omitempty"`
	Language    string            `json:"language,omitempty"`
	VolumeIndex int               `json:"volumeIndex,omitempty"`
	VolumeSize  int               `json:"volumeSize,omitempty"`
	VolumeStart int               `json:"volumeStart,omitempty"`
	VolumeEnd   int               `json:"volumeEnd,omitempty"`
	Chapters    []ManifestChapter `json:"chapters"`
}

// UpdateResult summarizes an UpsertChapters or RemoveChapters edit.
type UpdateResult struct {
	Path          string
	TotalChapters int
	OldKeys       []string
	NewKeys       []string
	SpineShifted  bool
	SDRRemapped   bool
}

// ReadManifest reads and parses META-INF/tsundoku.json from epubPath.
func ReadManifest(epubPath string) (*BookManifest, error) {
	r, err := zip.OpenReader(epubPath)
	if err != nil {
		return nil, fmt.Errorf("epub: opening %s: %w", epubPath, err)
	}
	defer r.Close()
	return readManifestFromZip(&r.Reader)
}

func readManifestFromZip(zr *zip.Reader) (*BookManifest, error) {
	for _, f := range zr.File {
		if f.Name != manifestEntryPath {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("epub: opening %s: %w", manifestEntryPath, err)
		}
		data, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, fmt.Errorf("epub: reading %s: %w", manifestEntryPath, err)
		}
		var m BookManifest
		if err := json.Unmarshal(data, &m); err != nil {
			return nil, fmt.Errorf("epub: parsing %s: %w", manifestEntryPath, err)
		}
		return &m, nil
	}
	return nil, fmt.Errorf("epub: missing %s", manifestEntryPath)
}

func chapterHref(key string) string {
	sum := sha256.Sum256([]byte(key))
	return "ch_" + hex.EncodeToString(sum[:8]) + ".xhtml"
}

func chapterID(href string) string {
	base := strings.TrimSuffix(href, ".xhtml")
	if base == "" {
		return "ch"
	}
	return base
}

var xmlReplacer = strings.NewReplacer(
	"&", "&amp;",
	"<", "&lt;",
	">", "&gt;",
	`"`, "&quot;",
	"'", "&apos;",
)

func xmlEscape(s string) string {
	return xmlReplacer.Replace(stripInvalidXMLChars(s))
}

func stripInvalidXMLChars(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '\t' || r == '\n' || r == '\r' {
			return r
		}
		if r >= 0x20 && r != 0xFFFE && r != 0xFFFF && r != unicode.ReplacementChar {
			return r
		}
		if r == unicode.ReplacementChar {
			return r
		}
		return -1
	}, s)
}

func trimParagraphSpace(s string) string {
	return strings.TrimFunc(s, func(r rune) bool {
		return unicode.IsSpace(r) || r == '\u3000' || r == '\u00a0'
	})
}

// RenderChapterXHTML converts plain/line-broken chapter text into minimal,
// flat XHTML 1.1 optimized for fast crengine layout on low-RAM e-ink devices.
func RenderChapterXHTML(title, rawText string) []byte {
	cleanTitle := trimParagraphSpace(stripInvalidXMLChars(title))
	if cleanTitle == "" {
		cleanTitle = "章节"
	}

	var buf bytes.Buffer
	buf.Grow(len(rawText) + 512)
	buf.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	buf.WriteString(`<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">` + "\n")
	buf.WriteString(`<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh">` + "\n")
	buf.WriteString(`<head>` + "\n")
	buf.WriteString(`<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>` + "\n")
	buf.WriteString(`<title>`)
	buf.WriteString(xmlEscape(cleanTitle))
	buf.WriteString(`</title>` + "\n")
	buf.WriteString(`<link rel="stylesheet" type="text/css" href="style.css"/>` + "\n")
	buf.WriteString(`</head>` + "\n")
	buf.WriteString(`<body>` + "\n")
	buf.WriteString(`<h2>`)
	buf.WriteString(xmlEscape(cleanTitle))
	buf.WriteString(`</h2>` + "\n")

	lines := strings.Split(strings.ReplaceAll(stripInvalidXMLChars(rawText), "\r\n", "\n"), "\n")
	firstParagraph := true
	for _, rawLine := range lines {
		p := trimParagraphSpace(rawLine)
		if p == "" {
			continue
		}
		if firstParagraph {
			firstParagraph = false
			if p == cleanTitle {
				continue
			}
		}
		buf.WriteString(`<p>`)
		buf.WriteString(xmlEscape(p))
		buf.WriteString(`</p>` + "\n")
	}

	buf.WriteString(`</body>` + "\n")
	buf.WriteString(`</html>` + "\n")
	return buf.Bytes()
}

// UpsertChapters creates or incrementally updates epubPath with incoming
// chapters sorted according to canonicalKeys (when provided) and chapter
// metadata. Unchanged existing chapters are copied raw without recompression.
func UpsertChapters(epubPath string, meta BookMeta, incoming []ChapterInput, canonicalKeys []string) (*UpdateResult, error) {
	if len(incoming) == 0 {
		return nil, fmt.Errorf("epub: no chapters supplied")
	}
	dir := filepath.Dir(epubPath)
	if dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("epub: creating %s: %w", dir, err)
		}
	}

	var oldZip *zip.ReadCloser
	var oldManifest *BookManifest
	if st, err := os.Stat(epubPath); err == nil && st.Size() > 0 {
		zr, zerr := zip.OpenReader(epubPath)
		if zerr != nil {
			return nil, fmt.Errorf("epub: opening existing %s: %w", epubPath, zerr)
		}
		oldZip = zr
		defer func() {
			if oldZip != nil {
				oldZip.Close()
			}
		}()
		oldManifest, err = readManifestFromZip(&zr.Reader)
		if err != nil {
			return nil, err
		}
	} else if err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("epub: stat %s: %w", epubPath, err)
	}

	canonicalIdx := canonicalOrderIndexMap(canonicalKeys)

	byKey := make(map[string]*sortableChapter)
	var oldKeys []string
	var oldZipFiles map[string]*zip.File
	if oldZip != nil {
		oldZipFiles = make(map[string]*zip.File, len(oldZip.File))
		for _, f := range oldZip.File {
			oldZipFiles[f.Name] = f
		}
	}

	seq := 0
	if oldManifest != nil {
		oldKeys = make([]string, 0, len(oldManifest.Chapters))
		for _, ch := range oldManifest.Chapters {
			oldKeys = append(oldKeys, ch.Key)
			if pos, ok := canonicalIdx[ch.Key]; ok {
				ch.TOCOrder = pos
			}
			seq++
			byKey[ch.Key] = &sortableChapter{
				mc:         ch,
				isExisting: true,
				origOrder:  seq,
			}
		}
	}

	for _, in := range incoming {
		if in.Key == "" {
			continue
		}
		tocOrder := in.TOCOrder
		if pos, ok := canonicalIdx[in.Key]; ok {
			tocOrder = pos
		}
		title := trimParagraphSpace(in.Title)
		if title == "" {
			title = in.Key
		}
		xhtml := RenderChapterXHTML(title, in.Text)
		if cur, exists := byKey[in.Key]; exists {
			cur.mc.Title = title
			if in.ChapterNumber != nil {
				cur.mc.ChapterNumber = in.ChapterNumber
			}
			if in.VolumeNumber != nil {
				cur.mc.VolumeNumber = in.VolumeNumber
			}
			if in.DateUploaded != nil {
				cur.mc.DateUploaded = in.DateUploaded
			}
			if tocOrder > 0 {
				cur.mc.TOCOrder = tocOrder
			}
			cur.payload = xhtml
		} else {
			seq++
			byKey[in.Key] = &sortableChapter{
				mc: ManifestChapter{
					Key:           in.Key,
					Title:         title,
					Href:          chapterHref(in.Key),
					ChapterNumber: in.ChapterNumber,
					VolumeNumber:  in.VolumeNumber,
					DateUploaded:  in.DateUploaded,
					TOCOrder:      tocOrder,
				},
				isExisting: false,
				origOrder:  seq,
				payload:    xhtml,
			}
		}
	}

	merged := make([]*sortableChapter, 0, len(byKey))
	for _, sc := range byKey {
		merged = append(merged, sc)
	}

	sortSortableChapters(merged)

	finalMeta := mergeMeta(oldManifest, meta)
	finalChapters := make([]ManifestChapter, len(merged))
	newKeys := make([]string, len(merged))
	newPayloads := make(map[string][]byte, len(incoming))
	for i, sc := range merged {
		finalChapters[i] = sc.mc
		newKeys[i] = sc.mc.Key
		if sc.payload != nil {
			newPayloads["OEBPS/"+sc.mc.Href] = sc.payload
		}
	}
	finalMeta.Chapters = finalChapters

	if err := writeEPUBArchive(epubPath, &finalMeta, newPayloads, oldZipFiles, func() {
		if oldZip != nil {
			oldZip.Close()
			oldZip = nil
		}
	}); err != nil {
		return nil, err
	}

	shifted := spineShifted(oldKeys, newKeys)
	sdrRemapped := false
	if shifted {
		if remapped, err := RemapAdjacentSDR(epubPath, oldKeys, newKeys); err == nil && remapped {
			sdrRemapped = true
		}
	}

	return &UpdateResult{
		Path:          epubPath,
		TotalChapters: len(finalChapters),
		OldKeys:       oldKeys,
		NewKeys:       newKeys,
		SpineShifted:  shifted,
		SDRRemapped:   sdrRemapped,
	}, nil
}

// RemoveChapters repacks epubPath without removeKeys, deleting the EPUB (and
// any adjacent .sdr sidecar) when no chapters remain.
func RemoveChapters(epubPath string, removeKeys []string) (*UpdateResult, error) {
	if _, err := os.Stat(epubPath); os.IsNotExist(err) {
		return &UpdateResult{Path: epubPath, TotalChapters: 0}, nil
	} else if err != nil {
		return nil, fmt.Errorf("epub: stat %s: %w", epubPath, err)
	}

	zr, err := zip.OpenReader(epubPath)
	if err != nil {
		return nil, fmt.Errorf("epub: opening %s: %w", epubPath, err)
	}
	defer func() {
		if zr != nil {
			zr.Close()
		}
	}()

	manifest, err := readManifestFromZip(&zr.Reader)
	if err != nil {
		return nil, err
	}

	removeSet := make(map[string]bool, len(removeKeys))
	for _, k := range removeKeys {
		if k != "" {
			removeSet[k] = true
		}
	}

	oldKeys := make([]string, 0, len(manifest.Chapters))
	kept := make([]ManifestChapter, 0, len(manifest.Chapters))
	for _, ch := range manifest.Chapters {
		oldKeys = append(oldKeys, ch.Key)
		if !removeSet[ch.Key] {
			kept = append(kept, ch)
		}
	}

	if len(kept) == 0 {
		zr.Close()
		zr = nil
		if err := os.Remove(epubPath); err != nil && !os.IsNotExist(err) {
			return nil, fmt.Errorf("epub: removing empty %s: %w", epubPath, err)
		}
		_ = removeAdjacentSDR(epubPath)
		return &UpdateResult{
			Path:          epubPath,
			TotalChapters: 0,
			OldKeys:       oldKeys,
			NewKeys:       nil,
			SpineShifted:  len(oldKeys) > 0,
		}, nil
	}

	if len(kept) == len(manifest.Chapters) {
		return &UpdateResult{
			Path:          epubPath,
			TotalChapters: len(kept),
			OldKeys:       oldKeys,
			NewKeys:       oldKeys,
			SpineShifted:  false,
		}, nil
	}

	oldZipFiles := make(map[string]*zip.File, len(zr.File))
	for _, f := range zr.File {
		oldZipFiles[f.Name] = f
	}

	newKeys := make([]string, len(kept))
	for i, ch := range kept {
		newKeys[i] = ch.Key
	}
	manifest.Chapters = kept

	if err := writeEPUBArchive(epubPath, manifest, nil, oldZipFiles, func() {
		if zr != nil {
			zr.Close()
			zr = nil
		}
	}); err != nil {
		return nil, err
	}

	shifted := spineShifted(oldKeys, newKeys)
	sdrRemapped := false
	if shifted {
		if remapped, err := RemapAdjacentSDR(epubPath, oldKeys, newKeys); err == nil && remapped {
			sdrRemapped = true
		}
	}

	return &UpdateResult{
		Path:          epubPath,
		TotalChapters: len(kept),
		OldKeys:       oldKeys,
		NewKeys:       newKeys,
		SpineShifted:  shifted,
		SDRRemapped:   sdrRemapped,
	}, nil
}

type sortableChapter struct {
	mc         ManifestChapter
	isExisting bool
	origOrder  int
	payload    []byte
}

func canonicalOrderIndexMap(canonicalKeys []string) map[string]int {
	m := make(map[string]int, len(canonicalKeys))
	for i, k := range canonicalKeys {
		if k != "" {
			if _, exists := m[k]; !exists {
				m[k] = i + 1
			}
		}
	}
	return m
}

func sortSortableChapters(items []*sortableChapter) {
	sort.SliceStable(items, func(i, j int) bool {
		a, b := items[i], items[j]
		if a.mc.TOCOrder > 0 && b.mc.TOCOrder > 0 && a.mc.TOCOrder != b.mc.TOCOrder {
			return a.mc.TOCOrder < b.mc.TOCOrder
		}
		if a.mc.VolumeNumber != nil && b.mc.VolumeNumber != nil && *a.mc.VolumeNumber != *b.mc.VolumeNumber {
			return *a.mc.VolumeNumber < *b.mc.VolumeNumber
		}
		if a.mc.ChapterNumber != nil && b.mc.ChapterNumber != nil && *a.mc.ChapterNumber != *b.mc.ChapterNumber {
			return *a.mc.ChapterNumber < *b.mc.ChapterNumber
		}
		if a.isExisting != b.isExisting {
			return a.isExisting
		}
		return a.origOrder < b.origOrder
	})
}

func spineShifted(oldKeys, newKeys []string) bool {
	if len(oldKeys) == 0 {
		return false
	}
	if len(newKeys) < len(oldKeys) {
		return true
	}
	for i, k := range oldKeys {
		if newKeys[i] != k {
			return true
		}
	}
	return false
}

func mergeMeta(old *BookManifest, incoming BookMeta) BookManifest {
	m := BookManifest{Version: manifestVersion}
	if old != nil {
		m = *old
		m.Version = manifestVersion
	}
	if incoming.SourceKey != "" {
		m.SourceKey = incoming.SourceKey
	}
	if incoming.MangaKey != "" {
		m.MangaKey = incoming.MangaKey
	}
	if incoming.Title != "" {
		m.Title = incoming.Title
	}
	if len(incoming.Authors) > 0 {
		m.Authors = append([]string(nil), incoming.Authors...)
	}
	if incoming.Description != "" {
		m.Description = incoming.Description
	}
	if incoming.Language != "" {
		m.Language = incoming.Language
	}
	if incoming.VolumeIndex > 0 {
		m.VolumeIndex = incoming.VolumeIndex
	}
	if incoming.VolumeSize > 0 {
		m.VolumeSize = incoming.VolumeSize
	} else if m.VolumeIndex > 0 && m.VolumeSize <= 0 {
		m.VolumeSize = DefaultChaptersPerVolume
	}
	if incoming.VolumeStart > 0 {
		m.VolumeStart = incoming.VolumeStart
	}
	if incoming.VolumeEnd > 0 {
		m.VolumeEnd = incoming.VolumeEnd
	}
	if m.Language == "" {
		m.Language = "zh"
	}
	if m.Title == "" {
		m.Title = m.MangaKey
	}
	return m
}

func writeEPUBArchive(
	epubPath string,
	manifest *BookManifest,
	newPayloads map[string][]byte,
	oldZipFiles map[string]*zip.File,
	beforeRename func(),
) error {
	dir := filepath.Dir(epubPath)
	tmp, err := os.CreateTemp(dir, tempPattern)
	if err != nil {
		return fmt.Errorf("epub: creating temp file in %s: %w", dir, err)
	}
	tmpPath := tmp.Name()
	cleanupTmp := func() {
		tmp.Close()
		os.Remove(tmpPath)
	}

	bw := bufio.NewWriterSize(tmp, 128*1024)
	zw := zip.NewWriter(bw)
	if err := writeStoreEntry(zw, "mimetype", []byte("application/epub+zip")); err != nil {
		cleanupTmp()
		return err
	}
	if err := writeStoreEntry(zw, containerPath, []byte(containerXML)); err != nil {
		cleanupTmp()
		return err
	}
	if err := writeStoreEntry(zw, cssEntryPath, []byte(defaultCSS)); err != nil {
		cleanupTmp()
		return err
	}

	for _, ch := range manifest.Chapters {
		entryName := "OEBPS/" + ch.Href
		if data, ok := newPayloads[entryName]; ok {
			if err := writeStoreEntry(zw, entryName, data); err != nil {
				cleanupTmp()
				return err
			}
			continue
		}
		oldFile := oldZipFiles[entryName]
		if oldFile == nil {
			cleanupTmp()
			return fmt.Errorf("epub: missing chapter entry %s during repack", entryName)
		}
		if err := copyRawZipEntry(zw, oldFile); err != nil {
			cleanupTmp()
			return err
		}
	}

	manifestJSON, err := json.Marshal(manifest)
	if err != nil {
		cleanupTmp()
		return fmt.Errorf("epub: encoding %s: %w", manifestEntryPath, err)
	}
	if err := writeStoreEntry(zw, manifestEntryPath, manifestJSON); err != nil {
		cleanupTmp()
		return err
	}
	if err := writeStoreEntry(zw, opfEntryPath, buildContentOPF(manifest)); err != nil {
		cleanupTmp()
		return err
	}
	if err := writeStoreEntry(zw, ncxEntryPath, buildTOCNCX(manifest)); err != nil {
		cleanupTmp()
		return err
	}

	if err := zw.Close(); err != nil {
		cleanupTmp()
		return fmt.Errorf("epub: finalizing archive %s: %w", tmpPath, err)
	}
	if err := bw.Flush(); err != nil {
		cleanupTmp()
		return fmt.Errorf("epub: flushing archive %s: %w", tmpPath, err)
	}
	if err := tmp.Sync(); err != nil {
		cleanupTmp()
		return fmt.Errorf("epub: syncing %s: %w", tmpPath, err)
	}
	_ = tmp.Chmod(0o644)
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("epub: closing %s: %w", tmpPath, err)
	}
	if beforeRename != nil {
		beforeRename()
	}
	if err := os.Rename(tmpPath, epubPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("epub: renaming %s to %s: %w", tmpPath, epubPath, err)
	}
	_ = fsutil.SyncDir(dir)
	return nil
}

func writeStoreEntry(zw *zip.Writer, name string, data []byte) error {
	w, err := zw.CreateHeader(&zip.FileHeader{
		Name:   name,
		Method: zip.Store,
	})
	if err != nil {
		return fmt.Errorf("epub: creating %s: %w", name, err)
	}
	if _, err := w.Write(data); err != nil {
		return fmt.Errorf("epub: writing %s: %w", name, err)
	}
	return nil
}

func copyRawZipEntry(zw *zip.Writer, src *zip.File) error {
	rc, err := src.OpenRaw()
	if err != nil {
		return fmt.Errorf("epub: opening raw %s: %w", src.Name, err)
	}
	hdr := src.FileHeader
	w, err := zw.CreateRaw(&hdr)
	if err != nil {
		return fmt.Errorf("epub: creating raw %s: %w", src.Name, err)
	}
	if _, err := io.Copy(w, rc); err != nil {
		return fmt.Errorf("epub: copying raw %s: %w", src.Name, err)
	}
	return nil
}

func bookIdentifier(m *BookManifest) string {
	sum := sha256.Sum256([]byte(m.SourceKey + "\x00" + m.MangaKey))
	base := "urn:tsundoku:" + hex.EncodeToString(sum[:16])
	if m.VolumeIndex > 0 {
		return fmt.Sprintf("%s:v%d", base, m.VolumeIndex)
	}
	return base
}

func displayVolumeTitle(m *BookManifest) string {
	if m.VolumeIndex > 0 && m.VolumeStart > 0 && m.VolumeEnd >= m.VolumeStart {
		return fmt.Sprintf("%s (%d-%d)", m.Title, m.VolumeStart, m.VolumeEnd)
	}
	return m.Title
}

func buildContentOPF(m *BookManifest) []byte {
	var buf bytes.Buffer
	buf.Grow(512 + len(m.Chapters)*180)
	lang := m.Language
	if lang == "" {
		lang = "zh"
	}
	buf.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	buf.WriteString(`<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">` + "\n")
	buf.WriteString(`  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">` + "\n")
	buf.WriteString(`    <dc:identifier id="BookId">` + xmlEscape(bookIdentifier(m)) + `</dc:identifier>` + "\n")
	buf.WriteString(`    <dc:title>` + xmlEscape(displayVolumeTitle(m)) + `</dc:title>` + "\n")
	buf.WriteString(`    <dc:language>` + xmlEscape(lang) + `</dc:language>` + "\n")
	for _, a := range m.Authors {
		if a = trimParagraphSpace(a); a != "" {
			buf.WriteString(`    <dc:creator opf:role="aut">` + xmlEscape(a) + `</dc:creator>` + "\n")
		}
	}
	if desc := trimParagraphSpace(m.Description); desc != "" {
		buf.WriteString(`    <dc:description>` + xmlEscape(desc) + `</dc:description>` + "\n")
	}
	buf.WriteString(`  </metadata>` + "\n")
	buf.WriteString(`  <manifest>` + "\n")
	buf.WriteString(`    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>` + "\n")
	buf.WriteString(`    <item id="style" href="style.css" media-type="text/css"/>` + "\n")
	for _, ch := range m.Chapters {
		id := xmlEscape(chapterID(ch.Href))
		href := xmlEscape(ch.Href)
		buf.WriteString(`    <item id="` + id + `" href="` + href + `" media-type="application/xhtml+xml"/>` + "\n")
	}
	buf.WriteString(`  </manifest>` + "\n")
	buf.WriteString(`  <spine toc="ncx">` + "\n")
	for _, ch := range m.Chapters {
		buf.WriteString(`    <itemref idref="` + xmlEscape(chapterID(ch.Href)) + `"/>` + "\n")
	}
	buf.WriteString(`  </spine>` + "\n")
	buf.WriteString(`</package>` + "\n")
	return buf.Bytes()
}

func buildTOCNCX(m *BookManifest) []byte {
	var buf bytes.Buffer
	buf.Grow(512 + len(m.Chapters)*200)
	buf.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	buf.WriteString(`<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">` + "\n")
	buf.WriteString(`<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">` + "\n")
	buf.WriteString(`  <head>` + "\n")
	buf.WriteString(`    <meta name="dtb:uid" content="` + xmlEscape(bookIdentifier(m)) + `"/>` + "\n")
	buf.WriteString(`    <meta name="dtb:depth" content="1"/>` + "\n")
	buf.WriteString(`    <meta name="dtb:totalPageCount" content="0"/>` + "\n")
	buf.WriteString(`    <meta name="dtb:maxPageNumber" content="0"/>` + "\n")
	buf.WriteString(`  </head>` + "\n")
	buf.WriteString(`  <docTitle><text>` + xmlEscape(displayVolumeTitle(m)) + `</text></docTitle>` + "\n")
	buf.WriteString(`  <navMap>` + "\n")
	for i, ch := range m.Chapters {
		order := i + 1
		buf.WriteString(fmt.Sprintf(`    <navPoint id="navPoint-%d" playOrder="%d">`+"\n", order, order))
		buf.WriteString(`      <navLabel><text>` + xmlEscape(ch.Title) + `</text></navLabel>` + "\n")
		buf.WriteString(`      <content src="` + xmlEscape(ch.Href) + `"/>` + "\n")
		buf.WriteString(`    </navPoint>` + "\n")
	}
	buf.WriteString(`  </navMap>` + "\n")
	buf.WriteString(`</ncx>` + "\n")
	return buf.Bytes()
}

// RemoveStaleTemps deletes leftover .epub-*.tmp files older than olderThan in dir.
func RemoveStaleTemps(dir string, olderThan time.Duration) {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, ".epub-") || !strings.HasSuffix(name, ".tmp") {
			continue
		}
		if fi, err := e.Info(); err == nil && time.Since(fi.ModTime()) > olderThan {
			os.Remove(filepath.Join(dir, name))
		}
	}
}

const containerXML = `<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
`

const defaultCSS = `body { margin: 0; padding: 0; line-height: 1.65; }
h2 { font-size: 1.25em; margin: 1em 0 0.8em 0; text-indent: 0; }
p { text-indent: 2em; margin: 0.45em 0; }
`
