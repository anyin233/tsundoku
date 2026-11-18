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
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ohaiibuzzle/aidokurunner-go/models"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime/host"
	"github.com/ohaiibuzzle/aidokurunner-go/settingsstore"
	"github.com/ohaiibuzzle/aidokurunner-go/source"
)

const (
	defaultSearchTimeout     = 20 * time.Second
	flareSolverrSearchTimout = 45 * time.Second
	maxSearchWorkers         = 6
)

type searchBatchPayload struct {
	Query      string                  `json:"query"`
	Page       int                     `json:"page"`
	Workers    int                     `json:"workers,omitempty"`
	TimeoutSec int                     `json:"timeoutSec,omitempty"`
	StreamPath string                  `json:"streamPath,omitempty"`
	Sources    []searchBatchSourceSpec `json:"sources"`
}

type searchBatchSourceSpec struct {
	Key     string               `json:"key"`
	Name    string               `json:"name"`
	Path    string               `json:"path"`
	Filters []models.FilterValue `json:"filters,omitempty"`
}

type searchBatchResultItem struct {
	SourceKey  string         `json:"sourceKey"`
	SourceName string         `json:"sourceName"`
	SourcePath string         `json:"sourcePath"`
	Entries    []models.Manga `json:"entries,omitempty"`
	HasNext    bool           `json:"hasNext,omitempty"`
	Error      string         `json:"error,omitempty"`
}

type searchStreamEntry struct {
	Key           string                  `json:"Key"`
	Title         string                  `json:"Title"`
	Cover         *string                 `json:"Cover,omitempty"`
	Artists       []string                `json:"Artists,omitempty"`
	Authors       []string                `json:"Authors,omitempty"`
	URL           *string                 `json:"URL,omitempty"`
	Status        models.PublishingStatus `json:"Status,omitempty"`
	ContentRating models.ContentRating    `json:"ContentRating,omitempty"`
	Viewer        models.Viewer           `json:"Viewer,omitempty"`
}

type searchStreamEvent struct {
	Type       string              `json:"type"`
	Index      int                 `json:"index"`
	Done       int                 `json:"done,omitempty"`
	Total      int                 `json:"total"`
	SourceKey  string              `json:"sourceKey"`
	SourceName string              `json:"sourceName"`
	SourcePath string              `json:"sourcePath,omitempty"`
	Entries    []searchStreamEntry `json:"entries,omitempty"`
	HasNext    bool                `json:"hasNext,omitempty"`
	ElapsedMs  int64               `json:"elapsedMs,omitempty"`
	Error      string              `json:"error,omitempty"`
}

func slimSearchEntries(entries []models.Manga) []searchStreamEntry {
	if len(entries) == 0 {
		return nil
	}
	out := make([]searchStreamEntry, len(entries))
	for i, m := range entries {
		out[i] = searchStreamEntry{
			Key:           m.Key,
			Title:         m.Title,
			Cover:         m.Cover,
			Artists:       m.Artists,
			Authors:       m.Authors,
			URL:           m.URL,
			Status:        m.Status,
			ContentRating: m.ContentRating,
			Viewer:        m.Viewer,
		}
	}
	return out
}

func readLinuxMemTotalMB() int {
	raw, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		kb, perr := strconv.Atoi(fields[1])
		if perr == nil && kb > 0 {
			return kb / 1024
		}
	}
	return 0
}

func resolveSearchWorkers(requested, total int, goarch string, numCPU, memTotalMB int) int {
	if total <= 0 {
		return 0
	}
	var workers int
	if requested > 0 {
		workers = requested
		if workers > maxSearchWorkers {
			workers = maxSearchWorkers
		}
		if goarch == "arm" && memTotalMB > 0 && memTotalMB <= 320 && workers > 2 {
			workers = 2
		}
	} else if goarch == "arm" {
		if memTotalMB > 0 && memTotalMB <= 600 {
			workers = 2
		} else if numCPU >= 2 {
			workers = 3
		} else {
			workers = 2
		}
	} else {
		if memTotalMB > 0 && memTotalMB <= 512 {
			workers = 2
		} else {
			workers = 4
		}
	}
	if workers > total {
		workers = total
	}
	if workers < 1 {
		workers = 1
	}
	return workers
}

func resolvePerSearchTimeout(timeoutSec int) time.Duration {
	if timeoutSec > 0 {
		if timeoutSec < 5 {
			timeoutSec = 5
		} else if timeoutSec > 120 {
			timeoutSec = 120
		}
		return time.Duration(timeoutSec) * time.Second
	}
	if host.FlareSolverrHostFromEnv() != "" {
		return flareSolverrSearchTimout
	}
	return defaultSearchTimeout
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
// aidoku-run process with a hardware-bounded worker pool, emitting
// "[search] done/total\tname" lines to stderr and optional real-time NDJSON
// events to payload.StreamPath.
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

	var streamFile *os.File
	if payload.StreamPath != "" {
		f, ferr := os.OpenFile(payload.StreamPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if ferr != nil {
			return fmt.Errorf("opening search stream path: %w", ferr)
		}
		streamFile = f
		defer streamFile.Close()
	}

	results := make([]searchBatchResultItem, len(payload.Sources))
	if len(payload.Sources) == 0 {
		if streamFile != nil {
			return printJSON(map[string]any{"streamed": true, "done": 0, "total": 0})
		}
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
	var streamMu sync.Mutex
	var cacheMu sync.Mutex
	var doneMu sync.Mutex
	doneCount := 0
	total := len(payload.Sources)

	emitStream := func(ev searchStreamEvent) {
		if streamFile == nil {
			return
		}
		line, merr := json.Marshal(ev)
		if merr != nil {
			return
		}
		line = append(line, '\n')
		streamMu.Lock()
		_, _ = streamFile.Write(line)
		streamMu.Unlock()
	}

	workers := resolveSearchWorkers(payload.Workers, total, goruntime.GOARCH, goruntime.NumCPU(), readLinuxMemTotalMB())
	perTimeout := resolvePerSearchTimeout(payload.TimeoutSec)
	netConc := host.NetworkConcurrencyFromEnv()
	if workers > 1 && goruntime.GOARCH == "arm" && (netConc <= 0 || netConc > 4) {
		netConc = 4
	}

	jobs := make(chan int, total)
	for i := range payload.Sources {
		jobs <- i
	}
	close(jobs)

	searchOne := func(idx int) (searchBatchResultItem, time.Duration) {
		started := time.Now()
		spec := payload.Sources[idx]
		out := searchBatchResultItem{
			SourceKey:  spec.Key,
			SourceName: spec.Name,
			SourcePath: spec.Path,
		}
		if ctx.Err() != nil {
			out.Error = ctx.Err().Error()
			return out, time.Since(started)
		}
		if spec.Path == "" {
			out.Error = "empty source path"
			return out, time.Since(started)
		}

		srcCtx, cancel := context.WithTimeout(ctx, perTimeout)
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
			NetworkConcurrency: netConc,
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
			return out, time.Since(started)
		}

		closed := false
		closeSrc := func() {
			if !closed && src != nil && src.Runner != nil {
				closed = true
				_ = src.Runner.Close(context.Background())
			}
		}
		defer closeSrc()

		if out.SourceKey == "" {
			out.SourceKey = src.Key
		}
		if out.SourceName == "" {
			out.SourceName = src.Name
		}

		injectCookiesFromFile(src, preloadedCookies)
		query := payload.Query
		res, serr := src.GetSearchMangaList(srcCtx, &query, page, spec.Filters)
		closeSrc()
		if serr != nil {
			out.Error = serr.Error()
			return out, time.Since(started)
		}
		if res != nil {
			out.Entries = res.Entries
			out.HasNext = res.HasNextPage
		}
		return out, time.Since(started)
	}

	var wg sync.WaitGroup
	wg.Add(workers)
	for w := 0; w < workers; w++ {
		go func() {
			defer wg.Done()
			for idx := range jobs {
				spec := payload.Sources[idx]
				if ctx.Err() != nil {
					results[idx] = searchBatchResultItem{
						SourceKey:  spec.Key,
						SourceName: spec.Name,
						SourcePath: spec.Path,
						Error:      ctx.Err().Error(),
					}
					continue
				}

				emitStream(searchStreamEvent{
					Type:       "start",
					Index:      idx + 1,
					Total:      total,
					SourceKey:  spec.Key,
					SourceName: sanitizeProgressName(spec.Name, spec.Key),
					SourcePath: spec.Path,
				})

				out, elapsed := searchOne(idx)
				label := sanitizeProgressName(out.SourceName, spec.Key)

				doneMu.Lock()
				doneCount++
				cur := doneCount
				doneMu.Unlock()

				stderrMu.Lock()
				fmt.Fprintf(os.Stderr, "[search] %d/%d\t%s\n", cur, total, label)
				stderrMu.Unlock()

				if streamFile != nil {
					emitStream(searchStreamEvent{
						Type:       "result",
						Index:      idx + 1,
						Done:       cur,
						Total:      total,
						SourceKey:  out.SourceKey,
						SourceName: out.SourceName,
						SourcePath: out.SourcePath,
						Entries:    slimSearchEntries(out.Entries),
						HasNext:    out.HasNext,
						ElapsedMs:  elapsed.Milliseconds(),
						Error:      out.Error,
					})
					out.Entries = nil
				}
				results[idx] = out
			}
		}()
	}
	wg.Wait()

	if streamFile != nil {
		return printJSON(map[string]any{
			"streamed": true,
			"done":     doneCount,
			"total":    total,
		})
	}
	return printJSON(map[string]any{"results": results})
}
