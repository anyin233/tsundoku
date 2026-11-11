package kox

import (
	"archive/zip"
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ohaiibuzzle/aidokurunner-go/cbz"
	"github.com/ohaiibuzzle/aidokurunner-go/downloads"
	"github.com/ohaiibuzzle/aidokurunner-go/models"
	"github.com/ohaiibuzzle/aidokurunner-go/runtime/host"
	"github.com/ohaiibuzzle/aidokurunner-go/source"
)

// KooboneUserInfo mirrors Koobone's `/v1/uinfo` payload.
type KooboneUserInfo struct {
	Uin       int64  `json:"uin"`
	Nick      string `json:"nick"`
	UID       string `json:"uid"`
	VIP       int    `json:"vip"`
	VIPExpiry string `json:"vip_expiry"`
	QuotaUsed int64  `json:"quota_used"`
	QuotaMax  int64  `json:"quota_max"`
	CountVol  int64  `json:"count_vol"`
}

// KooboneSeries represents one series on the user's Koobone bookshelf (`/v1/serieslist`).
type KooboneSeries struct {
	Seq        int64  `json:"seq"`
	Uin        int64  `json:"uin"`
	Series     string `json:"series"`
	SeriesID   string `json:"seriesid"`
	CountVol   int    `json:"count_vol"`
	TimeUpdate string `json:"time_update"`
	TimeModify string `json:"time_modify"`
	CoverURL   string `json:"cover_url"`
	CoverSmall string `json:"cover_small"`
	SeriesFrom string `json:"series_from"`
	SeriesURL  string `json:"series_url"`
}

// KooboneSeriesPage mirrors `/v1/serieslist`.
type KooboneSeriesPage struct {
	Uin       int64           `json:"uin"`
	Total     int             `json:"total"`
	TotalPage int             `json:"totalpage"`
	NowPage   int             `json:"nowpage"`
	NowCount  int             `json:"nowcount"`
	Data      []KooboneSeries `json:"data"`
}

// KooboneVolume represents one volume/chapter book on Koobone (`/v1/vollist`).
type KooboneVolume struct {
	Seq           int64  `json:"seq"`
	Uin           int64  `json:"uin"`
	Status        int    `json:"status"`
	FileMD5       string `json:"file_md5"`
	FileType      string `json:"file_type"`
	FileSize      int64  `json:"file_size"`
	FileFrom      string `json:"file_from"`
	VolName       string `json:"vol_name"`
	VolAuthor     string `json:"vol_author"`
	VolSeries     string `json:"vol_series"`
	VolSeriesID   string `json:"vol_seriesid"`
	VolSNumber    string `json:"vol_snumber"`
	VolPublisher  string `json:"vol_publisher"`
	VolLanguage   string `json:"vol_language"`
	VolDate       string `json:"vol_date"`
	VolIdentifier string `json:"vol_identifier"`
	UserLike      int    `json:"user_like"`
	UserLock      int    `json:"user_lock"`
	CountPage     int    `json:"count_page"`
	CountRead     int    `json:"count_read"`
	LastReadPage  int    `json:"last_readpage"`
	TimeAdd       string `json:"time_add"`
	TimeUpdate    string `json:"time_update"`
	CoverURL      string `json:"cover_url"`
	CoverSmall    string `json:"cover_small"`
	FileURL       string `json:"file_url"`
	CDNURL        string `json:"cdn_url"`

	// Synthesized Aidoku-compatible keys so Tsundoku's DownloadQueue,
	// LibraryBrowser, and ReaderUI treat Koobone volumes identically to
	// native Aidoku chapters.
	MangaKey     string   `json:"manga_key"`
	MangaTitle   string   `json:"manga_title"`
	ChapterKey   string   `json:"chapter_key"`
	ChapterTitle string   `json:"chapter_title"`
	ChapterNum   *float32 `json:"chapter_number,omitempty"`
	VolumeNum    *float32 `json:"volume_number,omitempty"`
}

// KooboneVolPage mirrors `/v1/vollist`.
type KooboneVolPage struct {
	Uin        int64           `json:"uin"`
	Total      int             `json:"total"`
	TotalPage  int             `json:"totalpage"`
	NowPage    int             `json:"nowpage"`
	NowCount   int             `json:"nowcount"`
	URLTimeout int64           `json:"url_timeout"`
	Data       []KooboneVolume `json:"data"`
}

// FetchKooboneUserInfo fetches `/v1/uinfo`.
func (c *Client) FetchKooboneUserInfo(ctx context.Context) (*KooboneUserInfo, error) {
	var out KooboneUserInfo
	if err := c.kooboneGetJSON(ctx, "/v1/uinfo?v=web&ver=8", &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ListKooboneSeries fetches a page of series on the user's Koobone bookshelf.
func (c *Client) ListKooboneSeries(ctx context.Context, page, limit int) (*KooboneSeriesPage, error) {
	if page < 1 {
		page = 1
	}
	if limit <= 0 {
		limit = 49
	}
	var out KooboneSeriesPage
	q := fmt.Sprintf("/v1/serieslist?p=%d&limit=%d&by=time", page, limit)
	if err := c.kooboneGetJSON(ctx, q, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ListKooboneVolumes fetches a page of volumes on Koobone, optionally filtered by seriesID, seriesName, search, or liked.
func (c *Client) ListKooboneVolumes(ctx context.Context, page, limit int, seriesID, seriesName, search string, likedOnly bool) (*KooboneVolPage, error) {
	if page < 1 {
		page = 1
	}
	if limit <= 0 {
		limit = 100
	}
	vals := url.Values{}
	vals.Set("p", strconv.Itoa(page))
	vals.Set("limit", strconv.Itoa(limit))
	vals.Set("by", "time")
	if seriesID != "" {
		vals.Set("sid", seriesID)
	}
	if seriesName != "" {
		vals.Set("sna", seriesName)
	}
	if search != "" {
		vals.Set("s", search)
	}
	if likedOnly {
		vals.Set("l", "1")
	}

	var out KooboneVolPage
	if err := c.kooboneGetJSON(ctx, "/v1/vollist?"+vals.Encode(), &out); err != nil {
		return nil, err
	}
	for i := range out.Data {
		enrichKooboneVolume(&out.Data[i])
	}
	return &out, nil
}

// ListAllKooboneVolumes pages through `/v1/vollist` up to maxPages to return the user's entire Koobone bookshelf.
func (c *Client) ListAllKooboneVolumes(ctx context.Context, seriesID, seriesName string, likedOnly bool) ([]KooboneVolume, error) {
	var all []KooboneVolume
	for page := 1; page <= 50; page++ {
		res, err := c.ListKooboneVolumes(ctx, page, 100, seriesID, seriesName, "", likedOnly)
		if err != nil {
			return nil, err
		}
		all = append(all, res.Data...)
		if page >= res.TotalPage || len(res.Data) == 0 {
			break
		}
	}
	return all, nil
}

var reTrailingNumber = regexp.MustCompile(`(\d+(?:\.\d+)?)`)

// enrichKooboneVolume computes stable MangaKey/ChapterKey/ChapterNum so that:
//  1. Books pushed from Kox (`KMOE:15816`) link directly to Kox manga key `15816`
//     (sharing library bookmarks, cover cache, and read history with Kox!).
//  2. Standalone uploaded EPUBs on Koobone still get a clean `koob:<series>` key.
func enrichKooboneVolume(v *KooboneVolume) {
	if after, ok := strings.CutPrefix(strings.TrimSpace(v.VolSeriesID), "KMOE:"); ok && after != "" {
		v.MangaKey = after
	} else if strings.TrimSpace(v.VolSeries) != "" {
		v.MangaKey = fmt.Sprintf("koob:sid:%s:%s", v.VolSeriesID, v.VolSeries)
	} else {
		v.MangaKey = "koob:uploads"
	}

	if strings.TrimSpace(v.VolSeries) != "" {
		v.MangaTitle = strings.TrimSpace(v.VolSeries)
	} else {
		v.MangaTitle = strings.TrimSpace(v.VolName)
	}

	v.ChapterKey = "koobvol:" + strings.TrimSpace(v.FileMD5)
	if strings.TrimSpace(v.VolSNumber) != "" {
		v.ChapterTitle = strings.TrimSpace(v.VolSNumber)
	} else {
		v.ChapterTitle = strings.TrimSpace(v.VolName)
	}

	// Derive numeric ordering so KOReader's ChapterOrder / NextChapter sorts
	// 卷01, 卷02, ... followed by 話032, 話036 naturally in ascending reading order!
	numLabel := v.ChapterTitle
	if m := reTrailingNumber.FindStringSubmatch(numLabel); len(m) > 1 {
		if f, err := strconv.ParseFloat(m[1], 32); err == nil {
			n := float32(f)
			if strings.Contains(numLabel, "卷") || strings.HasPrefix(strings.ToLower(numLabel), "vol") {
				v.VolumeNum = &n
				v.ChapterNum = &n
			} else if strings.Contains(numLabel, "話") || strings.Contains(numLabel, "话") {
				chN := 10000.0 + n
				v.ChapterNum = &chN
			} else {
				chN := 20000.0 + n
				v.ChapterNum = &chN
			}
		}
	}
}

// ResolveVolumeByMD5 finds a volume on Koobone by its MD5, obtaining a fresh signed `file_url`.
func (c *Client) ResolveVolumeByMD5(ctx context.Context, fileMD5, seriesID, seriesName string) (*KooboneVolume, error) {
	fileMD5 = strings.TrimSpace(strings.TrimPrefix(fileMD5, "koobvol:"))
	if idx := strings.IndexByte(fileMD5, ':'); idx >= 0 {
		fileMD5 = fileMD5[:idx]
	}
	if fileMD5 == "" {
		return nil, fmt.Errorf("koobone: empty file_md5")
	}
	vols, err := c.ListAllKooboneVolumes(ctx, seriesID, seriesName, false)
	if err != nil {
		return nil, err
	}
	for i := range vols {
		if vols[i].FileMD5 == fileMD5 {
			return &vols[i], nil
		}
	}
	// Fallback: global search without series filter if series filter missed it
	if seriesID != "" || seriesName != "" {
		volsAll, err := c.ListAllKooboneVolumes(ctx, "", "", false)
		if err == nil {
			for i := range volsAll {
				if volsAll[i].FileMD5 == fileMD5 {
					return &volsAll[i], nil
				}
			}
		}
	}
	return nil, fmt.Errorf("koobone: volume %s not found on bookshelf", fileMD5)
}

// DownloadKooboneVolumeCBZ downloads a Koobone EPUB volume (streaming to a temp
// file on disk rather than holding the whole archive in RAM), extracts its
// ordered manga pages into a standard uncompressed `.cbz` with `ComicInfo.xml`,
// and records it into `<downloadsDir>/index.db` under source `kox`.
func (c *Client) DownloadKooboneVolumeCBZ(
	ctx context.Context,
	vol KooboneVolume,
	sourcePath string,
	outputPath string,
	downloadsDir string,
	mangaDirName string,
	redownload bool,
	onProgress func(current, total int),
) (string, error) {
	enrichKooboneVolume(&vol)

	if vol.FileURL == "" {
		resolved, err := c.ResolveVolumeByMD5(ctx, vol.FileMD5, vol.VolSeriesID, vol.VolSeries)
		if err != nil {
			return "", err
		}
		vol = *resolved
	}

	var authors []string
	for _, a := range strings.Split(vol.VolAuthor, ",") {
		if a = strings.TrimSpace(a); a != "" {
			authors = append(authors, a)
		}
	}
	lang := vol.VolLanguage
	if lang == "" {
		lang = "zh"
	}
	var dateUploaded *time.Time
	var epochPtr *int64
	if fields := strings.Fields(vol.TimeAdd); len(fields) > 0 {
		if t, err := time.Parse("2006-01-02", fields[0]); err == nil {
			dateUploaded = &t
			ts := t.Unix()
			epochPtr = &ts
		}
	}
	manga := models.Manga{
		SourceKey: SourceKey,
		Key:       vol.MangaKey,
		Title:     vol.MangaTitle,
		Authors:   authors,
	}
	if vol.CoverURL != "" {
		cover := vol.CoverURL
		manga.Cover = &cover
	}
	chapterTitle := vol.ChapterTitle
	chapter := models.Chapter{
		Key:           vol.ChapterKey,
		Title:         &chapterTitle,
		ChapterNumber: vol.ChapterNum,
		VolumeNumber:  vol.VolumeNum,
		DateUploaded:  dateUploaded,
		Language:      &lang,
	}

	convertOnce := func(targetOut, mDir string) (string, error) {
		tmpDir := os.TempDir()
		if downloadsDir != "" {
			_ = os.MkdirAll(downloadsDir, 0o755)
			tmpDir = downloadsDir
		}
		tmpEpub, err := os.CreateTemp(tmpDir, ".koobone-*.epub.tmp")
		if err != nil {
			return "", fmt.Errorf("koobone: creating temp epub: %w", err)
		}
		tmpEpubPath := tmpEpub.Name()
		defer func() {
			tmpEpub.Close()
			_ = os.Remove(tmpEpubPath)
		}()

		rc, _, err := c.DownloadStream(ctx, vol.FileURL)
		if err != nil {
			return "", err
		}
		_, copyErr := io.Copy(tmpEpub, io.LimitReader(rc, host.MaxResponseBytes*4))
		rc.Close()
		if copyErr != nil {
			return "", fmt.Errorf("koobone: downloading epub stream: %w", copyErr)
		}
		if err := tmpEpub.Sync(); err != nil {
			return "", err
		}

		return ConvertEPUBFileToCBZ(tmpEpubPath, manga, chapter, targetOut, mDir, onProgress)
	}

	if downloadsDir == "" {
		return convertOnce(outputPath, mangaDirName)
	}

	lock, err := downloads.AcquireLock(ctx, SourceKey, manga.Key, chapter.Key)
	if err != nil {
		return "", fmt.Errorf("koobone: acquiring download lock: %w", err)
	}
	defer lock.Release()

	store, err := downloads.Open(downloadsDir)
	if err != nil {
		return "", fmt.Errorf("koobone: opening downloads index: %w", err)
	}
	defer store.Close()

	existing, err := store.Path(SourceKey, manga.Key, chapter.Key)
	if err != nil {
		return "", err
	}
	if existing != "" && !redownload {
		if _, statErr := os.Stat(existing); statErr == nil {
			return existing, nil
		}
	}

	if mangaDirName == "" && outputPath == "" {
		outputPath = filepath.Join(downloadsDir, chapterTitle+".cbz")
		mangaDirName = manga.Title + " [" + SourceKey + "]"
	}
	resolvedPath, err := source.ResolveOutputPath(outputPath, mangaDirName, manga, chapter)
	if err != nil {
		return "", err
	}
	pathLock, err := downloads.AcquirePathLock(ctx, resolvedPath)
	if err != nil {
		return "", fmt.Errorf("koobone: acquiring output path lock: %w", err)
	}
	defer pathLock.Release()

	if resolvedPath, err = store.UnusedPath(SourceKey, manga.Key, chapter.Key, resolvedPath); err != nil {
		return "", err
	}
	cbz.RemoveStaleTemps(filepath.Dir(resolvedPath), time.Hour)

	finalPath, err := convertOnce(resolvedPath, "")
	if err != nil {
		return "", err
	}

	entry, err := store.RecordWithDate(
		SourceKey,
		sourcePath,
		manga.Key,
		chapter.Key,
		finalPath,
		source.MangaLabel(manga),
		source.ChapterLabel(chapter),
		chapter.ChapterNumber,
		chapter.VolumeNumber,
		epochPtr,
	)
	if err != nil {
		return "", fmt.Errorf("koobone: recording download: %w", err)
	}
	if redownload && existing != "" && existing != entry.Path {
		_ = os.Remove(existing)
	}
	return entry.Path, nil
}

// ConvertEPUBFileToCBZ extracts manga images in spine reading order from an
// on-disk Kmoe/Koobone EPUB archive and streams them into an atomic `.cbz` archive.
func ConvertEPUBFileToCBZ(
	epubPath string,
	manga models.Manga,
	chapter models.Chapter,
	outputPath string,
	mangaDirName string,
	onProgress func(current, total int),
) (string, error) {
	zr, err := zip.OpenReader(epubPath)
	if err != nil {
		return "", fmt.Errorf("koobone: opening epub zip: %w", err)
	}
	defer zr.Close()

	byName := make(map[string]*zip.File, len(zr.File))
	for _, f := range zr.File {
		byName[f.Name] = f
	}

	imageEntries, err := orderedEPUBImageEntries(zr.File, byName)
	if err != nil {
		return "", err
	}
	if len(imageEntries) == 0 {
		return "", fmt.Errorf("koobone: epub contains no comic images")
	}

	resolvedOut, err := source.ResolveOutputPath(outputPath, mangaDirName, manga, chapter)
	if err != nil {
		return "", err
	}

	w, err := cbz.NewWriter(resolvedOut, len(imageEntries))
	if err != nil {
		return "", err
	}

	ci := cbz.ComicInfo{
		Series:    manga.Title,
		Writer:    strings.Join(manga.Authors, ", "),
		PageCount: len(imageEntries),
	}
	if chapter.Title != nil {
		ci.Title = *chapter.Title
	}
	if chapter.Language != nil {
		ci.LanguageISO = *chapter.Language
	}
	if chapter.DateUploaded != nil {
		y, m, d := chapter.DateUploaded.Date()
		ci.Year, ci.Month, ci.Day = y, int(m), d
	}
	ciBytes, err := ci.Marshal()
	if err != nil {
		w.Abort()
		return "", err
	}
	if err := w.WriteComicInfo(ciBytes); err != nil {
		w.Abort()
		return "", err
	}

	for i, entryName := range imageEntries {
		zf := byName[entryName]
		if zf == nil {
			w.Abort()
			return "", fmt.Errorf("koobone: missing image entry %q in epub", entryName)
		}
		rc, err := zf.Open()
		if err != nil {
			w.Abort()
			return "", err
		}
		imgBytes, readErr := host.ReadAllLimited(rc, host.MaxResponseBytes)
		rc.Close()
		if readErr != nil {
			w.Abort()
			return "", readErr
		}
		if err := w.WritePage(imgBytes); err != nil {
			w.Abort()
			return "", err
		}
		if onProgress != nil {
			onProgress(i+1, len(imageEntries))
		}
	}

	if err := w.Close(); err != nil {
		return "", err
	}
	return resolvedOut, nil
}

type xmlContainer struct {
	Rootfiles []struct {
		FullPath string `xml:"full-path,attr"`
	} `xml:"rootfiles>rootfile"`
}

type xmlPackage struct {
	Manifest struct {
		Items []struct {
			ID        string `xml:"id,attr"`
			Href      string `xml:"href,attr"`
			MediaType string `xml:"media-type,attr"`
		} `xml:"item"`
	} `xml:"manifest"`
	Spine struct {
		Itemrefs []struct {
			IDRef string `xml:"idref,attr"`
		} `xml:"itemref"`
	} `xml:"spine"`
}

var (
	reImgSrc   = regexp.MustCompile(`(?i)<img[^>]+src=["']([^"']+)["']`)
	reImageSVG = regexp.MustCompile(`(?i)<image[^>]+(?:xlink:)?href=["']([^"']+)["']`)
)

func orderedEPUBImageEntries(files []*zip.File, byName map[string]*zip.File) ([]string, error) {
	readEntry := func(name string) ([]byte, bool) {
		f := byName[name]
		if f == nil {
			return nil, false
		}
		rc, err := f.Open()
		if err != nil {
			return nil, false
		}
		defer rc.Close()
		b, err := host.ReadAllLimited(rc, 16<<20)
		return b, err == nil
	}

	opfPath := "vol.opf"
	if containerBytes, ok := readEntry("META-INF/container.xml"); ok {
		var c xmlContainer
		if xml.Unmarshal(containerBytes, &c) == nil && len(c.Rootfiles) > 0 && c.Rootfiles[0].FullPath != "" {
			opfPath = c.Rootfiles[0].FullPath
		}
	}

	var imageNames []string
	if opfBytes, ok := readEntry(opfPath); ok {
		var pkg xmlPackage
		if xml.Unmarshal(opfBytes, &pkg) == nil {
			opfDir := path.Dir(opfPath)
			if opfDir == "." {
				opfDir = ""
			}
			type itemInfo struct{ href, mediaType string }
			manifest := make(map[string]itemInfo, len(pkg.Manifest.Items))
			for _, it := range pkg.Manifest.Items {
				resolved := resolveZipPath(opfDir, it.Href)
				manifest[it.ID] = itemInfo{href: resolved, mediaType: it.MediaType}
			}
			for _, ref := range pkg.Spine.Itemrefs {
				it, exists := manifest[ref.IDRef]
				if !exists {
					continue
				}
				if strings.HasPrefix(strings.ToLower(it.mediaType), "image/") || isImageExt(it.href) {
					if !isTrailingCredit(it.href) && byName[it.href] != nil {
						imageNames = append(imageNames, it.href)
					}
					continue
				}
				if pageHTML, ok := readEntry(it.href); ok {
					s := string(pageHTML)
					var imgRel string
					if m := reImgSrc.FindStringSubmatch(s); len(m) > 1 {
						imgRel = m[1]
					} else if m := reImageSVG.FindStringSubmatch(s); len(m) > 1 {
						imgRel = m[1]
					}
					if imgRel != "" {
						pageDir := path.Dir(it.href)
						if pageDir == "." {
							pageDir = ""
						}
						imgPath := resolveZipPath(pageDir, imgRel)
						if !isTrailingCredit(imgPath) && byName[imgPath] != nil {
							imageNames = append(imageNames, imgPath)
						}
					}
				}
			}
		}
	}

	if len(imageNames) == 0 {
		for _, f := range files {
			if !f.FileInfo().IsDir() && isImageExt(f.Name) && !isTrailingCredit(f.Name) {
				imageNames = append(imageNames, f.Name)
			}
		}
		sort.Strings(imageNames)
	}
	return imageNames, nil
}

func resolveZipPath(baseDir, rel string) string {
	rel = strings.TrimSpace(rel)
	if strings.HasPrefix(rel, "/") {
		return strings.TrimPrefix(path.Clean(rel), "/")
	}
	if baseDir == "" {
		return strings.TrimPrefix(path.Clean(rel), "/")
	}
	return strings.TrimPrefix(path.Clean(baseDir+"/"+rel), "/")
}

func isImageExt(name string) bool {
	ext := strings.ToLower(filepath.Ext(name))
	return ext == ".jpg" || ext == ".jpeg" || ext == ".png" || ext == ".webp" || ext == ".gif"
}

func isTrailingCredit(name string) bool {
	return strings.HasSuffix(strings.ToLower(name), "theendinfo.png")
}
