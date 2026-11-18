package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	goruntime "runtime"
	"strings"
	"sync"
	"time"

	"github.com/ohaiibuzzle/aidokurunner-go/models"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime/host"
	"github.com/ohaiibuzzle/aidokurunner-go/settingsstore"
	"github.com/ohaiibuzzle/aidokurunner-go/source"
)

const perSearchTimeout = 45 * time.Second

type searchBatchPayload struct {
	Query   string                  `json:"query"`
	Page    int                     `json:"page"`
	Sources []searchBatchSourceSpec `json:"sources"`
}

type searchBatchSourceSpec struct {
	Key  string `json:"key"`
	Name string `json:"name"`
	Path string `json:"path"`
}

type searchBatchResultItem struct {
	SourceKey  string         `json:"sourceKey"`
	SourceName string         `json:"sourceName"`
	SourcePath string         `json:"sourcePath"`
	Entries    []models.Manga `json:"entries,omitempty"`
	HasNext    bool           `json:"hasNext,omitempty"`
	Error      string         `json:"error,omitempty"`
}

func injectCookiesFromFile(src *source.Source, f cookieFile) {
	if len(f) == 0 {
		return
	}
	jar := src.Runner.CookieJar()
	if jar == nil {
		return
	}
	for domain, entries := range f {
		if domain == "" {
			continue
		}
		cookies := make([]*http.Cookie, 0, len(entries))
		for _, e := range entries {
			cookies = append(cookies, e.cookie())
		}
		jar.SetCookies(&url.URL{Scheme: "https", Host: domain, Path: "/"}, cookies)
	}
}

func sanitizeProgressName(name, key string) string {
	s := strings.TrimSpace(name)
	if s == "" {
		s = strings.TrimSpace(key)
	}
	if s == "" {
		s = "source"
	}
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\t", " ")
	return s
}

// handleSearchBatch executes multi-source queries concurrently inside one
// aidoku-run process with a bounded worker pool, eliminating N sequential CLI
// startups and emitting "[search] done/total\tname" progress lines to stderr.
func handleSearchBatch(ctx context.Context, settings *settingsstore.Store, cookiePath string, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: aidoku-run - search-batch <payload.json>")
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return fmt.Errorf("reading search-batch payload: %w", err)
	}
	var payload searchBatchPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return fmt.Errorf("parsing search-batch payload: %w", err)
	}

	results := make([]searchBatchResultItem, len(payload.Sources))
	if len(payload.Sources) == 0 {
		return printJSON(map[string]any{"results": results})
	}

	page := payload.Page
	if page <= 0 {
		page = 1
	}

	preloadedCookies, _ := readCookieFile(cookiePath)
	compilationCache, cacheDir := openCompilationCache()
	if compilationCache != nil {
		defer compilationCache.Close(ctx)
	}

	var stderrMu sync.Mutex
	var cacheMu sync.Mutex
	var doneMu sync.Mutex
	doneCount := 0
	total := len(payload.Sources)

	workers := 4
	if goruntime.GOARCH == "arm" {
		workers = 3
	}
	if workers > total {
		workers = total
	}

	jobs := make(chan int, total)
	for i := range payload.Sources {
		jobs <- i
	}
	close(jobs)

	searchOne := func(idx int) {
		spec := payload.Sources[idx]
		out := searchBatchResultItem{
			SourceKey:  spec.Key,
			SourceName: spec.Name,
			SourcePath: spec.Path,
		}
		if ctx.Err() != nil {
			out.Error = ctx.Err().Error()
			results[idx] = out
			return
		}
		if spec.Path == "" {
			out.Error = "empty source path"
			results[idx] = out
			return
		}

		srcCtx, cancel := context.WithTimeout(ctx, perSearchTimeout)
		defer cancel()

		cacheMu.Lock()
		cc := compilationCache
		cacheMu.Unlock()

		interpConfig := runtime.Config{
			PrintHandler: func(s string) {
				stderrMu.Lock()
				fmt.Fprintln(os.Stderr, "[print]", s)
				stderrMu.Unlock()
			},
			Settings:         settings,
			CompilationCache: cc,
			OnFlareSolverrCookies: func(u *url.URL, cookies []*http.Cookie) {
				_ = persistCookies(cookiePath, cookies)
			},
			OnCookiesDeleted: func(h, domain string, names []string) {
				_ = forgetCookies(cookiePath, h, domain, names)
			},
			NetworkConcurrency: host.NetworkConcurrencyFromEnv(),
		}

		src, lerr := source.LoadPath(srcCtx, spec.Path, interpConfig, settings)
		if errors.Is(lerr, runtime.ErrCompile) && cc != nil {
			cacheMu.Lock()
			if cacheDir != "" {
				_ = os.RemoveAll(cacheDir)
			}
			compilationCache = nil
			cacheMu.Unlock()

			interpConfig.CompilationCache = nil
			src, lerr = source.LoadPath(srcCtx, spec.Path, interpConfig, settings)
		}
		if lerr != nil {
			out.Error = lerr.Error()
			results[idx] = out
			return
		}
		defer src.Runner.Close(srcCtx)

		if out.SourceKey == "" {
			out.SourceKey = src.Key
		}
		if out.SourceName == "" {
			out.SourceName = src.Name
		}

		injectCookiesFromFile(src, preloadedCookies)
		query := payload.Query
		res, serr := src.GetSearchMangaList(srcCtx, &query, page, nil)
		if serr != nil {
			out.Error = serr.Error()
			results[idx] = out
			return
		}
		if res != nil {
			out.Entries = res.Entries
			out.HasNext = res.HasNextPage
		}
		results[idx] = out
	}

	var wg sync.WaitGroup
	wg.Add(workers)
	for w := 0; w < workers; w++ {
		go func() {
			defer wg.Done()
			for idx := range jobs {
				searchOne(idx)
				spec := payload.Sources[idx]
				label := sanitizeProgressName(results[idx].SourceName, spec.Key)
				doneMu.Lock()
				doneCount++
				cur := doneCount
				doneMu.Unlock()

				stderrMu.Lock()
				fmt.Fprintf(os.Stderr, "[search] %d/%d\t%s\n", cur, total, label)
				stderrMu.Unlock()
			}
		}()
	}
	wg.Wait()

	return printJSON(map[string]any{"results": results})
}
