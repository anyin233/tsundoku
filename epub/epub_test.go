package epub

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func f32p(v float32) *float32 { return &v }

func readZipEntry(t *testing.T, epubPath, name string) (string, uint16) {
	t.Helper()
	zr, err := zip.OpenReader(epubPath)
	if err != nil {
		t.Fatalf("open epub %s: %v", epubPath, err)
	}
	defer zr.Close()
	for _, f := range zr.File {
		if f.Name == name {
			rc, err := f.Open()
			if err != nil {
				t.Fatalf("open entry %s: %v", name, err)
			}
			b, err := io.ReadAll(rc)
			rc.Close()
			if err != nil {
				t.Fatalf("read entry %s: %v", name, err)
			}
			return string(b), f.Method
		}
	}
	t.Fatalf("entry %s not found in %s", name, epubPath)
	return "", 0
}

func TestUpsertAppendPreInsertAndRemove(t *testing.T) {
	dir := t.TempDir()
	epubPath := filepath.Join(dir, "凡人修仙传.epub")
	meta := BookMeta{
		SourceKey:   "zh.biquge",
		MangaKey:    "/book/123/",
		Title:       "凡人修仙传",
		Authors:     []string{"忘语"},
		Description: "一个普通山村穷小子 & 仙侠传奇",
		Language:    "zh",
	}

	// 1. Create initial 1-chapter EPUB
	res, err := UpsertChapters(epubPath, meta, []ChapterInput{
		{
			Key:           "/book/123/1.html",
			Title:         "第一章 山边小村",
			Text:          "第一章 山边小村\n\n　　二愣子睁大着双眼。\n\n　　村口老槐树下。",
			ChapterNumber: f32p(1),
			TOCOrder:      1,
		},
	}, nil)
	if err != nil {
		t.Fatalf("initial UpsertChapters: %v", err)
	}
	if res.TotalChapters != 1 || res.SpineShifted {
		t.Fatalf("unexpected initial result: %+v", res)
	}

	// Verify uncompressed mimetype as first entry at byte offset 30+8
	raw, err := os.ReadFile(epubPath)
	if err != nil {
		t.Fatalf("read epub raw: %v", err)
	}
	if len(raw) < 58 || string(raw[30:38]) != "mimetype" || string(raw[38:58]) != "application/epub+zip" {
		t.Fatalf("mimetype header/payload not stored uncompressed at start of EPUB")
	}

	// Verify all entries use zip.Store and XML parses cleanly
	zr, err := zip.OpenReader(epubPath)
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	for _, f := range zr.File {
		if f.Method != zip.Store {
			t.Errorf("entry %s method = %d, want zip.Store (%d)", f.Name, f.Method, zip.Store)
		}
	}
	zr.Close()

	opf, _ := readZipEntry(t, epubPath, "OEBPS/content.opf")
	if err := xml.Unmarshal([]byte(opf), new(any)); err != nil {
		t.Fatalf("invalid OPF XML: %v\n%s", err, opf)
	}
	ncx, _ := readZipEntry(t, epubPath, "OEBPS/toc.ncx")
	if err := xml.Unmarshal([]byte(ncx), new(any)); err != nil {
		t.Fatalf("invalid NCX XML: %v\n%s", err, ncx)
	}

	m1, err := ReadManifest(epubPath)
	if err != nil {
		t.Fatalf("ReadManifest: %v", err)
	}
	ch1Body, _ := readZipEntry(t, epubPath, "OEBPS/"+m1.Chapters[0].Href)
	if strings.Count(ch1Body, "第一章 山边小村") != 2 { // <title> and <h2>, stripped duplicate first paragraph
		t.Fatalf("expected duplicate leading chapter title stripped from paragraphs, got:\n%s", ch1Body)
	}
	if !strings.Contains(ch1Body, "<p>二愣子睁大着双眼。</p>") {
		t.Fatalf("expected trimmed paragraph in XHTML, got:\n%s", ch1Body)
	}

	// 2. Append chapters 2 & 3 -> SpineShifted must be false
	res2, err := UpsertChapters(epubPath, meta, []ChapterInput{
		{Key: "/book/123/2.html", Title: "第二章 青牛镇", Text: "第二章正文", ChapterNumber: f32p(2), TOCOrder: 2},
		{Key: "/book/123/3.html", Title: "第三章 七玄门", Text: "第三章正文", ChapterNumber: f32p(3), TOCOrder: 3},
	}, []string{"/book/123/1.html", "/book/123/2.html", "/book/123/3.html"})
	if err != nil {
		t.Fatalf("append UpsertChapters: %v", err)
	}
	if res2.TotalChapters != 3 || res2.SpineShifted {
		t.Fatalf("append should keep SpineShifted=false, got %+v", res2)
	}
	ch1BodyAfter, _ := readZipEntry(t, epubPath, "OEBPS/"+m1.Chapters[0].Href)
	if ch1BodyAfter != ch1Body {
		t.Fatalf("raw copy altered ch1 content")
	}

	// Write adjacent .sdr metadata pointing to DocFragment[1] (chapter 1) and bookmark in chapter 3
	sdrFile := filepath.Join(dir, "凡人修仙传.sdr", "metadata.epub.lua")
	if err := os.MkdirAll(filepath.Dir(sdrFile), 0o755); err != nil {
		t.Fatalf("mkdir sdr: %v", err)
	}
	initialLua := `return {
    ["last_xpointer"] = "/body/DocFragment[1]/body/p[1]/text().0",
    ["bookmarks"] = {
        [1] = {
            ["page"] = "/body/DocFragment[3]/body/p[1]/text().0",
        },
    },
}
`
	if err := os.WriteFile(sdrFile, []byte(initialLua), 0o644); err != nil {
		t.Fatalf("write sdr: %v", err)
	}

	// 3. Out-of-order pre-insert chapter 0 ("序章") -> SpineShifted=true and .sdr remapped!
	canonical := []string{"/book/123/0.html", "/book/123/1.html", "/book/123/2.html", "/book/123/3.html"}
	res3, err := UpsertChapters(epubPath, meta, []ChapterInput{
		{Key: "/book/123/0.html", Title: "序章", Text: "序章内容", ChapterNumber: f32p(0.5)},
	}, canonical)
	if err != nil {
		t.Fatalf("pre-insert UpsertChapters: %v", err)
	}
	if res3.TotalChapters != 4 || !res3.SpineShifted || !res3.SDRRemapped {
		t.Fatalf("expected SpineShifted & SDRRemapped, got %+v", res3)
	}
	if got := strings.Join(res3.NewKeys, ","); got != strings.Join(canonical, ",") {
		t.Fatalf("order mismatch: got %s, want %s", got, strings.Join(canonical, ","))
	}
	sdrUpdated, err := os.ReadFile(sdrFile)
	if err != nil {
		t.Fatalf("read sdr: %v", err)
	}
	if !strings.Contains(string(sdrUpdated), `"/body/DocFragment[2]/body/p[1]/text().0"`) ||
		!strings.Contains(string(sdrUpdated), `"/body/DocFragment[4]/body/p[1]/text().0"`) {
		t.Fatalf("expected .sdr xpointers shifted +1, got:\n%s", string(sdrUpdated))
	}

	// 4. Verify flat toc.ncx matches original reading order
	ncx3, _ := readZipEntry(t, epubPath, "OEBPS/toc.ncx")
	idx0 := strings.Index(ncx3, "序章")
	idx1 := strings.Index(ncx3, "第一章 山边小村")
	idx2 := strings.Index(ncx3, "第二章 青牛镇")
	idx3 := strings.Index(ncx3, "第三章 七玄门")
	if !(idx0 > 0 && idx0 < idx1 && idx1 < idx2 && idx2 < idx3) {
		t.Fatalf("toc.ncx not in original reading order:\n%s", ncx3)
	}

	// 5. Remove middle chapter 2 -> 3 chapters remain, bookmark on chapter 3 shifts 4 -> 3
	remRes, err := RemoveChapters(epubPath, []string{"/book/123/2.html"})
	if err != nil {
		t.Fatalf("RemoveChapters: %v", err)
	}
	if remRes.TotalChapters != 3 || !remRes.SDRRemapped {
		t.Fatalf("unexpected remove result: %+v", remRes)
	}
	sdrAfterRem, _ := os.ReadFile(sdrFile)
	if !strings.Contains(string(sdrAfterRem), `"/body/DocFragment[3]/body/p[1]/text().0"`) {
		t.Fatalf("expected bookmark shifted from 4 to 3, got:\n%s", string(sdrAfterRem))
	}

	// 6. Remove remaining chapters -> deletes EPUB and .sdr
	remAll, err := RemoveChapters(epubPath, []string{"/book/123/0.html", "/book/123/1.html", "/book/123/3.html"})
	if err != nil {
		t.Fatalf("RemoveChapters all: %v", err)
	}
	if remAll.TotalChapters != 0 {
		t.Fatalf("expected 0 chapters remaining, got %d", remAll.TotalChapters)
	}
	if _, err := os.Stat(epubPath); !os.IsNotExist(err) {
		t.Fatalf("expected epub deleted when empty, stat err = %v", err)
	}
	if _, err := os.Stat(filepath.Dir(sdrFile)); !os.IsNotExist(err) {
		t.Fatalf("expected adjacent .sdr deleted when empty, stat err = %v", err)
	}

	// Verify XPointer single-fragment & deleted-chapter fallback edge cases
	if got := RemapXPointerString("/body/DocFragment/body/p[2]/text().0", []string{"a"}, []string{"x", "a"}); got != "/body/DocFragment[2]/body/p[2]/text().0" {
		t.Fatalf("single fragment remap = %q", got)
	}
	if got := RemapXPointerString("/body/DocFragment[2]/body/p[2]/text().0", []string{"a", "b", "c"}, []string{"a", "c"}); got != "/body/DocFragment[2]/body" {
		t.Fatalf("deleted chapter remap = %q", got)
	}
}

func TestRenderChapterXHTMLStripsInvalidXMLChars(t *testing.T) {
	out := RenderChapterXHTML("测试\x00标题 & <1>", "第一段\x0b继续\n第二段\"引号\"")
	if err := xml.Unmarshal(bytes.TrimSpace(out), new(any)); err != nil {
		t.Fatalf("invalid XHTML: %v\n%s", err, string(out))
	}
}
