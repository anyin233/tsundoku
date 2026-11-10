package main

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ohaiibuzzle/aidokurunner-go/settingsstore"
)

func TestHandleCoversDirectAndAlreadyCached(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 240, 360))
	for y := 0; y < 360; y++ {
		for x := 0; x < 240; x++ {
			img.Set(x, y, color.RGBA{R: 120, G: 140, B: 180, A: 255})
		}
	}
	var pngBuf bytes.Buffer
	if err := png.Encode(&pngBuf, img); err != nil {
		t.Fatalf("png.Encode: %v", err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/ok.png":
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(pngBuf.Bytes())
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	tmp := t.TempDir()
	existingPath := filepath.Join(tmp, "existing.jpg")
	if err := os.WriteFile(existingPath, []byte("preexisting"), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	fetchedPath := filepath.Join(tmp, "fetched.jpg")
	failedPath := filepath.Join(tmp, "failed.jpg")

	reqPath := filepath.Join(tmp, "req.json")
	reqBody, err := json.Marshal(coversPayload{
		MaxWidth:  160,
		MaxHeight: 240,
		Items: []coverRequestItem{
			{ID: "a", CoverURL: srv.URL + "/unused.png", DestPath: existingPath},
			{ID: "b", CoverURL: srv.URL + "/ok.png", DestPath: fetchedPath},
			{ID: "c", CoverURL: srv.URL + "/missing.png", DestPath: failedPath},
		},
	})
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if err := os.WriteFile(reqPath, reqBody, 0o644); err != nil {
		t.Fatalf("WriteFile req: %v", err)
	}

	settings, err := settingsstore.Open(filepath.Join(tmp, "settings.json"))
	if err != nil {
		t.Fatalf("settingsstore.Open: %v", err)
	}

	origStdout, origStderr := os.Stdout, os.Stderr
	rOut, wOut, _ := os.Pipe()
	rErr, wErr, _ := os.Pipe()
	os.Stdout, os.Stderr = wOut, wErr
	defer func() {
		os.Stdout, os.Stderr = origStdout, origStderr
	}()

	runErr := handleCovers(context.Background(), settings, filepath.Join(tmp, "cookies.json"), []string{reqPath})
	wOut.Close()
	wErr.Close()
	stdoutBytes, _ := io.ReadAll(rOut)
	stderrBytes, _ := io.ReadAll(rErr)
	os.Stdout, os.Stderr = origStdout, origStderr

	if runErr != nil {
		t.Fatalf("handleCovers: %v", runErr)
	}

	var parsed struct {
		Results []coverResultItem `json:"results"`
	}
	if err := json.Unmarshal(stdoutBytes, &parsed); err != nil {
		t.Fatalf("unmarshal stdout %q: %v", string(stdoutBytes), err)
	}
	if len(parsed.Results) != 3 {
		t.Fatalf("got %d results, want 3", len(parsed.Results))
	}
	if !parsed.Results[0].OK || !parsed.Results[1].OK || parsed.Results[2].OK {
		t.Fatalf("unexpected result flags: %+v", parsed.Results)
	}
	if st, err := os.Stat(fetchedPath); err != nil || st.Size() == 0 {
		t.Fatalf("expected fetched thumbnail on disk, err=%v", err)
	}
	stderrStr := string(stderrBytes)
	if !strings.Contains(stderrStr, "[cover] 1\n") || !strings.Contains(stderrStr, "[cover] 2\n") {
		t.Fatalf("expected incremental [cover] markers on stderr, got %q", stderrStr)
	}
	if strings.Contains(stderrStr, "[cover] 3\n") {
		t.Fatalf("did not expect [cover] 3 for failed item: %q", stderrStr)
	}
}
