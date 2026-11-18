package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

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
