package main

import (
	"archive/zip"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ohaiibuzzle/aidokurunner-go/settingsstore"
)

func runHandleSearchBatchForTest(t *testing.T, settings *settingsstore.Store, cookiePath string, payload searchBatchPayload) (struct {
	Results []searchBatchResultItem `json:"results"`
}, string) {
	t.Helper()
	reqPath := filepath.Join(t.TempDir(), "search_req.json")
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if err := os.WriteFile(reqPath, body, 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	origStdout, origStderr := os.Stdout, os.Stderr
	rOut, wOut, _ := os.Pipe()
	rErr, wErr, _ := os.Pipe()
	os.Stdout, os.Stderr = wOut, wErr
	defer func() {
		os.Stdout, os.Stderr = origStdout, origStderr
	}()

	runErr := handleSearchBatch(context.Background(), settings, cookiePath, []string{reqPath})
	wOut.Close()
	wErr.Close()
	stdoutBytes, _ := io.ReadAll(rOut)
	stderrBytes, _ := io.ReadAll(rErr)
	os.Stdout, os.Stderr = origStdout, origStderr

	if runErr != nil {
		t.Fatalf("handleSearchBatch: %v", runErr)
	}
	var parsed struct {
		Results []searchBatchResultItem `json:"results"`
	}
	if err := json.Unmarshal(stdoutBytes, &parsed); err != nil {
		t.Fatalf("unmarshal stdout %q: %v", string(stdoutBytes), err)
	}
	return parsed, string(stderrBytes)
}

func TestHandleSearchBatchEmptyAndPartialErrors(t *testing.T) {
	tmp := t.TempDir()
	settings, err := settingsstore.Open(filepath.Join(tmp, "settings.json"))
	if err != nil {
		t.Fatalf("settingsstore.Open: %v", err)
	}
	cookies := filepath.Join(tmp, "cookies.json")

	emptyParsed, _ := runHandleSearchBatchForTest(t, settings, cookies, searchBatchPayload{
		Query:   "test",
		Page:    1,
		Sources: nil,
	})
	if len(emptyParsed.Results) != 0 {
		t.Fatalf("empty Results len = %d, want 0", len(emptyParsed.Results))
	}

	parsed, stderrStr := runHandleSearchBatchForTest(t, settings, cookies, searchBatchPayload{
		Query: "test",
		Page:  1,
		Sources: []searchBatchSourceSpec{
			{Key: "first.src", Name: "First\nSource", Path: filepath.Join(tmp, "missing1.aix")},
			{Key: "second.src", Name: "Second Source", Path: ""},
		},
	})
	if len(parsed.Results) != 2 {
		t.Fatalf("Results len = %d, want 2", len(parsed.Results))
	}
	if parsed.Results[0].SourceKey != "first.src" || parsed.Results[0].Error == "" {
		t.Fatalf("result[0] = %+v, want error isolated to first.src", parsed.Results[0])
	}
	if parsed.Results[1].SourceKey != "second.src" || parsed.Results[1].Error == "" {
		t.Fatalf("result[1] = %+v, want error isolated to second.src", parsed.Results[1])
	}
	if !strings.Contains(stderrStr, "[search] 1/2\t") || !strings.Contains(stderrStr, "[search] 2/2\t") {
		t.Fatalf("expected incremental [search] progress lines on stderr, got %q", stderrStr)
	}
}

func TestHandleSearchBatchConcurrentWithLiveSource(t *testing.T) {
	aixPath := filepath.Join("..", "..", "koreader", "aidoku.koplugin", "builtin_sources", "biquge-v1.aix")
	if _, err := os.Stat(aixPath); err != nil {
		t.Skipf("biquge-v1.aix not built yet (%v); skipping concurrent source search test", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=gbk")
		_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><body>
			<form action="/search.php" method="post" accept-charset="gbk">
				<input type="text" name="keyword" />
			</form>
		</body></html>`))
	})
	mux.HandleFunc("/search.php", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=gbk")
		_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><head><meta charset="gbk"></head><body>
			<table class="grid">
				<tr><th>书名</th><th>最新</th><th>作者</th></tr>
				<tr><td><a href="/book/42/">Sample Book</a></td><td>第1章</td><td>Author</td></tr>
			</table>
		</body></html>`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	tmp := t.TempDir()
	settings, err := settingsstore.Open(filepath.Join(tmp, "settings.json"))
	if err != nil {
		t.Fatalf("settingsstore.Open: %v", err)
	}
	if err := settings.SetValue("zh.biquge.mirror_url", srv.URL); err != nil {
		t.Fatalf("SetValue mirror_url: %v", err)
	}

	parsed, stderrStr := runHandleSearchBatchForTest(t, settings, filepath.Join(tmp, "cookies.json"), searchBatchPayload{
		Query: "Sample",
		Page:  1,
		Sources: []searchBatchSourceSpec{
			{Key: "bad.src", Name: "Broken", Path: filepath.Join(tmp, "nonexistent.aix")},
			{Key: "zh.biquge", Name: "Biquge", Path: aixPath},
		},
	})
	if len(parsed.Results) != 2 {
		t.Fatalf("Results len = %d, want 2", len(parsed.Results))
	}
	if parsed.Results[0].SourceKey != "bad.src" || parsed.Results[0].Error == "" {
		t.Fatalf("result[0] = %+v, want error", parsed.Results[0])
	}
	if parsed.Results[1].SourceKey != "zh.biquge" || parsed.Results[1].Error != "" {
		t.Fatalf("result[1] = %+v, want success", parsed.Results[1])
	}
	if len(parsed.Results[1].Entries) == 0 || parsed.Results[1].Entries[0].Title != "Sample Book" {
		t.Fatalf("result[1].Entries = %+v, want Sample Book", parsed.Results[1].Entries)
	}
	if !strings.Contains(stderrStr, "[search] 2/2\t") {
		t.Fatalf("expected 2/2 completion marker on stderr, got %q", stderrStr)
	}
}

func TestResolveSearchWorkers(t *testing.T) {
	cases := []struct {
		name       string
		requested  int
		total      int
		goarch     string
		numCPU     int
		memTotalMB int
		want       int
	}{
		{name: "empty", requested: 0, total: 0, goarch: "arm", numCPU: 2, memTotalMB: 956, want: 0},
		{name: "arm_256mb_auto", requested: 0, total: 10, goarch: "arm", numCPU: 1, memTotalMB: 256, want: 2},
		{name: "arm_512mb_auto", requested: 0, total: 10, goarch: "arm", numCPU: 2, memTotalMB: 512, want: 2},
		{name: "arm_956mb_1cpu_auto", requested: 0, total: 10, goarch: "arm", numCPU: 1, memTotalMB: 956, want: 2},
		{name: "arm_956mb_2cpu_auto", requested: 0, total: 10, goarch: "arm", numCPU: 2, memTotalMB: 956, want: 3},
		{name: "arm_256mb_clamps_requested", requested: 5, total: 10, goarch: "arm", numCPU: 1, memTotalMB: 256, want: 2},
		{name: "arm_956mb_allows_requested_4", requested: 4, total: 10, goarch: "arm", numCPU: 2, memTotalMB: 956, want: 4},
		{name: "arm64_auto", requested: 0, total: 10, goarch: "arm64", numCPU: 8, memTotalMB: 8192, want: 4},
		{name: "amd64_512mb_auto", requested: 0, total: 10, goarch: "amd64", numCPU: 4, memTotalMB: 512, want: 2},
		{name: "amd64_clamps_to_max_6", requested: 12, total: 10, goarch: "amd64", numCPU: 8, memTotalMB: 8192, want: 6},
		{name: "serial_requested_1", requested: 1, total: 8, goarch: "amd64", numCPU: 8, memTotalMB: 8192, want: 1},
		{name: "clamps_to_total", requested: 4, total: 2, goarch: "amd64", numCPU: 8, memTotalMB: 8192, want: 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := resolveSearchWorkers(tc.requested, tc.total, tc.goarch, tc.numCPU, tc.memTotalMB)
			if got != tc.want {
				t.Fatalf("resolveSearchWorkers(%d, %d, %q, %d, %d) = %d, want %d",
					tc.requested, tc.total, tc.goarch, tc.numCPU, tc.memTotalMB, got, tc.want)
			}
		})
	}
}

func cloneAixDirWithID(t *testing.T, aixPath, newID, newName string) string {
	t.Helper()
	r, err := zip.OpenReader(aixPath)
	if err != nil {
		t.Fatalf("zip.OpenReader: %v", err)
	}
	defer r.Close()

	dstDir := filepath.Join(t.TempDir(), newID)
	if err := os.MkdirAll(dstDir, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	for _, f := range r.File {
		if f.FileInfo().IsDir() || !strings.HasPrefix(f.Name, "Payload/") {
			continue
		}
		rel := strings.TrimPrefix(f.Name, "Payload/")
		if rel == "" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			t.Fatalf("open zip entry %s: %v", f.Name, err)
		}
		data, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			t.Fatalf("read zip entry %s: %v", f.Name, err)
		}
		if rel == "source.json" {
			var manifest map[string]any
			if err := json.Unmarshal(data, &manifest); err != nil {
				t.Fatalf("unmarshal source.json: %v", err)
			}
			if info, ok := manifest["info"].(map[string]any); ok {
				info["id"] = newID
				info["name"] = newName
			}
			data, err = json.Marshal(manifest)
			if err != nil {
				t.Fatalf("marshal modified source.json: %v", err)
			}
		}
		outPath := filepath.Join(dstDir, rel)
		if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
			t.Fatalf("MkdirAll parent: %v", err)
		}
		if err := os.WriteFile(outPath, data, 0o644); err != nil {
			t.Fatalf("WriteFile %s: %v", outPath, err)
		}
	}
	return dstDir
}

func TestHandleSearchBatchStreamingAndCancellation(t *testing.T) {
	aixPath := filepath.Join("..", "..", "koreader", "aidoku.koplugin", "builtin_sources", "biquge-v1.aix")
	if _, err := os.Stat(aixPath); err != nil {
		t.Skipf("biquge-v1.aix not built yet (%v); skipping streaming search test", err)
	}

	slowDir := cloneAixDirWithID(t, aixPath, "zh.biquge.slow", "Slow Biquge")

	fastMux := http.NewServeMux()
	fastMux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=gbk")
		_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><body>
			<form action="/search.php" method="post" accept-charset="gbk">
				<input type="text" name="keyword" />
			</form>
		</body></html>`))
	})
	fastMux.HandleFunc("/search.php", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=gbk")
		_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><head><meta charset="gbk"></head><body>
			<table class="grid">
				<tr><th>书名</th><th>最新</th><th>作者</th></tr>
				<tr><td><a href="/book/42/">Sample Book</a></td><td>第1章</td><td>Author</td></tr>
			</table>
		</body></html>`))
	})
	fastSrv := httptest.NewServer(fastMux)
	defer fastSrv.Close()

	slowEntered := make(chan struct{}, 1)
	slowSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case slowEntered <- struct{}{}:
		default:
		}
		<-r.Context().Done()
	}))
	defer slowSrv.Close()

	tmp := t.TempDir()
	settings, err := settingsstore.Open(filepath.Join(tmp, "settings.json"))
	if err != nil {
		t.Fatalf("settingsstore.Open: %v", err)
	}
	if err := settings.SetValue("zh.biquge.mirror_url", fastSrv.URL); err != nil {
		t.Fatalf("SetValue fast mirror_url: %v", err)
	}
	if err := settings.SetValue("zh.biquge.slow.mirror_url", slowSrv.URL); err != nil {
		t.Fatalf("SetValue slow mirror_url: %v", err)
	}

	streamPath := filepath.Join(tmp, "stream.ndjson")
	reqPath := filepath.Join(tmp, "search_stream_req.json")
	payload := searchBatchPayload{
		Query:      "Sample",
		Page:       1,
		Workers:    2,
		TimeoutSec: 30,
		StreamPath: streamPath,
		Sources: []searchBatchSourceSpec{
			{Key: "zh.biquge.slow", Name: "Slow Biquge", Path: slowDir},
			{Key: "zh.biquge", Name: "Fast Biquge", Path: aixPath},
		},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if err := os.WriteFile(reqPath, body, 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	origStdout, origStderr := os.Stdout, os.Stderr
	rOut, wOut, _ := os.Pipe()
	rErr, wErr, _ := os.Pipe()
	os.Stdout, os.Stderr = wOut, wErr
	defer func() {
		os.Stdout, os.Stderr = origStdout, origStderr
	}()
	go func() { _, _ = io.Copy(io.Discard, rOut); _ = rOut.Close() }()
	go func() { _, _ = io.Copy(io.Discard, rErr); _ = rErr.Close() }()

	doneCh := make(chan error, 1)
	go func() {
		doneCh <- handleSearchBatch(ctx, settings, filepath.Join(tmp, "cookies.json"), []string{reqPath})
	}()

	select {
	case <-slowEntered:
	case <-time.After(10 * time.Second):
		cancel()
		t.Fatal("slow server was not contacted within 10s")
	}

	deadline := time.Now().Add(10 * time.Second)
	var sawFastResult bool
	var sawStart bool
	for time.Now().Before(deadline) {
		rawStream, _ := os.ReadFile(streamPath)
		for _, line := range strings.Split(string(rawStream), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			var ev searchStreamEvent
			if json.Unmarshal([]byte(line), &ev) == nil {
				if ev.Type == "start" {
					sawStart = true
				}
				if ev.Type == "result" && ev.SourceKey == "zh.biquge" && len(ev.Entries) > 0 && ev.Entries[0].Title == "Sample Book" {
					sawFastResult = true
				}
			}
		}
		if sawStart && sawFastResult {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !sawStart || !sawFastResult {
		cancel()
		<-doneCh
		rawStream, _ := os.ReadFile(streamPath)
		t.Fatalf("expected fast result streamed while slow server still blocked; sawStart=%v sawFastResult=%v stream=%q",
			sawStart, sawFastResult, string(rawStream))
	}

	// Verify handleSearchBatch is still running (blocked on slow source), then cancel it.
	select {
	case rerr := <-doneCh:
		t.Fatalf("handleSearchBatch finished before slow source was cancelled: %v", rerr)
	default:
	}

	cancel()
	select {
	case rerr := <-doneCh:
		wOut.Close()
		wErr.Close()
		if rerr != nil {
			t.Fatalf("handleSearchBatch after cancel returned error: %v", rerr)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("handleSearchBatch did not return after context cancellation")
	}

	finalRaw, err := os.ReadFile(streamPath)
	if err != nil {
		t.Fatalf("ReadFile streamPath: %v", err)
	}
	var validFast bool
	for _, line := range strings.Split(string(finalRaw), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var ev searchStreamEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("corrupt NDJSON line %q: %v", line, err)
		}
		if ev.Type == "result" && ev.SourceKey == "zh.biquge" && len(ev.Entries) > 0 && ev.Entries[0].Title == "Sample Book" {
			validFast = true
		}
	}
	if !validFast {
		t.Fatalf("fast result missing from stream after cancellation: %q", string(finalRaw))
	}
}
