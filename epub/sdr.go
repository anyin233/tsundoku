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
	xpRegex     = regexp.MustCompile(`^/body/DocFragment(?:\[(\d+)\])?(/.*)?$`)
	xpFindRegex = regexp.MustCompile(`/body/DocFragment(?:\[\d+\])?(?:/[^"'\r\n]*)?`)
)

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

	dir := filepath.Dir(metaPath)
	tmp, err := os.CreateTemp(dir, ".metadata-*.tmp")
	if err != nil {
		return false, err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(updated); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return false, err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return false, err
	}
	_ = tmp.Chmod(0o644)
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return false, err
	}
	if err := os.Rename(tmpPath, metaPath); err != nil {
		os.Remove(tmpPath)
		return false, err
	}
	_ = fsutil.SyncDir(dir)
	return true, nil
}
