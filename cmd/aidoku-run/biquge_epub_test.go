package main

import (
	"archive/zip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
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

	epubPath := filepath.Join(downloadsDir, mangaDir, "斗破苍穹 [0001-0050].epub")
	manifest1, err := epub.ReadManifest(epubPath)
	if err != nil {
		t.Fatalf("ReadManifest after batch 1: %v", err)
	}
	if len(manifest1.Chapters) != 2 || manifest1.Chapters[0].Key != "/book/100/101.html" || manifest1.Chapters[1].Key != "/book/100/102.html" {
		t.Fatalf("unexpected manifest1 chapters: %+v", manifest1.Chapters)
	}
	if manifest1.VolumeIndex != 1 || manifest1.VolumeStart != 1 || manifest1.VolumeEnd != 50 {
		t.Fatalf("unexpected manifest1 volume metadata: %+v", manifest1)
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

	// 5. Incrementally append chapters 3 & 4 passing OutputPath: epubPath +
	// MangaDirName (matching KOReader Lua's incremental download payload).
	if err := executeBatchDownload(ctx, src, aixPath, downloadBatchPayload{
		Manga:         *manga,
		Chapters:      []models.Chapter{manga.Chapters[1], manga.Chapters[0]}, // Ch 3, Ch 4
		CanonicalKeys: canonical,
		OutputPath:    epubPath,
		DownloadsDir:  downloadsDir,
		MangaDirName:  mangaDir,
	}); err != nil {
		t.Fatalf("executeBatchDownload (ch 3-4): %v", err)
	}

	var epubFiles []string
	if err := filepath.WalkDir(downloadsDir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.EqualFold(filepath.Ext(d.Name()), ".epub") {
			epubFiles = append(epubFiles, path)
		}
		return err
	}); err != nil {
		t.Fatalf("WalkDir(downloadsDir): %v", err)
	}
	if len(epubFiles) != 1 || epubFiles[0] != epubPath {
		t.Fatalf("expected strictly 1 epub at %q, found %v", epubPath, epubFiles)
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
	sdrPath := filepath.Join(downloadsDir, mangaDir, "斗破苍穹 [0001-0050].sdr", "metadata.epub.lua")
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

func TestBiqugeMultiMirrorFallbackAndMiddleChapterOrder(t *testing.T) {
	aixPath := filepath.Join("..", "..", "koreader", "aidoku.koplugin", "builtin_sources", "biquge-v1.aix")
	if _, err := os.Stat(aixPath); err != nil {
		t.Skipf("biquge-v1.aix not built yet (%v); skipping integration test", err)
	}

	// Primary mirror serves TOC and Ch2 & Ch4 (#content .text), but fails Ch1 & Ch3 (HTTP 500).
	primaryMux := http.NewServeMux()
	primaryMux.HandleFunc("/book/200/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><head>
			<meta property="og:novel:book_name" content="测试多镜像小说">
			<meta property="og:novel:author" content="测试作者">
		</head><body>
			<div id="list"><dl>
				<dt>正文</dt>
				<dd><a href="/book/200/1.html">001 第一章 开端</a></dd>
				<dd><a href="/book/200/2.html">002 第二章 推进</a></dd>
				<dd><a href="/book/200/3.html">003 第三章 转折</a></dd>
				<dd><a href="/book/200/4.html">004 第四章 终章</a></dd>
			</dl></div>
		</body></html>`))
	})
	primaryMux.HandleFunc("/book/200/1.html", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "primary error", http.StatusInternalServerError)
	})
	primaryMux.HandleFunc("/book/200/2.html", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><body><div id="content"><div class="text"><p>主站第二章正文。</p></div></div></body></html>`))
	})
	primaryMux.HandleFunc("/book/200/3.html", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "primary error", http.StatusInternalServerError)
	})
	primaryMux.HandleFunc("/book/200/4.html", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><body><div id="content"><div class="text"><p>主站第四章正文。</p></div></div></body></html>`))
	})
	primarySrv := httptest.NewServer(primaryMux)
	defer primarySrv.Close()

	// Secondary independent mirror uses different URL scheme (/books/alt-id/chapters/N)
	// and .reader-prose HTML container with "第 N 章 ..." prefixed titles.
	altMux := http.NewServeMux()
	altMux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		q := r.URL.Query().Get("q")
		if q != "" {
			_, _ = w.Write([]byte(`<!DOCTYPE html><html><body>
				<form action="/" method="get"><input type="search" name="q"/></form>
				<a class="reader-book" href="/books/alt-id">
					<span class="reader-book-info"><strong>测试多镜像小说</strong><span>测试作者</span><p>简介</p></span>
				</a>
			</body></html>`))
			return
		}
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><body><form action="/" method="get"><input type="search" name="q"/></form></body></html>`))
	})
	altMux.HandleFunc("/books/alt-id", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><body>
			<div id="info"><h1>测试多镜像小说</h1></div>
			<div id="directory">
				<a href="/books/alt-id/chapters/1">第 1 章 001 第一章 开端</a>
				<a href="/books/alt-id/chapters/2">第 2 章 002 第二章 推进</a>
				<a href="?page=2#directory">下一页</a>
			</div>
		</body></html>`))
	})
	altMux.HandleFunc("/books/alt-id/chapters/1", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><body><div class="reader-prose"><p>备用镜像第一章正文。</p></div></body></html>`))
	})
	altMux.HandleFunc("/books/alt-id/chapters/3", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><body><div class="reader-prose"><p>备用镜像第三章正文。</p></div></body></html>`))
	})
	// Handle ?page=2 on /books/alt-id
	altHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/books/alt-id" && r.URL.Query().Get("page") == "2" {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<!DOCTYPE html><html><body>
				<div id="directory">
					<a href="/books/alt-id/chapters/3">第 3 章 003 第三章 转折</a>
					<a href="/books/alt-id/chapters/4">第 4 章 004 第四章 终章</a>
				</div>
			</body></html>`))
			return
		}
		altMux.ServeHTTP(w, r)
	})
	altSrv := httptest.NewServer(altHandler)
	defer altSrv.Close()

	workDir := t.TempDir()
	settingsDir := filepath.Join(workDir, "settings")
	downloadsDir := filepath.Join(workDir, "downloads")
	if err := os.MkdirAll(settingsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	settings, err := settingsstore.Open(filepath.Join(settingsDir, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	_ = settings.SetValue("zh.biquge.mirror_url", primarySrv.URL)
	_ = settings.SetValue("zh.biquge.mirror_fallback", true)
	_ = settings.SetValue("zh.biquge.fallback_mirrors", altSrv.URL)

	ctx := context.Background()
	src, err := source.LoadPath(ctx, aixPath, runtime.Config{Settings: settings}, settings)
	if err != nil {
		t.Fatalf("LoadPath: %v", err)
	}
	defer src.Runner.Close(ctx)

	manga, err := src.GetMangaUpdate(ctx, models.Manga{Key: "/book/200/"}, true, true, nil)
	if err != nil {
		t.Fatalf("GetMangaUpdate: %v", err)
	}
	canonical := source.CanonicalReadingKeys(manga.Chapters)
	if len(canonical) != 4 {
		t.Fatalf("expected 4 canonical chapters, got %v", canonical)
	}
	// Chapters in Aidoku are newest-first: [0]=Ch4, [1]=Ch3, [2]=Ch2, [3]=Ch1
	mangaDir := "测试多镜像小说 [zh.biquge]"

	// 1. Download Ch2 and Ch4 first (leaves Ch1 and Ch3 missing).
	if err := executeBatchDownload(ctx, src, aixPath, downloadBatchPayload{
		Manga:         *manga,
		Chapters:      []models.Chapter{manga.Chapters[2], manga.Chapters[0]}, // Ch2, Ch4
		CanonicalKeys: canonical,
		DownloadsDir:  downloadsDir,
		MangaDirName:  mangaDir,
	}); err != nil {
		t.Fatalf("initial partial batch (Ch2, Ch4): %v", err)
	}

	epubPath := filepath.Join(downloadsDir, mangaDir, "测试多镜像小说 [0001-0050].epub")
	sdrPath := filepath.Join(downloadsDir, mangaDir, "测试多镜像小说 [0001-0050].sdr", "metadata.epub.lua")
	_ = os.MkdirAll(filepath.Dir(sdrPath), 0o755)
	_ = os.WriteFile(sdrPath, []byte(`return { ["last_xpointer"] = "/body/DocFragment[2]/body" }`), 0o644)

	// 2. Download missing Ch1 and Ch3 (primary returns 500 -> must fallback to altSrv).
	if err := executeBatchDownload(ctx, src, aixPath, downloadBatchPayload{
		Manga:         *manga,
		Chapters:      []models.Chapter{manga.Chapters[3], manga.Chapters[1]}, // Ch1, Ch3
		CanonicalKeys: canonical,
		OutputPath:    epubPath,
		DownloadsDir:  downloadsDir,
		MangaDirName:  mangaDir,
	}); err != nil {
		t.Fatalf("fallback batch (Ch1, Ch3): %v", err)
	}

	manifest, err := epub.ReadManifest(epubPath)
	if err != nil {
		t.Fatal(err)
	}
	var gotKeys []string
	for _, ch := range manifest.Chapters {
		gotKeys = append(gotKeys, ch.Key)
	}
	wantOrder := strings.Join(canonical, ",")
	if strings.Join(gotKeys, ",") != wantOrder {
		t.Fatalf("EPUB spine order = %v, want canonical %v", gotKeys, canonical)
	}

	sdrAfter, err := os.ReadFile(sdrPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(sdrAfter), `/body/DocFragment[4]/body`) {
		t.Fatalf("expected .sdr DocFragment shifted 2->4 after pre+middle insertion, got:\n%s", string(sdrAfter))
	}

	// Verify fallback prose actually landed inside Ch1 & Ch3 XHTML entries.
	zr, err := zip.OpenReader(epubPath)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	for _, want := range []struct {
		href    string
		snippet string
	}{
		{manifest.Chapters[0].Href, "备用镜像第一章正文。"},
		{manifest.Chapters[2].Href, "备用镜像第三章正文。"},
	} {
		var body string
		for _, f := range zr.File {
			if f.Name == "OEBPS/"+want.href {
				rc, _ := f.Open()
				b, _ := io.ReadAll(rc)
				rc.Close()
				body = string(b)
			}
		}
		if !strings.Contains(body, want.snippet) {
			t.Fatalf("chapter %s missing fallback prose %q, got:\n%s", want.href, want.snippet, body)
		}
	}
}

func TestBiqugeMultiVolumeAndLegacySplit(t *testing.T) {
	aixPath := filepath.Join("..", "..", "koreader", "aidoku.koplugin", "builtin_sources", "biquge-v1.aix")
	if _, err := os.Stat(aixPath); err != nil {
		t.Skipf("biquge-v1.aix not built yet (%v); skipping integration test", err)
	}

	const totalCh = 65
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/book/300/" {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			var b strings.Builder
			b.WriteString(`<!DOCTYPE html><html><head><meta property="og:novel:book_name" content="分卷长篇小说"><meta property="og:novel:author" content="分卷作者"></head><body><div id="info"><h1>分卷长篇小说</h1></div><div id="list"><dl><dt>正文</dt>`)
			for i := 1; i <= totalCh; i++ {
				fmt.Fprintf(&b, `<dd><a href="/book/300/%d.html">第%d章 正文%d</a></dd>`, i, i, i)
			}
			b.WriteString(`</dl></div></body></html>`)
			_, _ = w.Write([]byte(b.String()))
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = fmt.Fprintf(w, `<!DOCTYPE html><html><body><div id="content"><p>章节内容 %s</p></div></body></html>`, r.URL.Path)
	})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	workDir := t.TempDir()
	settingsDir := filepath.Join(workDir, "settings")
	downloadsDir := filepath.Join(workDir, "downloads")
	_ = os.MkdirAll(settingsDir, 0o755)
	settings, err := settingsstore.Open(filepath.Join(settingsDir, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	_ = settings.SetValue("zh.biquge.mirror_url", srv.URL)

	ctx := context.Background()
	src, err := source.LoadPath(ctx, aixPath, runtime.Config{Settings: settings}, settings)
	if err != nil {
		t.Fatalf("LoadPath: %v", err)
	}
	defer src.Runner.Close(ctx)

	manga, err := src.GetMangaUpdate(ctx, models.Manga{Key: "/book/300/"}, true, true, nil)
	if err != nil {
		t.Fatalf("GetMangaUpdate: %v", err)
	}
	canonical := source.CanonicalReadingKeys(manga.Chapters)
	if len(canonical) != totalCh {
		t.Fatalf("expected %d canonical keys, got %d", totalCh, len(canonical))
	}

	// Build reading-order slice (chapters 1..60, crossing 50-chapter boundary)
	readingOrder := make([]models.Chapter, 0, totalCh)
	for i := len(manga.Chapters) - 1; i >= 0; i-- {
		readingOrder = append(readingOrder, manga.Chapters[i])
	}

	mangaDir := "分卷长篇小说 [zh.biquge]"
	if err := executeBatchDownload(ctx, src, aixPath, downloadBatchPayload{
		Manga:         *manga,
		Chapters:      readingOrder[:60],
		CanonicalKeys: canonical,
		DownloadsDir:  downloadsDir,
		MangaDirName:  mangaDir,
	}); err != nil {
		t.Fatalf("executeBatchDownload(1..60): %v", err)
	}

	bookDir := filepath.Join(downloadsDir, mangaDir)
	vol1Path := filepath.Join(bookDir, "分卷长篇小说 [0001-0050].epub")
	vol2Path := filepath.Join(bookDir, "分卷长篇小说 [0051-0100].epub")

	m1, err := epub.ReadManifest(vol1Path)
	if err != nil {
		t.Fatalf("ReadManifest vol1: %v", err)
	}
	m2, err := epub.ReadManifest(vol2Path)
	if err != nil {
		t.Fatalf("ReadManifest vol2: %v", err)
	}
	if len(m1.Chapters) != 50 || m1.VolumeIndex != 1 || m1.VolumeStart != 1 || m1.VolumeEnd != 50 {
		t.Fatalf("unexpected vol1 manifest: count=%d vol=%d [%d-%d]", len(m1.Chapters), m1.VolumeIndex, m1.VolumeStart, m1.VolumeEnd)
	}
	if len(m2.Chapters) != 10 || m2.VolumeIndex != 2 || m2.VolumeStart != 51 || m2.VolumeEnd != 100 {
		t.Fatalf("unexpected vol2 manifest: count=%d vol=%d [%d-%d]", len(m2.Chapters), m2.VolumeIndex, m2.VolumeStart, m2.VolumeEnd)
	}

	// Verify .tsundoku_book.json + SQLite routing + TotalBytes across volumes
	idxBytes, err := os.ReadFile(filepath.Join(bookDir, epub.BookIndexFilename))
	if err != nil {
		t.Fatalf("read %s: %v", epub.BookIndexFilename, err)
	}
	var bookIdx epub.BookIndex
	if err := json.Unmarshal(idxBytes, &bookIdx); err != nil {
		t.Fatalf("unmarshal %s: %v", epub.BookIndexFilename, err)
	}
	if len(bookIdx.Volumes) != 2 || len(bookIdx.Volumes[0].Chapters) != 50 || len(bookIdx.Volumes[1].Chapters) != 10 {
		t.Fatalf("unexpected bookIdx: %+v", bookIdx)
	}

	store, err := downloads.Open(downloadsDir)
	if err != nil {
		t.Fatal(err)
	}
	paths, err := store.BookEPUBPaths("zh.biquge", "/book/300/")
	if err != nil || len(paths) != 2 {
		t.Fatalf("BookEPUBPaths = (%v, %v), want 2 paths", paths, err)
	}
	if p1, _ := store.Path("zh.biquge", "/book/300/", "/book/300/1.html"); p1 != vol1Path {
		t.Fatalf("ch1 path = %q, want %q", p1, vol1Path)
	}
	if p55, _ := store.Path("zh.biquge", "/book/300/", "/book/300/55.html"); p55 != vol2Path {
		t.Fatalf("ch55 path = %q, want %q", p55, vol2Path)
	}
	fi1, _ := os.Stat(vol1Path)
	fi2, _ := os.Stat(vol2Path)
	totalBytes, _ := store.TotalBytes()
	store.Close()
	if totalBytes != fi1.Size()+fi2.Size() {
		t.Fatalf("TotalBytes = %d, want %d+%d=%d", totalBytes, fi1.Size(), fi2.Size(), fi1.Size()+fi2.Size())
	}

	// Test legacy monolithic EPUB auto-migration when appending chapter 61 via executeDownload
	legacyDir := t.TempDir()
	legacyDLDir := filepath.Join(legacyDir, "downloads")
	legacyBookDir := filepath.Join(legacyDLDir, mangaDir)
	legacyPath := filepath.Join(legacyBookDir, "分卷长篇小说.epub")
	legacyInputs := make([]epub.ChapterInput, 55)
	var legacyRecs []downloads.BookChapterRecord
	for i := 0; i < 55; i++ {
		ch := readingOrder[i]
		legacyInputs[i] = source.BuildChapterInput(ch, "旧正文", i+1)
		legacyRecs = append(legacyRecs, downloads.BookChapterRecord{
			ChapterKey:   ch.Key,
			ChapterTitle: source.ChapterLabel(ch),
		})
	}
	if _, err := epub.UpsertChapters(legacyPath, buildBookMetaWithSource(src, *manga), legacyInputs, canonical); err != nil {
		t.Fatalf("seed legacy epub: %v", err)
	}
	legacySDR := filepath.Join(legacyBookDir, "分卷长篇小说.sdr", "metadata.epub.lua")
	_ = os.MkdirAll(filepath.Dir(legacySDR), 0o755)
	_ = os.WriteFile(legacySDR, []byte(`return { ["last_xpointer"] = "/body/DocFragment[53]/body" }`), 0o644)
	legacyStore, err := downloads.Open(legacyDLDir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := legacyStore.RecordBookChapters("zh.biquge", aixPath, manga.Key, legacyPath, source.MangaLabel(*manga), legacyRecs, 0); err != nil {
		t.Fatal(err)
	}
	legacyStore.Close()

	// Appending ch 56 triggers maybeMigrateLegacyBookEPUBs automatically!
	if err := executeDownload(ctx, src, aixPath, *manga, readingOrder[55], "", legacyDLDir, mangaDir, false, false, canonical); err != nil {
		t.Fatalf("executeDownload after legacy seed: %v", err)
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("expected legacy monolithic EPUB deleted after auto-split, err=%v", err)
	}
	migratedVol2 := filepath.Join(legacyBookDir, "分卷长篇小说 [0051-0100].epub")
	mv2, err := epub.ReadManifest(migratedVol2)
	if err != nil {
		t.Fatalf("read migrated vol2: %v", err)
	}
	if len(mv2.Chapters) != 6 {
		t.Fatalf("expected 6 chapters (51..56) in migrated vol2, got %d", len(mv2.Chapters))
	}
	migratedSDR, err := os.ReadFile(filepath.Join(legacyBookDir, "分卷长篇小说 [0051-0100].sdr", "metadata.epub.lua"))
	if err != nil {
		t.Fatalf("read migrated vol2 sdr: %v", err)
	}
	if !strings.Contains(string(migratedSDR), `"/body/DocFragment[3]/body"`) {
		t.Fatalf("expected migrated sdr last_xpointer 53->3, got:\n%s", string(migratedSDR))
	}

	// Test standalone handleEpubSplit CLI handler on a second legacy file
	splitWorkDir := filepath.Join(legacyDir, "split_cli")
	splitBook := filepath.Join(splitWorkDir, "CLI拆卷.epub")
	if _, err := epub.UpsertChapters(splitBook, buildBookMetaWithSource(src, *manga), legacyInputs, canonical); err != nil {
		t.Fatal(err)
	}
	splitPayloadPath := filepath.Join(legacyDir, "split.json")
	splitBytes, _ := json.Marshal(epubSplitPayload{
		EPUBPath:      splitBook,
		CanonicalKeys: canonical,
		VolumeSize:    50,
	})
	_ = os.WriteFile(splitPayloadPath, splitBytes, 0o644)
	if err := handleEpubSplit(ctx, []string{splitPayloadPath}); err != nil {
		t.Fatalf("handleEpubSplit: %v", err)
	}
	if _, err := os.Stat(splitBook); !os.IsNotExist(err) {
		t.Fatalf("expected splitBook removed after handleEpubSplit")
	}
	if _, err := os.Stat(filepath.Join(splitWorkDir, "CLI拆卷 [0051-0100].epub")); err != nil {
		t.Fatalf("expected CLI split vol2 to exist: %v", err)
	}
}
