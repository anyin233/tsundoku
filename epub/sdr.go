package epub

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/ohaiibuzzle/aidokurunner-go/internal/fsutil"
)

func sidecarDir(epubPath string) string {
	ext := filepath.Ext(epubPath)
	base := strings.TrimSuffix(epubPath, ext)
	if base == "" {
		base = epubPath
	}
	return base + ".sdr"
}

func removeAdjacentSDR(epubPath string) error {
	return os.RemoveAll(sidecarDir(epubPath))
}

var (
	xpRegex       = regexp.MustCompile(`^/body/DocFragment(?:\[(\d+)\])?(/.*)?$`)
	xpFindRegex   = regexp.MustCompile(`/body/DocFragment(?:\[\d+\])?(?:/[^"'\r\n]*)?`)
	lastXPRegex   = regexp.MustCompile(`\["last_xpointer"\]\s*=\s*"([^"\r\n]*)"`)
	staleSDRLine  = regexp.MustCompile(`(?m)^[ \t]*\["(?:doc_pages|doc_path|partial_md5_checksum|percent_finished|readingloc_anchor)"\]\s*=[^\r\n]*\r?\n?`)
)

func writeAtomicFile(path, pattern string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	_ = tmp.Chmod(0o644)
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return err
	}
	_ = fsutil.SyncDir(dir)
	return nil
}

func writeFileAtomic(path string, data []byte) error {
	return writeAtomicFile(path, ".metadata-*.tmp", data)
}

// extractLastXPointer reads last_xpointer and its 1-based DocFragment index
// from a KOReader metadata.epub.lua payload, returning ("", 0) when absent.
func extractLastXPointer(data []byte) (string, int) {
	m := lastXPRegex.FindSubmatch(data)
	if len(m) < 2 {
		return "", 0
	}
	xp := string(m[1])
	parts := xpRegex.FindStringSubmatch(xp)
	if parts == nil {
		return xp, 0
	}
	if parts[1] == "" {
		return xp, 1
	}
	idx, err := strconv.Atoi(parts[1])
	if err != nil || idx < 1 {
		return xp, 0
	}
	return xp, idx
}

func remapXPointerInSubset(xp string, oldKeys []string, targetIndex map[string]int) string {
	m := xpRegex.FindStringSubmatch(xp)
	if m == nil || len(oldKeys) == 0 {
		return xp
	}
	oldIdx := 1
	if m[1] != "" {
		parsed, err := strconv.Atoi(m[1])
		if err != nil {
			return xp
		}
		oldIdx = parsed
	}
	if oldIdx < 1 || oldIdx > len(oldKeys) {
		return xp
	}
	if newIdx, ok := targetIndex[oldKeys[oldIdx-1]]; ok {
		return fmt.Sprintf("/body/DocFragment[%d]%s", newIdx, m[2])
	}
	return xp
}

// migrateVolumeSDR copies a legacy book's metadata.epub.lua into volEPUBPath's
// adjacent .sdr directory, remapping XPointers belonging to volKeys and
// stripping stale file-specific layout/hash fields so KOReader recomputes them.
func migrateVolumeSDR(legacyData []byte, volEPUBPath string, legacyKeys, volKeys []string) error {
	if len(legacyData) == 0 || len(volKeys) == 0 {
		return nil
	}
	targetIndex := make(map[string]int, len(volKeys))
	for i, k := range volKeys {
		targetIndex[k] = i + 1
	}
	cleaned := staleSDRLine.ReplaceAll(legacyData, nil)
	updated := xpFindRegex.ReplaceAllFunc(cleaned, func(match []byte) []byte {
		return []byte(remapXPointerInSubset(string(match), legacyKeys, targetIndex))
	})
	metaPath := filepath.Join(sidecarDir(volEPUBPath), "metadata.epub.lua")
	return writeFileAtomic(metaPath, updated)
}

// RemapXPointerString adjusts a KOReader crengine XPointer from oldKeys'
// 1-based DocFragment indices to newKeys' indices so reading positions,
// bookmarks, and highlights survive pre-insertions or mid-book deletions.
func RemapXPointerString(xp string, oldKeys, newKeys []string) string {
	if len(oldKeys) == 0 || len(newKeys) == 0 {
		return xp
	}
	m := xpRegex.FindStringSubmatch(xp)
	if m == nil {
		return xp
	}
	oldIdx := 1
	if m[1] != "" {
		parsed, err := strconv.Atoi(m[1])
		if err != nil {
			return xp
		}
		oldIdx = parsed
	}
	if oldIdx < 1 || oldIdx > len(oldKeys) {
		return xp
	}

	newIndex := make(map[string]int, len(newKeys))
	for i, k := range newKeys {
		newIndex[k] = i + 1
	}

	key := oldKeys[oldIdx-1]
	if targetIdx, ok := newIndex[key]; ok {
		return fmt.Sprintf("/body/DocFragment[%d]%s", targetIdx, m[2])
	}

	// The chapter at oldIdx was removed: jump to the nearest surviving
	// subsequent chapter, or fall back to the final surviving chapter.
	for i := oldIdx; i < len(oldKeys); i++ {
		if targetIdx, ok := newIndex[oldKeys[i]]; ok {
			return fmt.Sprintf("/body/DocFragment[%d]/body", targetIdx)
		}
	}
	return fmt.Sprintf("/body/DocFragment[%d]/body", len(newKeys))
}

// RemapAdjacentSDR updates DocFragment indices inside an adjacent KOReader
// <stem>.sdr/metadata.epub.lua file when spine indices shifted. Returns true
// if a sidecar file existed and was updated.
func RemapAdjacentSDR(epubPath string, oldKeys, newKeys []string) (bool, error) {
	if len(oldKeys) == 0 || len(newKeys) == 0 {
		return false, nil
	}
	metaPath := filepath.Join(sidecarDir(epubPath), "metadata.epub.lua")
	data, err := os.ReadFile(metaPath)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}

	updated := xpFindRegex.ReplaceAllFunc(data, func(match []byte) []byte {
		return []byte(RemapXPointerString(string(match), oldKeys, newKeys))
	})
	if bytes.Equal(data, updated) {
		return false, nil
	}

	if err := writeFileAtomic(metaPath, updated); err != nil {
		return false, err
	}
	return true, nil
}
