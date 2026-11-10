package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ohaiibuzzle/aidokurunner-go/models"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime/host"
	"github.com/ohaiibuzzle/aidokurunner-go/settingsstore"
	"github.com/ohaiibuzzle/aidokurunner-go/source"
	"github.com/tetratelabs/wazero"
)

const perCoverTimeout = 45 * time.Second

type coversPayload struct {
	SourcesDir string             `json:"sourcesDir,omitempty"`
	MaxWidth   int                `json:"maxWidth,omitempty"`
	MaxHeight  int                `json:"maxHeight,omitempty"`
	Items      []coverRequestItem `json:"items"`
}

type coverRequestItem struct {
	ID         string `json:"id"`
	SourceKey  string `json:"sourceKey,omitempty"`
	SourcePath string `json:"sourcePath,omitempty"`
	MangaKey   string `json:"mangaKey,omitempty"`
	CoverURL   string `json:"coverUrl,omitempty"`
	DestPath   string `json:"destPath"`
}

type coverResultItem struct {
	ID            string `json:"id"`
	OK            bool   `json:"ok"`
	Path          string `json:"path,omitempty"`
	ResolvedCover string `json:"resolvedCover,omitempty"`
	Error         string `json:"error,omitempty"`
}

func cookiesForURL(cookiePath, rawURL string) []*http.Cookie {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Hostname() == "" {
		return nil
	}
	reqHost := strings.ToLower(parsed.Hostname())
	f, _ := readCookieFile(cookiePath)
	if len(f) == 0 {
		return nil
	}
	var out []*http.Cookie
	for domain, entries := range f {
		d := strings.ToLower(domain)
		if d == "" {
			continue
		}
		for _, e := range entries {
			if reqHost == d || (e.IncludeSubdomains && strings.HasSuffix(reqHost, "."+d)) {
				out = append(out, e.cookie())
			}
		}
	}
	return out
}

func buildSourcesMap(sourcesDir string) map[string]string {
	out := make(map[string]string)
	if sourcesDir == "" {
		return out
	}
	entries, err := os.ReadDir(sourcesDir)
	if err != nil {
		return out
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".aix") {
			continue
		}
		fullPath := filepath.Join(sourcesDir, e.Name())
		if info, merr := source.ReadManifest(fullPath); merr == nil && info.Key != "" {
			out[info.Key] = fullPath
		}
	}
	return out
}

func resolveItemSourcePath(it coverRequestItem, byKey map[string]string) string {
	if it.SourcePath != "" {
		if _, err := os.Stat(it.SourcePath); err == nil {
			return it.SourcePath
		}
	}
	if it.SourceKey != "" && byKey != nil {
		if p, ok := byKey[it.SourceKey]; ok {
			return p
		}
	}
	return ""
}

// handleCovers processes a batch of cover thumbnail requests in a single
// invocation while keeping at most one WASM source loaded in memory at a time.
// Emits "[cover] <1-based-index>" to stderr as each cover finishes so callers
// can incrementally repaint individual cells without waiting for the batch.
func handleCovers(ctx context.Context, settings *settingsstore.Store, cookiePath string, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: aidoku-run - covers <payload.json>")
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return fmt.Errorf("reading covers payload: %w", err)
	}
	var payload coversPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return fmt.Errorf("parsing covers payload: %w", err)
	}

	results := make([]coverResultItem, len(payload.Items))
	if len(payload.Items) == 0 {
		return printJSON(map[string]any{"results": results})
	}

	var byKey map[string]string
	for i, it := range payload.Items {
		results[i].ID = it.ID
		if it.DestPath != "" {
			if st, serr := os.Stat(it.DestPath); serr == nil && !st.IsDir() && st.Size() > 0 {
				results[i].OK = true
				results[i].Path = it.DestPath
				fmt.Fprintf(os.Stderr, "[cover] %d\n", i+1)
				continue
			}
		}
		if it.SourcePath == "" || func() bool { _, e := os.Stat(it.SourcePath); return e != nil }() {
			if byKey == nil && payload.SourcesDir != "" {
				byKey = buildSourcesMap(payload.SourcesDir)
			}
		}
	}

	// Group pending item indices by resolved source path, preserving first-seen
	// group order so visible items at the top of the page finish first while
	// still loading each .aix WASM module at most once.
	type sourceGroup struct {
		sourcePath string
		indices    []int
	}
	var groups []sourceGroup
	groupIdx := make(map[string]int)

	for i, it := range payload.Items {
		if results[i].OK {
			continue
		}
		if it.DestPath == "" {
			results[i].Error = "empty destPath"
			continue
		}
		spath := resolveItemSourcePath(it, byKey)
		pos, exists := groupIdx[spath]
		if !exists {
			pos = len(groups)
			groupIdx[spath] = pos
			groups = append(groups, sourceGroup{sourcePath: spath})
		}
		groups[pos].indices = append(groups[pos].indices, i)
	}

	cacheDir := filepath.Join(os.TempDir(), "aidoku-run-wazero-cache")
	if dir := os.Getenv("AIDOKU_SETTINGS_DIR"); dir != "" {
		cacheDir = filepath.Join(dir, "wazero-cache")
	}
	var compilationCache wazero.CompilationCache
	if len(groups) > 0 && (len(groups) > 1 || groups[0].sourcePath != "") {
		cc, cerr := wazero.NewCompilationCacheWithDir(cacheDir)
		if cerr == nil {
			compilationCache = cc
			defer compilationCache.Close(ctx)
		}
	}

	loadOneSource := func(spath string) *source.Source {
		if spath == "" {
			return nil
		}
		interpConfig := runtime.Config{
			PrintHandler:     func(s string) { fmt.Fprintln(os.Stderr, "[print]", s) },
			Settings:         settings,
			CompilationCache: compilationCache,
			OnFlareSolverrCookies: func(u *url.URL, cookies []*http.Cookie) {
				_ = persistCookies(cookiePath, cookies)
			},
			OnCookiesDeleted: func(h, domain string, names []string) {
				_ = forgetCookies(cookiePath, h, domain, names)
			},
			NetworkConcurrency: host.NetworkConcurrencyFromEnv(),
		}
		src, lerr := source.LoadPath(ctx, spath, interpConfig, settings)
		if errors.Is(lerr, runtime.ErrCompile) && compilationCache != nil {
			_ = os.RemoveAll(cacheDir)
			interpConfig.CompilationCache = nil
			src, lerr = source.LoadPath(ctx, spath, interpConfig, settings)
		}
		if lerr != nil {
			return nil
		}
		injectCookies(src, cookiePath)
		return src
	}

	for _, grp := range groups {
		if ctx.Err() != nil {
			break
		}
		src := loadOneSource(grp.sourcePath)
		for _, idx := range grp.indices {
			if ctx.Err() != nil {
				break
			}
			it := payload.Items[idx]
			itemCtx, cancel := context.WithTimeout(ctx, perCoverTimeout)
			coverURL := strings.TrimSpace(it.CoverURL)

			if coverURL == "" && src != nil && it.MangaKey != "" {
				updated, uerr := src.GetMangaUpdate(itemCtx, models.Manga{Key: it.MangaKey}, true, false, nil)
				if uerr == nil && updated != nil && updated.Cover != nil && strings.TrimSpace(*updated.Cover) != "" {
					coverURL = strings.TrimSpace(*updated.Cover)
					results[idx].ResolvedCover = coverURL
				}
			}

			if coverURL == "" {
				results[idx].Error = "no cover URL available"
				cancel()
				continue
			}

			var imgBytes []byte
			var fetchErr error
			if src != nil {
				imgBytes, fetchErr = src.DownloadCover(itemCtx, coverURL)
			} else {
				imgBytes, fetchErr = source.DownloadCoverDirect(itemCtx, coverURL, cookiesForURL(cookiePath, coverURL))
			}
			cancel()

			if fetchErr != nil {
				results[idx].Error = fetchErr.Error()
				continue
			}
			if saveErr := source.SaveCoverThumbnail(imgBytes, it.DestPath, payload.MaxWidth, payload.MaxHeight); saveErr != nil {
				results[idx].Error = saveErr.Error()
				continue
			}
			results[idx].OK = true
			results[idx].Path = it.DestPath
			fmt.Fprintf(os.Stderr, "[cover] %d\n", idx+1)
		}
		if src != nil {
			_ = src.Runner.Close(ctx)
		}
	}

	return printJSON(map[string]any{"results": results})
}
