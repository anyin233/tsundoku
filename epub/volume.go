package epub

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

// BookIndexChapter records one chapter's location inside a sharded book volume.
type BookIndexChapter struct {
	Key       string `json:"key"`
	Title     string `json:"title"`
	TOCOrder  int    `json:"tocOrder,omitempty"`
	FragIndex int    `json:"fragIndex"`
}

// BookIndexVolume summarizes one EPUB file belonging to a book directory.
type BookIndexVolume struct {
	VolumeIndex int                `json:"volumeIndex"`
	VolumeStart int                `json:"volumeStart"`
	VolumeEnd   int                `json:"volumeEnd"`
	File        string             `json:"file"`
	Chapters    []BookIndexChapter `json:"chapters"`
}

// BookIndex is persisted at <bookDir>/.tsundoku_book.json so KOReader's
// ReaderToc hook can assemble the entire multi-volume TOC in O(1) file read.
type BookIndex struct {
	Version    int               `json:"version"`
	SourceKey  string            `json:"sourceKey"`
	MangaKey   string            `json:"mangaKey"`
	Title      string            `json:"title"`
	VolumeSize int               `json:"volumeSize"`
	Volumes    []BookIndexVolume `json:"volumes"`
}

// SplitVolumeResult reports one volume created or updated by SplitToVolumes.
type SplitVolumeResult struct {
	VolumeIndex int      `json:"volumeIndex"`
	VolumeStart int      `json:"volumeStart"`
	VolumeEnd   int      `json:"volumeEnd"`
	Path        string   `json:"path"`
	ChapterKeys []string `json:"chapterKeys"`
}

// SplitResult summarizes migrating a legacy single-file EPUB into sharded volumes.
type SplitResult struct {
	LegacyPath     string              `json:"legacyPath"`
	AlreadySharded bool                `json:"alreadySharded"`
	ActivePath     string              `json:"activePath,omitempty"`
	ActiveChapter  string              `json:"activeChapter,omitempty"`
	Volumes        []SplitVolumeResult `json:"volumes,omitempty"`
	TotalChapters  int                 `json:"totalChapters"`
}

// VolumeForOrder maps a 1-based canonical chapter order to its 1-based volume
// index and inclusive 1-based slot range [start, end].
func VolumeForOrder(tocOrder, volumeSize int) (volIdx, start, end int) {
	if volumeSize <= 0 {
		volumeSize = DefaultChaptersPerVolume
	}
	if tocOrder < 1 {
		tocOrder = 1
	}
	volIdx = (tocOrder-1)/volumeSize + 1
	start = (volIdx-1)*volumeSize + 1
	end = volIdx * volumeSize
	return volIdx, start, end
}

// VolumeRangeSuffix returns the filename suffix for a volume slot range.
func VolumeRangeSuffix(start, end int) string {
	return fmt.Sprintf(" [%04d-%04d]", start, end)
}

func volumeFilename(baseStem, suffix string) string {
	const ext = ".epub"
	const maxBytes = 240
	if baseStem == "" {
		baseStem = "book"
	}
	maxStemBytes := maxBytes - len(suffix) - len(ext)
	if len(baseStem) > maxStemBytes && maxStemBytes > 0 {
		cut := maxStemBytes
		for cut > 0 && !utf8.RuneStart(baseStem[cut]) {
			cut--
		}
		baseStem = strings.TrimSpace(baseStem[:cut])
		if baseStem == "" {
			baseStem = "book"
		}
	}
	return baseStem + suffix + ext
}

// SyncBookIndex scans bookDir for Tsundoku EPUB archives and writes
// <bookDir>/.tsundoku_book.json atomically, or removes it when none remain.
func SyncBookIndex(bookDir string) (*BookIndex, error) {
	if bookDir == "" {
		return nil, nil
	}
	entries, err := os.ReadDir(bookDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("epub: reading book dir %s: %w", bookDir, err)
	}

	idx := &BookIndex{
		Version:    1,
		VolumeSize: DefaultChaptersPerVolume,
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if strings.HasPrefix(name, ".") || !strings.EqualFold(filepath.Ext(name), ".epub") {
			continue
		}
		m, err := ReadManifest(filepath.Join(bookDir, name))
		if err != nil || m == nil || len(m.Chapters) == 0 {
			continue
		}
		if idx.SourceKey == "" {
			idx.SourceKey = m.SourceKey
		}
		if idx.MangaKey == "" {
			idx.MangaKey = m.MangaKey
		}
		if idx.Title == "" {
			idx.Title = m.Title
		}
		if m.VolumeSize > 0 && idx.VolumeSize == DefaultChaptersPerVolume {
			idx.VolumeSize = m.VolumeSize
		}

		volSize := m.VolumeSize
		if volSize <= 0 {
			volSize = DefaultChaptersPerVolume
		}
		volStart, volEnd := m.VolumeStart, m.VolumeEnd
		if m.VolumeIndex > 0 && (volStart <= 0 || volEnd < volStart) {
			_, volStart, volEnd = VolumeForOrder((m.VolumeIndex-1)*volSize+1, volSize)
		}

		chapters := make([]BookIndexChapter, 0, len(m.Chapters))
		for i, ch := range m.Chapters {
			chapters = append(chapters, BookIndexChapter{
				Key:       ch.Key,
				Title:     ch.Title,
				TOCOrder:  ch.TOCOrder,
				FragIndex: i + 1,
			})
		}
		idx.Volumes = append(idx.Volumes, BookIndexVolume{
			VolumeIndex: m.VolumeIndex,
			VolumeStart: volStart,
			VolumeEnd:   volEnd,
			File:        name,
			Chapters:    chapters,
		})
	}

	indexPath := filepath.Join(bookDir, BookIndexFilename)
	if len(idx.Volumes) == 0 {
		if err := os.Remove(indexPath); err != nil && !os.IsNotExist(err) {
			return nil, fmt.Errorf("epub: removing empty book index %s: %w", indexPath, err)
		}
		return nil, nil
	}

	sort.Slice(idx.Volumes, func(i, j int) bool {
		a, b := idx.Volumes[i], idx.Volumes[j]
		if (a.VolumeIndex == 0) != (b.VolumeIndex == 0) {
			return a.VolumeIndex != 0
		}
		if len(a.Chapters) > 0 && len(b.Chapters) > 0 {
			ao, bo := a.Chapters[0].TOCOrder, b.Chapters[0].TOCOrder
			if ao > 0 && bo > 0 && ao != bo {
				return ao < bo
			}
		}
		if a.VolumeIndex != b.VolumeIndex {
			return a.VolumeIndex < b.VolumeIndex
		}
		return a.File < b.File
	})

	data, err := json.Marshal(idx)
	if err != nil {
		return nil, fmt.Errorf("epub: encoding book index: %w", err)
	}
	if err := writeAtomicFile(indexPath, ".tsundoku-*.tmp", data); err != nil {
		return nil, fmt.Errorf("epub: writing book index %s: %w", indexPath, err)
	}
	return idx, nil
}

// SplitToVolumes losslessly splits a legacy monolithic EPUB (VolumeIndex == 0)
// into fixed-size volume EPUBs (copying XHTML entries raw without re-encoding),
// migrates any adjacent .sdr reading position/typography settings to the active
// volume, deletes the legacy EPUB + .sdr, and writes .tsundoku_book.json.
func SplitToVolumes(legacyEPUBPath string, volumeSize int, canonicalKeys []string) (*SplitResult, error) {
	if volumeSize <= 0 {
		volumeSize = DefaultChaptersPerVolume
	}
	zr, err := zip.OpenReader(legacyEPUBPath)
	if err != nil {
		return nil, fmt.Errorf("epub: opening %s: %w", legacyEPUBPath, err)
	}
	closed := false
	closeLegacy := func() {
		if !closed {
			closed = true
			_ = zr.Close()
		}
	}
	defer closeLegacy()

	manifest, err := readManifestFromZip(&zr.Reader)
	if err != nil {
		return nil, err
	}
	if manifest.VolumeIndex > 0 {
		return &SplitResult{
			LegacyPath:     legacyEPUBPath,
			AlreadySharded: true,
			TotalChapters:  len(manifest.Chapters),
		}, nil
	}
	if len(manifest.Chapters) == 0 {
		return &SplitResult{
			LegacyPath:    legacyEPUBPath,
			TotalChapters: 0,
		}, nil
	}

	legacyZipFiles := make(map[string]*zip.File, len(zr.File))
	for _, f := range zr.File {
		legacyZipFiles[f.Name] = f
	}

	legacyKeys := make([]string, len(manifest.Chapters))
	for i, ch := range manifest.Chapters {
		legacyKeys[i] = ch.Key
	}

	legacySDRPath := filepath.Join(sidecarDir(legacyEPUBPath), "metadata.epub.lua")
	legacySDRData, sdrErr := os.ReadFile(legacySDRPath)
	if sdrErr != nil {
		legacySDRData = nil
	}
	var activeChapterKey string
	if len(legacySDRData) > 0 {
		_, lastFragIdx := extractLastXPointer(legacySDRData)
		if lastFragIdx >= 1 && lastFragIdx <= len(manifest.Chapters) {
			activeChapterKey = manifest.Chapters[lastFragIdx-1].Key
		}
	}

	canonicalIdx := canonicalOrderIndexMap(canonicalKeys)

	type volumeBucket struct {
		volIdx   int
		volStart int
		volEnd   int
		chapters []ManifestChapter
	}
	bucketsByVol := make(map[int]*volumeBucket)
	for i, ch := range manifest.Chapters {
		pos := ch.TOCOrder
		if cpos, ok := canonicalIdx[ch.Key]; ok && cpos > 0 {
			pos = cpos
		}
		if pos <= 0 {
			pos = i + 1
		}
		ch.TOCOrder = pos
		volIdx, volStart, volEnd := VolumeForOrder(pos, volumeSize)
		b := bucketsByVol[volIdx]
		if b == nil {
			b = &volumeBucket{
				volIdx:   volIdx,
				volStart: volStart,
				volEnd:   volEnd,
			}
			bucketsByVol[volIdx] = b
		}
		b.chapters = append(b.chapters, ch)
	}

	volIDs := make([]int, 0, len(bucketsByVol))
	for volIdx := range bucketsByVol {
		volIDs = append(volIDs, volIdx)
	}
	sort.Ints(volIDs)

	bookDir := filepath.Dir(legacyEPUBPath)
	baseStem := strings.TrimSuffix(filepath.Base(legacyEPUBPath), filepath.Ext(legacyEPUBPath))
	cleanLegacy := filepath.Clean(legacyEPUBPath)

	res := &SplitResult{
		LegacyPath:    legacyEPUBPath,
		ActiveChapter: activeChapterKey,
		TotalChapters: len(manifest.Chapters),
		Volumes:       make([]SplitVolumeResult, 0, len(volIDs)),
	}
	writtenPaths := make(map[string]bool, len(volIDs))

	for bi, volIdx := range volIDs {
		b := bucketsByVol[volIdx]
		volFile := volumeFilename(baseStem, VolumeRangeSuffix(b.volStart, b.volEnd))
		volPath := filepath.Join(bookDir, volFile)
		cleanVol := filepath.Clean(volPath)

		byKey := make(map[string]*sortableChapter, len(b.chapters))
		mergedZipFiles := make(map[string]*zip.File, len(b.chapters))
		seq := 0

		var existingZip *zip.ReadCloser
		var existingManifest *BookManifest
		if cleanVol != cleanLegacy {
			if st, serr := os.Stat(volPath); serr == nil && st.Size() > 0 {
				ez, eerr := zip.OpenReader(volPath)
				if eerr != nil {
					return nil, fmt.Errorf("epub: opening existing volume %s: %w", volPath, eerr)
				}
				existingZip = ez
				existingManifest, eerr = readManifestFromZip(&ez.Reader)
				if eerr != nil {
					_ = existingZip.Close()
					return nil, eerr
				}
				ezFiles := make(map[string]*zip.File, len(ez.File))
				for _, f := range ez.File {
					ezFiles[f.Name] = f
				}
				for _, ch := range existingManifest.Chapters {
					if pos, ok := canonicalIdx[ch.Key]; ok {
						ch.TOCOrder = pos
					}
					seq++
					byKey[ch.Key] = &sortableChapter{
						mc:         ch,
						isExisting: true,
						origOrder:  seq,
					}
					if zf := ezFiles["OEBPS/"+ch.Href]; zf != nil {
						mergedZipFiles["OEBPS/"+ch.Href] = zf
					}
				}
			}
		}

		for _, ch := range b.chapters {
			entryName := "OEBPS/" + ch.Href
			zf := legacyZipFiles[entryName]
			if zf == nil {
				if existingZip != nil {
					_ = existingZip.Close()
				}
				return nil, fmt.Errorf("epub: missing entry %s in %s", entryName, legacyEPUBPath)
			}
			seq++
			byKey[ch.Key] = &sortableChapter{
				mc:         ch,
				isExisting: true,
				origOrder:  seq,
			}
			mergedZipFiles[entryName] = zf
		}

		merged := make([]*sortableChapter, 0, len(byKey))
		for _, sc := range byKey {
			merged = append(merged, sc)
		}
		sortSortableChapters(merged)

		volChapters := make([]ManifestChapter, len(merged))
		volKeys := make([]string, len(merged))
		containsActive := false
		for i, sc := range merged {
			volChapters[i] = sc.mc
			volKeys[i] = sc.mc.Key
			if activeChapterKey != "" && sc.mc.Key == activeChapterKey {
				containsActive = true
			}
		}

		volMeta := mergeMeta(existingManifest, BookMeta{
			SourceKey:   manifest.SourceKey,
			MangaKey:    manifest.MangaKey,
			Title:       manifest.Title,
			Authors:     manifest.Authors,
			Description: manifest.Description,
			Language:    manifest.Language,
			VolumeIndex: b.volIdx,
			VolumeSize:  volumeSize,
			VolumeStart: b.volStart,
			VolumeEnd:   b.volEnd,
		})
		volMeta.Chapters = volChapters

		if err := writeEPUBArchive(volPath, &volMeta, nil, mergedZipFiles, func() {
			if existingZip != nil {
				_ = existingZip.Close()
				existingZip = nil
			}
		}); err != nil {
			if existingZip != nil {
				_ = existingZip.Close()
			}
			return nil, err
		}
		writtenPaths[cleanVol] = true

		if containsActive || (len(legacySDRData) > 0 && activeChapterKey == "" && bi == 0) {
			if err := migrateVolumeSDR(legacySDRData, volPath, legacyKeys, volKeys); err != nil {
				return nil, fmt.Errorf("epub: migrating sidecar to %s: %w", volPath, err)
			}
			res.ActivePath = volPath
		}

		res.Volumes = append(res.Volumes, SplitVolumeResult{
			VolumeIndex: b.volIdx,
			VolumeStart: b.volStart,
			VolumeEnd:   b.volEnd,
			Path:        volPath,
			ChapterKeys: volKeys,
		})
	}

	if res.ActivePath == "" && len(res.Volumes) > 0 {
		res.ActivePath = res.Volumes[0].Path
	}

	closeLegacy()
	if !writtenPaths[cleanLegacy] {
		if err := os.Remove(legacyEPUBPath); err != nil && !os.IsNotExist(err) {
			return nil, fmt.Errorf("epub: removing legacy %s: %w", legacyEPUBPath, err)
		}
		_ = removeAdjacentSDR(legacyEPUBPath)
	}

	if _, err := SyncBookIndex(bookDir); err != nil {
		return nil, err
	}
	return res, nil
}
