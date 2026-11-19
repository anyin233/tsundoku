package epub

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"encoding/xml"
	"fmt"
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

func TestVolumeForOrderAndRangeSuffix(t *testing.T) {
	cases := []struct {
		order int
		vol   int
		start int
		end   int
		suf   string
	}{
		{0, 1, 1, 50, " [0001-0050]"},
		{1, 1, 1, 50, " [0001-0050]"},
		{50, 1, 1, 50, " [0001-0050]"},
		{51, 2, 51, 100, " [0051-0100]"},
		{100, 2, 51, 100, " [0051-0100]"},
		{101, 3, 101, 150, " [0101-0150]"},
		{1028, 21, 1001, 1050, " [1001-1050]"},
	}
	for _, tc := range cases {
		vol, start, end := VolumeForOrder(tc.order, 0)
		if vol != tc.vol || start != tc.start || end != tc.end {
			t.Errorf("VolumeForOrder(%d, 0) = (%d,%d,%d), want (%d,%d,%d)",
				tc.order, vol, start, end, tc.vol, tc.start, tc.end)
		}
		if got := VolumeRangeSuffix(start, end); got != tc.suf {
			t.Errorf("VolumeRangeSuffix(%d,%d) = %q, want %q", start, end, got, tc.suf)
		}
	}
}

func TestSplitToVolumesAndSyncBookIndex(t *testing.T) {
	dir := t.TempDir()
	legacyPath := filepath.Join(dir, "长篇小说.epub")
	meta := BookMeta{
		SourceKey: "zh.biquge",
		MangaKey:  "/book/999/",
		Title:     "长篇小说",
		Authors:   []string{"测试作者"},
		Language:  "zh",
	}

	const totalCh = 125
	inputs := make([]ChapterInput, totalCh)
	canonical := make([]string, totalCh)
	for i := 0; i < totalCh; i++ {
		k := fmt.Sprintf("/book/999/%d.html", i+1)
		canonical[i] = k
		inputs[i] = ChapterInput{
			Key:           k,
			Title:         fmt.Sprintf("第%d章 章节标题%d", i+1, i+1),
			Text:          fmt.Sprintf("第%d章正文第一段。\n第%d章正文第二段。", i+1, i+1),
			ChapterNumber: f32p(float32(i + 1)),
			TOCOrder:      i + 1,
		}
	}
	if _, err := UpsertChapters(legacyPath, meta, inputs, canonical); err != nil {
		t.Fatalf("UpsertChapters legacy: %v", err)
	}

	// Write adjacent legacy .sdr pointing to chapter 73 (Vol 2, FragIndex 23) + bookmark on chapter 75 (FragIndex 25)
	legacySDRDir := filepath.Join(dir, "长篇小说.sdr")
	if err := os.MkdirAll(legacySDRDir, 0o755); err != nil {
		t.Fatal(err)
	}
	legacySDR := `return {
    ["copt_font_size"] = 24,
    ["doc_pages"] = 500,
    ["doc_path"] = "/mnt/us/legacy.epub",
    ["font_face"] = "Noto Sans CJK SC",
    ["last_xpointer"] = "/body/DocFragment[73]/body/p[2]/text().0",
    ["partial_md5_checksum"] = "deadbeef",
    ["percent_finished"] = 0.58,
    ["readingloc_anchor"] = 42,
    ["bookmarks"] = {
        [1] = {
            ["page"] = "/body/DocFragment[75]/body/p[1]/text().0",
        },
    },
}
`
	if err := os.WriteFile(filepath.Join(legacySDRDir, "metadata.epub.lua"), []byte(legacySDR), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := SplitToVolumes(legacyPath, 50, canonical)
	if err != nil {
		t.Fatalf("SplitToVolumes: %v", err)
	}
	if res.AlreadySharded || res.TotalChapters != totalCh || len(res.Volumes) != 3 {
		t.Fatalf("unexpected SplitResult: %+v", res)
	}
	if res.ActiveChapter != "/book/999/73.html" {
		t.Fatalf("ActiveChapter = %q, want /book/999/73.html", res.ActiveChapter)
	}
	wantVol2Path := filepath.Join(dir, "长篇小说 [0051-0100].epub")
	if res.ActivePath != wantVol2Path {
		t.Fatalf("ActivePath = %q, want %q", res.ActivePath, wantVol2Path)
	}

	// Legacy files must be removed
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("expected legacy epub removed, err=%v", err)
	}
	if _, err := os.Stat(legacySDRDir); !os.IsNotExist(err) {
		t.Fatalf("expected legacy sdr removed, err=%v", err)
	}

	// Verify volume manifests, OPF identifiers, and titles
	wantCounts := []int{50, 50, 25}
	wantRanges := [][2]int{{1, 50}, {51, 100}, {101, 150}}
	ids := make(map[string]bool)
	for i, v := range res.Volumes {
		m, err := ReadManifest(v.Path)
		if err != nil {
			t.Fatalf("ReadManifest vol %d: %v", i+1, err)
		}
		if len(m.Chapters) != wantCounts[i] {
			t.Fatalf("vol %d chapters = %d, want %d", i+1, len(m.Chapters), wantCounts[i])
		}
		if m.VolumeIndex != i+1 || m.VolumeStart != wantRanges[i][0] || m.VolumeEnd != wantRanges[i][1] || m.VolumeSize != 50 {
			t.Fatalf("vol %d manifest volume fields = %+v", i+1, m)
		}
		id := bookIdentifier(m)
		if ids[id] {
			t.Fatalf("duplicate volume identifier %q", id)
		}
		ids[id] = true
		opf, _ := readZipEntry(t, v.Path, "OEBPS/content.opf")
		wantTitle := fmt.Sprintf("<dc:title>长篇小说 (%d-%d)</dc:title>", wantRanges[i][0], wantRanges[i][1])
		if !strings.Contains(opf, wantTitle) {
			t.Fatalf("vol %d OPF missing %s:\n%s", i+1, wantTitle, opf)
		}
	}

	// Verify migrated .sdr on Vol 2
	vol2SDRBytes, err := os.ReadFile(filepath.Join(dir, "长篇小说 [0051-0100].sdr", "metadata.epub.lua"))
	if err != nil {
		t.Fatalf("read migrated vol2 sdr: %v", err)
	}
	vol2SDR := string(vol2SDRBytes)
	if !strings.Contains(vol2SDR, `"/body/DocFragment[23]/body/p[2]/text().0"`) {
		t.Fatalf("expected last_xpointer remapped 73->23, got:\n%s", vol2SDR)
	}
	if !strings.Contains(vol2SDR, `"/body/DocFragment[25]/body/p[1]/text().0"`) {
		t.Fatalf("expected bookmark remapped 75->25, got:\n%s", vol2SDR)
	}
	if !strings.Contains(vol2SDR, `["font_face"] = "Noto Sans CJK SC"`) || !strings.Contains(vol2SDR, `["copt_font_size"] = 24`) {
		t.Fatalf("expected typography settings preserved, got:\n%s", vol2SDR)
	}
	for _, stale := range []string{"doc_pages", "doc_path", "partial_md5_checksum", "percent_finished", "readingloc_anchor"} {
		if strings.Contains(vol2SDR, stale) {
			t.Fatalf("expected stale key %q stripped from migrated sdr, got:\n%s", stale, vol2SDR)
		}
	}

	// Verify .tsundoku_book.json
	idxData, err := os.ReadFile(filepath.Join(dir, BookIndexFilename))
	if err != nil {
		t.Fatalf("read %s: %v", BookIndexFilename, err)
	}
	var bookIdx BookIndex
	if err := json.Unmarshal(idxData, &bookIdx); err != nil {
		t.Fatalf("decode %s: %v", BookIndexFilename, err)
	}
	if len(bookIdx.Volumes) != 3 || bookIdx.Title != "长篇小说" || bookIdx.VolumeSize != 50 {
		t.Fatalf("unexpected BookIndex: %+v", bookIdx)
	}
	if bookIdx.Volumes[1].Chapters[22].Key != "/book/999/73.html" || bookIdx.Volumes[1].Chapters[22].FragIndex != 23 {
		t.Fatalf("unexpected Vol 2 ch 23 entry: %+v", bookIdx.Volumes[1].Chapters[22])
	}

	// Splitting an already-sharded volume is a no-op
	again, err := SplitToVolumes(res.Volumes[0].Path, 50, canonical)
	if err != nil || !again.AlreadySharded {
		t.Fatalf("SplitToVolumes on sharded volume = (%+v, %v), want AlreadySharded=true", again, err)
	}

	// SyncBookIndex removes .tsundoku_book.json once all EPUBs are gone
	for _, v := range res.Volumes {
		_ = os.Remove(v.Path)
	}
	emptyIdx, err := SyncBookIndex(dir)
	if err != nil || emptyIdx != nil {
		t.Fatalf("SyncBookIndex on empty dir = (%+v, %v), want nil, nil", emptyIdx, err)
	}
	if _, err := os.Stat(filepath.Join(dir, BookIndexFilename)); !os.IsNotExist(err) {
		t.Fatalf("expected %s removed when no EPUBs remain, err=%v", BookIndexFilename, err)
	}
}
