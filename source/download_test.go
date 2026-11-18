package source

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/ohaiibuzzle/aidokurunner-go/models"
)

func TestResolveOutputPath_Flat(t *testing.T) {
	dir := t.TempDir()
	manga := models.Manga{Title: "Test Manga"}
	title := "Chapter 1"
	chapter := models.Chapter{Title: &title}

	got, err := ResolveOutputPath(filepath.Join(dir, "Chapter 1.cbz"), "", manga, chapter)
	if err != nil {
		t.Fatalf("ResolveOutputPath: %v", err)
	}
	want := filepath.Join(dir, "Chapter 1.cbz")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveOutputPath_MangaDirCreatedAndSanitized(t *testing.T) {
	dir := t.TempDir()
	manga := models.Manga{Title: "Test Manga"}
	title := "Chapter 1"
	chapter := models.Chapter{Title: &title}

	got, err := ResolveOutputPath(filepath.Join(dir, "Chapter 1.cbz"), `Bad? Name: <Title> [src.key]`, manga, chapter)
	if err != nil {
		t.Fatalf("ResolveOutputPath: %v", err)
	}
	wantDir := filepath.Join(dir, "Bad- Name- -Title- [src.key]")
	want := filepath.Join(wantDir, "Chapter 1.cbz")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if info, err := os.Stat(wantDir); err != nil || !info.IsDir() {
		t.Errorf("expected manga directory %q to have been created", wantDir)
	}
}

func TestResolveOutputPath_SanitizesChapterFilenameToo(t *testing.T) {
	dir := t.TempDir()
	manga := models.Manga{Title: "Test Manga"}
	title := "Chapter 1"
	chapter := models.Chapter{Title: &title}

	got, err := ResolveOutputPath(filepath.Join(dir, `Chapter: 1?.cbz`), "Manga Folder", manga, chapter)
	if err != nil {
		t.Fatalf("ResolveOutputPath: %v", err)
	}
	want := filepath.Join(dir, "Manga Folder", "Chapter- 1-.cbz")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// TestResolveOutputPath_MangaDirNameTraversalRejected guards against a
// manga title of "." or ".." resolving outside the downloads directory:
// unlike the chapter filename (which always gets a ".cbz" suffix
// neutralizing that), mangaDirName is used as a bare path component with
// filepath.Join, so an unsanitized ".." there would escape the intended
// directory entirely.
func TestResolveOutputPath_MangaDirNameTraversalRejected(t *testing.T) {
	dir := t.TempDir()
	manga := models.Manga{Title: "Test Manga"}
	title := "Chapter 1"
	chapter := models.Chapter{Title: &title}

	got, err := ResolveOutputPath(filepath.Join(dir, "downloads", "Chapter 1.cbz"), "..", manga, chapter)
	if err != nil {
		t.Fatalf("ResolveOutputPath: %v", err)
	}
	if !strings.HasPrefix(got, filepath.Join(dir, "downloads")) {
		t.Errorf("resolved path %q escaped the downloads directory %q", got, filepath.Join(dir, "downloads"))
	}
}

func TestSanitizeFilenameRejectsDotAndDotDot(t *testing.T) {
	for _, in := range []string{".", ".."} {
		if got := sanitizeFilename(in); got == "." || got == ".." {
			t.Errorf("sanitizeFilename(%q) = %q, want something other than a bare . or ..", in, got)
		}
	}
}

func TestSanitizeFilenameStripsControlChars(t *testing.T) {
	got := sanitizeFilename("Chapter\x001\x1f\x7f Title")
	if strings.ContainsAny(got, "\x00\x1f\x7f") {
		t.Fatalf("sanitizeFilename left a control character in %q", got)
	}
	if got != "Chapter1 Title" {
		t.Fatalf("sanitizeFilename(...) = %q, want %q", got, "Chapter1 Title")
	}
}

func TestResolveOutputPath_Empty(t *testing.T) {
	manga := models.Manga{Title: "Test Manga"}
	title := "Chapter 1"
	chapter := models.Chapter{Title: &title}

	got, err := ResolveOutputPath("", "ignored", manga, chapter)
	if err != nil {
		t.Fatalf("ResolveOutputPath: %v", err)
	}
	if want := "Test Manga - Chapter 1.cbz"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestSanitizeFilenameIdempotentAroundControlChars(t *testing.T) {
	once := sanitizeFilename("Omake \x01")
	if once != "Omake" || sanitizeFilename(once) != once {
		t.Fatalf("got %q then %q, want stable %q", once, sanitizeFilename(once), "Omake")
	}
}

func TestSanitizeFilenameTruncatesLongNames(t *testing.T) {
	long := strings.Repeat("漫", 90) + " [multi.mangadex]" // 287 bytes
	got := sanitizeFilename(long)
	if len(got) > maxFilenameBytes || !utf8.ValidString(got) {
		t.Fatalf("got %d bytes (valid UTF-8: %v): %q", len(got), utf8.ValidString(got), got)
	}
	if !strings.HasSuffix(got, " [multi.mangadex]") {
		t.Errorf("source-key suffix lost: %q", got)
	}
	if sanitizeFilename(got) != got {
		t.Errorf("not idempotent: %q -> %q", got, sanitizeFilename(got))
	}
	other := sanitizeFilename(strings.Repeat("漫", 45) + "画" + strings.Repeat("漫", 44) + " [multi.mangadex]")
	if other == got {
		t.Errorf("two different long titles truncated to the same name %q", got)
	}
	if short := "Yotsuba to! [multi.mangadex]"; sanitizeFilename(short) != short {
		t.Errorf("short name changed: %q", sanitizeFilename(short))
	}
}

// The extension is part of the sanitized, capped name: an illegal char in it
// is replaced, and a long title still ends in ".cbz" within the cap.
func TestResolveOutputPath_SanitizesAndCapsExtension(t *testing.T) {
	dir := t.TempDir()
	manga := models.Manga{Title: "Test Manga"}
	title := "Chapter 1"
	chapter := models.Chapter{Title: &title}

	got, err := ResolveOutputPath(filepath.Join(dir, "Chapter 1.cb:z\x01"), "", manga, chapter)
	if err != nil {
		t.Fatalf("ResolveOutputPath: %v", err)
	}
	if want := filepath.Join(dir, "Chapter 1.cb-z"); got != want {
		t.Errorf("got %q, want %q", got, want)
	}

	got, err = ResolveOutputPath(filepath.Join(dir, strings.Repeat("a", 300)+".cbz"), "", manga, chapter)
	if err != nil {
		t.Fatalf("ResolveOutputPath: %v", err)
	}
	if base := filepath.Base(got); len(base) > maxFilenameBytes || !strings.HasSuffix(base, ".cbz") {
		t.Errorf("long name not capped with .cbz kept: %d bytes, %q", len(base), base)
	}
	if again, _ := ResolveOutputPath(got, "", manga, chapter); again != got {
		t.Errorf("not idempotent: %q -> %q", got, again)
	}
}

func TestEffectiveViewerAndBuildComicInfo(t *testing.T) {
	tests := []struct {
		name       string
		manga      models.Manga
		wantViewer models.Viewer
		wantFormat string
		wantManga  string
	}{
		{
			name:       "explicit_rtl",
			manga:      models.Manga{Title: "Manga", Viewer: models.ViewerRightToLeft},
			wantViewer: models.ViewerRightToLeft,
			wantManga:  "YesAndRightToLeft",
		},
		{
			name:       "explicit_ltr",
			manga:      models.Manga{Title: "Comic", Viewer: models.ViewerLeftToRight},
			wantViewer: models.ViewerLeftToRight,
			wantManga:  "No",
		},
		{
			name:       "explicit_vertical",
			manga:      models.Manga{Title: "Vertical", Viewer: models.ViewerVertical},
			wantViewer: models.ViewerVertical,
			wantFormat: "Webtoon",
		},
		{
			name:       "explicit_webtoon",
			manga:      models.Manga{Title: "Webtoon", Viewer: models.ViewerWebtoon},
			wantViewer: models.ViewerWebtoon,
			wantFormat: "Webtoon",
		},
		{
			name:       "tag_inferred_webtoon_en",
			manga:      models.Manga{Title: "Strip", Viewer: models.ViewerUnknown, Tags: []string{"Action", " Long Strip "}},
			wantViewer: models.ViewerWebtoon,
			wantFormat: "Webtoon",
		},
		{
			name:       "tag_inferred_webtoon_zh",
			manga:      models.Manga{Title: "StripZH", Viewer: models.ViewerUnknown, Tags: []string{"条漫"}},
			wantViewer: models.ViewerWebtoon,
			wantFormat: "Webtoon",
		},
		{
			name:       "unknown_no_webtoon_tag",
			manga:      models.Manga{Title: "Unknown", Viewer: models.ViewerUnknown, Tags: []string{"Fantasy", "Comedy"}},
			wantViewer: models.ViewerUnknown,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := EffectiveViewer(tt.manga); got != tt.wantViewer {
				t.Errorf("EffectiveViewer = %v, want %v", got, tt.wantViewer)
			}
			ci := buildComicInfo(tt.manga, models.Chapter{Key: "ch1"}, 12)
			if ci.Format != tt.wantFormat {
				t.Errorf("ComicInfo.Format = %q, want %q", ci.Format, tt.wantFormat)
			}
			if ci.Manga != tt.wantManga {
				t.Errorf("ComicInfo.Manga = %q, want %q", ci.Manga, tt.wantManga)
			}
			xmlBytes, err := ci.Marshal()
			if err != nil {
				t.Fatalf("Marshal: %v", err)
			}
			xmlStr := string(xmlBytes)
			if tt.wantFormat != "" && !strings.Contains(xmlStr, "<Format>"+tt.wantFormat+"</Format>") {
				t.Errorf("marshaled XML missing <Format>%s</Format>: %s", tt.wantFormat, xmlStr)
			}
			if tt.wantFormat == "" && strings.Contains(xmlStr, "<Format>") {
				t.Errorf("marshaled XML unexpectedly contains <Format>: %s", xmlStr)
			}
			if tt.wantManga != "" && !strings.Contains(xmlStr, "<Manga>"+tt.wantManga+"</Manga>") {
				t.Errorf("marshaled XML missing <Manga>%s</Manga>: %s", tt.wantManga, xmlStr)
			}
			if tt.wantManga == "" && strings.Contains(xmlStr, "<Manga>") {
				t.Errorf("marshaled XML unexpectedly contains <Manga>: %s", xmlStr)
			}
		})
	}
}
