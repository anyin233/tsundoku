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

	"github.com/ohaiibuzzle/aidokurunner-go/downloads"
	"github.com/ohaiibuzzle/aidokurunner-go/epub"
	"github.com/ohaiibuzzle/aidokurunner-go/models"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime"
	"github.com/ohaiibuzzle/aidokurunner-go/settingsstore"
	"github.com/ohaiibuzzle/aidokurunner-go/source"
	"golang.org/x/text/encoding/simplifiedchinese"
)

func toGBK(t *testing.T, s string) []byte {
	t.Helper()
	b, err := simplifiedchinese.GB18030.NewEncoder().Bytes([]byte(s))
	if err != nil {
		t.Fatalf("encode GBK: %v", err)
	}
	return b
}

func TestBiqugeSourceEndToEndEPUBWorkflow(t *testing.T) {
	aixPath := filepath.Join("..", "..", "koreader", "aidoku.koplugin", "builtin_sources", "biquge-v1.aix")
	if _, err := os.Stat(aixPath); err != nil {
		t.Skipf("biquge-v1.aix not built yet (%v); skipping integration test", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=gbk")
		_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><head><meta charset="gbk"><title>笔趣阁测试</title></head><body>
			<form action="/search.php" method="post" accept-charset="gbk">
				<input type="text" name="keyword" />
				<input type="hidden" name="type" value="articlename" />
			</form>
			<div id="hotcontent"><div class="item"><dl><dt><a href="/book/100/">斗破苍穹</a></dt><dd>天才少年。</dd></dl></div></div>
		</body></html>`))
	})

	mux.HandleFunc("/search.php", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		bodyStr := string(body)
		// Verify GBK encoding of "斗破" (%B6%B7%C6%C6)
		if strings.Contains(bodyStr, "%B6%B7%C6%C6") {
			w.Header().Set("Content-Type", "text/html; charset=gbk")
			_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><head><meta charset="gbk"></head><body>
				<table class="grid">
					<tr><th>书名</th><th>最新</th><th>作者</th></tr>
					<tr><td><a href="/book/100/">斗破苍穹</a></td><td>第四章</td><td>天蚕土豆</td></tr>
				</table>
			</body></html>`))
			return
		}
		// Exact-hit 302 redirect simulation
		if strings.Contains(bodyStr, "exact") {
			http.Redirect(w, r, "/book/100/", http.StatusFound)
			return
		}
		http.Error(w, "unexpected query: "+bodyStr, http.StatusBadRequest)
	})

	mux.HandleFunc("/book/100/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=gbk")
		_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><head>
			<meta charset="gbk">
			<meta property="og:novel:book_name" content="斗破苍穹">
			<meta property="og:novel:author" content="天蚕土豆">
			<meta property="og:novel:status" content="连载中">
			<meta property="og:novel:category" content="玄幻">
			<meta property="og:description" content="三十年河东，三十年河西。">
		</head><body>
			<div id="info"><h1>斗破苍穹</h1></div>
			<div id="list"><dl>
				<dt>《斗破苍穹》最新章节</dt>
				<dd><a href="/book/100/104.html">第四章 测试四</a></dd>
				<dd><a href="/book/100/103.html">第三章 测试三</a></dd>
				<dt>《斗破苍穹》正文</dt>
				<dd><a href="/book/100/101.html">第一章 陨落的天才</a></dd>
				<dd><a href="/book/100/102.html">第二章 斗之气</a></dd>
				<dd><a href="/book/100/103.html">第三章 测试三</a></dd>
				<dd><a href="/book/100/104.html">第四章 测试四</a></dd>
			</dl></div>
		</body></html>`))
	})

	mux.HandleFunc("/book/100/101.html", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=gbk")
		_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><head><meta charset="gbk"></head><body>
			<div id="content">
				一秒记住【笔趣阁 www.test.cc】，无弹窗免费阅读！<br/>
				第一章 陨落的天才<br/>
				　　“斗之力，三段！”<br/>
				（本章未完，请点击下一页继续阅读）
				<script>console.log("ad")</script>
				<div class="bottem"><a href="/book/100/101_2.html">下一页</a></div>
			</div>
		</body></html>`))
	})

	mux.HandleFunc("/book/100/101_2.html", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=gbk")
		_, _ = w.Write(toGBK(t, `<!DOCTYPE html><html><head><meta charset="gbk"></head><body>
			<div id="content">
				　　少年紧握双拳，目光倔强。<br/>
			</div>
			<a href="/book/100/102.html">下一章</a>
		</body></html>`))
	})

	for _, ep := range []struct {
		path string
		body string
	}{
		{"/book/100/102.html", `<div id="content">第二章正文段落。</div>`},
		{"/book/100/103.html", `<div id="content">第三章正文段落。</div>`},
		{"/book/100/104.html", `<div id="content">第四章正文段落。</div>`},
	} {
		ep := ep
		mux.HandleFunc(ep.path, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<!DOCTYPE html><html><body>` + ep.body + `</body></html>`))
		})
	}

	srv := httptest.NewServer(mux)
	defer srv.Close()

	workDir := t.TempDir()
	settingsDir := filepath.Join(workDir, "settings")
	downloadsDir := filepath.Join(workDir, "downloads")
	if err := os.MkdirAll(settingsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	settings, err := settingsstore.Open(filepath.Join(settingsDir, "settings.json"))
	if err != nil {
		t.Fatalf("settingsstore.Open: %v", err)
	}
	if err := settings.SetValue("zh.biquge.mirror_url", srv.URL); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	src, err := source.LoadPath(ctx, aixPath, runtime.Config{Settings: settings}, settings)
	if err != nil {
		t.Fatalf("LoadPath: %v", err)
	}
	defer src.Runner.Close(ctx)

	// 1. Search (GBK form auto-discovery)
	q := "斗破"
	sres, err := src.GetSearchMangaList(ctx, &q, 1, nil)
	if err != nil {
		t.Fatalf("GetSearchMangaList(斗破): %v", err)
	}
	if len(sres.Entries) != 1 || sres.Entries[0].Key != "/book/100/" || sres.Entries[0].Title != "斗破苍穹" {
		t.Fatalf("unexpected search results: %+v", sres.Entries)
	}

	// 2. Search 302 redirect exact hit
	qExact := "exact"
	sresExact, err := src.GetSearchMangaList(ctx, &qExact, 1, nil)
	if err != nil {
		t.Fatalf("GetSearchMangaList(exact 302): %v", err)
	}
	if len(sresExact.Entries) != 1 || sresExact.Entries[0].Key != "/book/100/" {
		t.Fatalf("unexpected 302 search result: %+v", sresExact.Entries)
	}

	// 3. Book update + TOC deduplication (preview stripped, newest first in Aidoku)
	manga, err := src.GetMangaUpdate(ctx, models.Manga{Key: "/book/100/"}, true, true, nil)
	if err != nil {
		t.Fatalf("GetMangaUpdate: %v", err)
	}
	if len(manga.Chapters) != 4 {
		t.Fatalf("expected 4 deduped chapters, got %d: %+v", len(manga.Chapters), manga.Chapters)
	}
	// Aidoku convention: newest first; canonical reading order reverses back to 1..4
	canonical := source.CanonicalReadingKeys(manga.Chapters)
	wantKeys := []string{"/book/100/101.html", "/book/100/102.html", "/book/100/103.html", "/book/100/104.html"}
	if strings.Join(canonical, ",") != strings.Join(wantKeys, ",") {
		t.Fatalf("CanonicalReadingKeys = %v, want %v", canonical, wantKeys)
	}

	// 4. Batch download chapters 1 & 2 into single EPUB
	mangaDir := "斗破苍穹 [zh.biquge]"
	if err := executeBatchDownload(ctx, src, aixPath, downloadBatchPayload{
		Manga:         *manga,
		Chapters:      []models.Chapter{manga.Chapters[3], manga.Chapters[2]}, // Ch 1, Ch 2
		CanonicalKeys: canonical,
		DownloadsDir:  downloadsDir,
		MangaDirName:  mangaDir,
	}); err != nil {
		t.Fatalf("executeBatchDownload (ch 1-2): %v", err)
	}

	epubPath := filepath.Join(downloadsDir, mangaDir, "斗破苍穹.epub")
	manifest1, err := epub.ReadManifest(epubPath)
	if err != nil {
		t.Fatalf("ReadManifest after batch 1: %v", err)
	}
	if len(manifest1.Chapters) != 2 || manifest1.Chapters[0].Key != "/book/100/101.html" || manifest1.Chapters[1].Key != "/book/100/102.html" {
		t.Fatalf("unexpected manifest1 chapters: %+v", manifest1.Chapters)
	}

	// Check stitched subpage content in chapter 1 XHTML
	zr, err := zip.OpenReader(epubPath)
	if err != nil {
		t.Fatal(err)
	}
	var ch1XHTML string
	for _, f := range zr.File {
		if f.Method != zip.Store {
			t.Errorf("entry %s not stored uncompressed", f.Name)
		}
		if f.Name == "OEBPS/"+manifest1.Chapters[0].Href {
			rc, _ := f.Open()
			b, _ := io.ReadAll(rc)
			rc.Close()
			ch1XHTML = string(b)
		}
	}
	zr.Close()
	if !strings.Contains(ch1XHTML, "“斗之力，三段！”") || !strings.Contains(ch1XHTML, "少年紧握双拳，目光倔强。") {
		t.Fatalf("expected stitched ch1+ch1_2 paragraphs, got:\n%s", ch1XHTML)
	}
	if strings.Contains(ch1XHTML, "一秒记住") || strings.Contains(ch1XHTML, "本章未完") || strings.Contains(ch1XHTML, "下一页") {
		t.Fatalf("expected ad and pagination lines stripped, got:\n%s", ch1XHTML)
	}

	// 5. Incrementally append chapters 3 & 4
	if err := executeBatchDownload(ctx, src, aixPath, downloadBatchPayload{
		Manga:         *manga,
		Chapters:      []models.Chapter{manga.Chapters[1], manga.Chapters[0]}, // Ch 3, Ch 4
		CanonicalKeys: canonical,
		DownloadsDir:  downloadsDir,
		MangaDirName:  mangaDir,
	}); err != nil {
		t.Fatalf("executeBatchDownload (ch 3-4): %v", err)
	}

	manifest2, err := epub.ReadManifest(epubPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(manifest2.Chapters) != 4 {
		t.Fatalf("expected 4 chapters after append, got %d", len(manifest2.Chapters))
	}

	// Verify deduplicated TotalBytes == single epub file size
	store, err := downloads.Open(downloadsDir)
	if err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(epubPath)
	if err != nil {
		t.Fatal(err)
	}
	totalBytes, err := store.TotalBytes()
	store.Close()
	if err != nil || totalBytes != fi.Size() {
		t.Fatalf("TotalBytes = %d, want single epub size %d (err=%v)", totalBytes, fi.Size(), err)
	}

	// 6. Write .sdr sidecar pointing to Ch 4 (DocFragment[4]), then remove Ch 2 via epub-remove
	sdrPath := filepath.Join(downloadsDir, mangaDir, "斗破苍穹.sdr", "metadata.epub.lua")
	_ = os.MkdirAll(filepath.Dir(sdrPath), 0o755)
	_ = os.WriteFile(sdrPath, []byte(`return { ["last_xpointer"] = "/body/DocFragment[4]/body/p[1]/text().0" }`), 0o644)

	remPayloadPath := filepath.Join(workDir, "remove.json")
	remBytes, _ := json.Marshal(epubRemovePayload{
		EPUBPath:     epubPath,
		DownloadsDir: downloadsDir,
		SourceKey:    "zh.biquge",
		MangaKey:     "/book/100/",
		ChapterKeys:  []string{"/book/100/102.html"},
	})
	_ = os.WriteFile(remPayloadPath, remBytes, 0o644)
	if err := handleEpubRemove(ctx, []string{remPayloadPath}); err != nil {
		t.Fatalf("handleEpubRemove: %v", err)
	}

	manifest3, err := epub.ReadManifest(epubPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(manifest3.Chapters) != 3 || manifest3.Chapters[1].Key != "/book/100/103.html" {
		t.Fatalf("expected [101, 103, 104], got %+v", manifest3.Chapters)
	}
	sdrAfter, _ := os.ReadFile(sdrPath)
	if !strings.Contains(string(sdrAfter), `/body/DocFragment[3]/body/p[1]/text().0`) {
		t.Fatalf("expected .sdr DocFragment shifted 4->3 after removing ch2, got:\n%s", string(sdrAfter))
	}
}
