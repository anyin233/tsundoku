package source

import (
	"context"
	"fmt"
	"image"
	"image/draw"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"time"

	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp"

	"github.com/ohaiibuzzle/aidokurunner-go/internal/fsutil"
	"github.com/ohaiibuzzle/aidokurunner-go/models"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime/host"
)

const (
	defaultCoverMaxWidth  = 320
	defaultCoverMaxHeight = 480
	coverJPEGQuality      = 85
)

// DownloadCover fetches a manga cover image URL through this source's
// get_image_request / cookie jar / FlareSolverr pipeline and, when the source
// exports process_cover_image, runs it over the response.
func (s *Source) DownloadCover(ctx context.Context, rawURL string) ([]byte, error) {
	f, err := s.fetchURL(ctx, rawURL, nil)
	if err != nil {
		return nil, err
	}
	if s.Runner.Features.ProcessesCovers {
		return s.processCover(ctx, f)
	}
	return f.body, f.failure
}

func (s *Source) processCover(ctx context.Context, f pageFetch) ([]byte, error) {
	u := f.req.URL.String()
	resp := models.Response{
		Code:    404,
		Headers: map[string]string{},
		Request: models.Request{URL: &u, Headers: flattenHeader(f.req.Header)},
	}
	var stored any = image.NewGray(image.Rect(0, 0, 1, 1))
	if f.failure == nil {
		resp.Code, resp.Headers = uint16(f.status), flattenHeader(f.header)
		stored = f.body
		if img, err := host.DecodeImageBounded(f.body); err == nil {
			stored = img
		}
	}
	resp.Image = s.Runner.StoreValue(stored)
	defer s.Runner.RemoveValue(resp.Image)

	out, err := s.Runner.ProcessCoverImage(ctx, resp)
	if err != nil {
		if f.failure == nil && len(f.body) > 0 {
			return f.body, nil
		}
		if f.failure != nil {
			return nil, fmt.Errorf("source: process_cover_image: %w (after fetch failed: %v)", err, f.failure)
		}
		return nil, fmt.Errorf("source: process_cover_image: %w", err)
	}
	return s.resolveImageRef(models.ImageRef(out))
}

// DownloadCoverDirect fetches rawURL without a loaded WASM source (used as a
// fallback when a bookmarked manga's source is no longer installed locally,
// while its cover URL is still known).
func DownloadCoverDirect(ctx context.Context, rawURL string, cookies []*http.Cookie) ([]byte, error) {
	if rawURL == "" {
		return nil, fmt.Errorf("source: cover has empty URL")
	}
	parsed, err := url.Parse(rawURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return nil, fmt.Errorf("source: invalid cover URL %q", rawURL)
	}
	originReferer := parsed.Scheme + "://" + parsed.Host + "/"

	for attempt := 0; ; attempt++ {
		req, reqErr := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if reqErr != nil {
			return nil, fmt.Errorf("source: building cover request for %s: %w", rawURL, reqErr)
		}
		req.Header.Set("User-Agent", defaultPageUserAgent)
		req.Header.Set("Referer", originReferer)
		for _, c := range cookies {
			if c != nil {
				req.AddCookie(c)
			}
		}

		f, retryable := fetchOnce(req, rawURL)
		if f.failure != nil && ctx.Err() != nil {
			return nil, f.failure
		}
		if !retryable || attempt >= maxPageRetries {
			return f.body, f.failure
		}
		t := time.NewTimer(retryDelay(f.header, attempt))
		select {
		case <-ctx.Done():
			t.Stop()
			return nil, fmt.Errorf("%w (while retrying: %v)", ctx.Err(), f.failure)
		case <-t.C:
		}
	}
}

// SaveCoverThumbnail decodes rawBytes (JPEG, PNG, GIF, or WebP) with bounded
// memory, composites any alpha channel onto opaque white, downscales
// proportionally to fit within maxW x maxH, and atomically writes a compact
// baseline JPEG thumbnail to destPath.
func SaveCoverThumbnail(rawBytes []byte, destPath string, maxW, maxH int) error {
	if len(rawBytes) == 0 {
		return fmt.Errorf("source: empty cover image data")
	}
	if destPath == "" {
		return fmt.Errorf("source: empty cover destination path")
	}
	if maxW <= 0 {
		maxW = defaultCoverMaxWidth
	}
	if maxH <= 0 {
		maxH = defaultCoverMaxHeight
	}

	srcImg, err := host.DecodeImageBounded(rawBytes)
	if err != nil {
		return fmt.Errorf("source: decoding cover image: %w", err)
	}
	sb := srcImg.Bounds()
	srcW, srcH := sb.Dx(), sb.Dy()
	if srcW <= 0 || srcH <= 0 {
		return fmt.Errorf("source: invalid cover dimensions %dx%d", srcW, srcH)
	}

	dstW, dstH := srcW, srcH
	if srcW > maxW || srcH > maxH {
		scale := math.Min(float64(maxW)/float64(srcW), float64(maxH)/float64(srcH))
		dstW = max(1, int(math.Round(float64(srcW)*scale)))
		dstH = max(1, int(math.Round(float64(srcH)*scale)))
	}

	canvas := image.NewRGBA(image.Rect(0, 0, dstW, dstH))
	draw.Draw(canvas, canvas.Bounds(), image.White, image.Point{}, draw.Src)
	if dstW == srcW && dstH == srcH {
		draw.Draw(canvas, canvas.Bounds(), srcImg, sb.Min, draw.Over)
	} else {
		xdraw.BiLinear.Scale(canvas, canvas.Bounds(), srcImg, sb, xdraw.Over, nil)
	}

	dir := filepath.Dir(destPath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("source: creating cover cache dir: %w", err)
	}
	tmp, err := os.CreateTemp(dir, ".cover-*.tmp")
	if err != nil {
		return fmt.Errorf("source: creating cover temp file: %w", err)
	}
	tmpPath := tmp.Name()
	if err := jpeg.Encode(tmp, canvas, &jpeg.Options{Quality: coverJPEGQuality}); err != nil {
		tmp.Close()
		_ = os.Remove(tmpPath)
		return fmt.Errorf("source: encoding cover thumbnail: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		_ = os.Remove(tmpPath)
		return fmt.Errorf("source: syncing cover thumbnail: %w", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("source: closing cover thumbnail: %w", err)
	}
	if err := os.Rename(tmpPath, destPath); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("source: renaming cover thumbnail: %w", err)
	}
	_ = fsutil.SyncDir(dir)
	return nil
}
