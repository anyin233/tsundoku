package source

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestSaveCoverThumbnailDownscalesAndCompositesAlpha(t *testing.T) {
	// 600x900 transparent PNG with a solid dark center block.
	src := image.NewNRGBA(image.Rect(0, 0, 600, 900))
	for y := 200; y < 700; y++ {
		for x := 100; x < 500; x++ {
			src.SetNRGBA(x, y, color.NRGBA{R: 30, G: 40, B: 50, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, src); err != nil {
		t.Fatalf("png.Encode: %v", err)
	}

	dest := filepath.Join(t.TempDir(), "covers", "thumb.jpg")
	if err := SaveCoverThumbnail(buf.Bytes(), dest, 200, 300); err != nil {
		t.Fatalf("SaveCoverThumbnail: %v", err)
	}

	raw, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	decoded, err := jpeg.Decode(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("jpeg.Decode: %v", err)
	}
	if gotW, gotH := decoded.Bounds().Dx(), decoded.Bounds().Dy(); gotW != 200 || gotH != 300 {
		t.Fatalf("got dimensions %dx%d, want 200x300", gotW, gotH)
	}
	// Transparent corner (0,0) should have composited onto white (~255), not black (0).
	r, g, b, _ := decoded.At(2, 2).RGBA()
	if r>>8 < 245 || g>>8 < 245 || b>>8 < 245 {
		t.Fatalf("expected white corner from alpha composite, got RGB=(%d,%d,%d)", r>>8, g>>8, b>>8)
	}
}

func TestDownloadCoverDirectSendsRefererAndCookies(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 40, 60))
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		t.Fatalf("png.Encode: %v", err)
	}

	var gotReferer, gotUA, gotCookie string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotReferer = r.Header.Get("Referer")
		gotUA = r.Header.Get("User-Agent")
		if c, err := r.Cookie("cf_clearance"); err == nil {
			gotCookie = c.Value
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(encoded.Bytes())
	}))
	defer srv.Close()

	data, err := DownloadCoverDirect(context.Background(), srv.URL+"/img/cover.png", []*http.Cookie{
		{Name: "cf_clearance", Value: "tok123"},
	})
	if err != nil {
		t.Fatalf("DownloadCoverDirect: %v", err)
	}
	if len(data) == 0 {
		t.Fatalf("expected non-empty body")
	}
	if gotReferer != srv.URL+"/" {
		t.Fatalf("got Referer %q, want %q", gotReferer, srv.URL+"/")
	}
	if gotUA == "" {
		t.Fatalf("expected non-empty User-Agent")
	}
	if gotCookie != "tok123" {
		t.Fatalf("got cookie %q, want tok123", gotCookie)
	}
}
