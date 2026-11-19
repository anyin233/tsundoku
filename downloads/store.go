// Package downloads is the persistent index of locally downloaded chapters:
// which (source, manga, chapter) maps to which local CBZ file, its size, and
// when it was fetched -- backed by SQLite (modernc.org/sqlite, pure Go, no
// cgo) since callers query it on nearly every screen.
//
// Record, Path, and AcquireLock (lock.go) are the only methods any Go binary
// here still calls (cmd/aidoku-run's "download" command). The KOReader
// plugin instead opens index.db directly via lua-ljsqlite3 (see
// downloadsengine.lua) and reimplements the rest of this API's queries in
// Lua -- the Go versions stay here, fully tested, as this package's public
// surface for any other embedder, not dead code.
package downloads

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ohaiibuzzle/aidokurunner-go/epub"
	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

// Entry is one indexed download. SourceKey (the source's stable manifest
// ID, e.g. "en.weebcentral") is the real identity -- see the package doc on
// why. SourcePath (the installed .aix's filesystem path at the time of the
// most recent Record) is kept alongside purely as a display/debugging hint;
// nothing should treat it as a stable identifier.
type Entry struct {
	SourceKey     string   `json:"sourceKey"`
	SourcePath    string   `json:"sourcePath"`
	MangaKey      string   `json:"mangaKey"`
	ChapterKey    string   `json:"chapterKey"`
	Path          string   `json:"path"`
	MangaTitle    string   `json:"mangaTitle"`
	ChapterTitle  string   `json:"chapterTitle"`
	SizeBytes     int64    `json:"sizeBytes"`
	DownloadedAt  int64    `json:"downloadedAt"` // unix seconds
	ChapterNumber *float32 `json:"chapterNumber"` // nil if the source didn't report one, same as models.Chapter
	VolumeNumber  *float32 `json:"volumeNumber"`  // nil if the source didn't report one, same as models.Chapter
	DateUploaded  *int64   `json:"dateUploaded"`  // unix seconds; nil if the source didn't report one
	Viewer        uint8    `json:"viewer"`        // models.Viewer enum (0=Unknown, 1=LTR, 2=RTL, 3=Vertical, 4=Webtoon)
}

// Open opens (creating if needed) the downloads index database at
// <dir>/index.db, migrating it from the pre-source_key schema if needed --
// see migrateToSourceKey.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("downloads: creating %s: %w", dir, err)
	}
	dbPath := filepath.Join(dir, "index.db")
	// _busy_timeout: the KOReader plugin now opens this same file directly
	// (via lua-ljsqlite3) for reads/deletes while this process holds it open
	// for a write -- without a busy timeout a concurrent writer/reader would
	// get SQLITE_BUSY immediately instead of retrying. No _journal_mode=WAL
	// here: some real target hardware (older Kindle kernels) can't safely
	// mmap for WAL, and this package has no way to detect that.
	db, err := sql.Open("sqlite", dbPath+"?_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("downloads: opening %s: %w", dbPath, err)
	}
	s := &Store{db: db}
	if err := s.migrateToSourceKey(); err != nil {
		db.Close()
		return nil, fmt.Errorf("downloads: migrating schema: %w", err)
	}
	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS downloads (
			source_key     TEXT NOT NULL,
			manga_key      TEXT NOT NULL,
			chapter_key    TEXT NOT NULL,
			source_path    TEXT NOT NULL,
			path           TEXT NOT NULL,
			manga_title    TEXT NOT NULL,
			chapter_title  TEXT NOT NULL,
			size_bytes     INTEGER NOT NULL,
			downloaded_at  INTEGER NOT NULL,
			chapter_number REAL,
			volume_number  REAL,
			date_uploaded  INTEGER,
			viewer         INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (source_key, manga_key, chapter_key)
		)
	`); err != nil {
		db.Close()
		return nil, fmt.Errorf("downloads: creating schema: %w", err)
	}
	if err := s.migrateAddChapterOrdering(); err != nil {
		db.Close()
		return nil, fmt.Errorf("downloads: migrating schema: %w", err)
	}
	if err := s.migrateAddDateUploaded(); err != nil {
		db.Close()
		return nil, fmt.Errorf("downloads: migrating schema: %w", err)
	}
	if err := s.migrateAddViewer(); err != nil {
		db.Close()
		return nil, fmt.Errorf("downloads: migrating schema: %w", err)
	}
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS idx_downloads_path ON downloads(path)`); err != nil {
		db.Close()
		return nil, fmt.Errorf("downloads: creating path index: %w", err)
	}
	return s, nil
}

// migrateToSourceKey upgrades a database from before source_key existed
// (when source_path was itself the primary key). SQLite can't add/change a
// PRIMARY KEY column via ALTER TABLE, so this rebuilds the table, seeding
// source_key from the old source_path -- which can't retroactively fix a
// row whose source was renamed before this ran, but keeps every row
// resolving correctly and keys future rows by the stable identity. No-op if
// the table doesn't exist yet or already has a source_key column.
func (s *Store) migrateToSourceKey() error {
	var exists int
	if err := s.db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type='table' AND name='downloads'`).Scan(&exists); err != nil {
		return err
	}
	if exists == 0 {
		return nil
	}
	rows, err := s.db.Query(`PRAGMA table_info(downloads)`)
	if err != nil {
		return err
	}
	hasSourceKey := false
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "source_key" {
			hasSourceKey = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	if hasSourceKey {
		return nil
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`ALTER TABLE downloads RENAME TO downloads_pre_source_key`); err != nil {
		return err
	}
	if _, err := tx.Exec(`
		CREATE TABLE downloads (
			source_key    TEXT NOT NULL,
			manga_key     TEXT NOT NULL,
			chapter_key   TEXT NOT NULL,
			source_path   TEXT NOT NULL,
			path          TEXT NOT NULL,
			manga_title   TEXT NOT NULL,
			chapter_title TEXT NOT NULL,
			size_bytes    INTEGER NOT NULL,
			downloaded_at INTEGER NOT NULL,
			PRIMARY KEY (source_key, manga_key, chapter_key)
		)
	`); err != nil {
		return err
	}
	if _, err := tx.Exec(`
		INSERT INTO downloads (source_key, manga_key, chapter_key, source_path, path, manga_title, chapter_title, size_bytes, downloaded_at)
		SELECT source_path, manga_key, chapter_key, source_path, path, manga_title, chapter_title, size_bytes, downloaded_at
		FROM downloads_pre_source_key
	`); err != nil {
		return err
	}
	if _, err := tx.Exec(`DROP TABLE downloads_pre_source_key`); err != nil {
		return err
	}
	return tx.Commit()
}

// migrateAddChapterOrdering adds the chapter_number/volume_number columns
// (needed to reproduce reading order from the index alone, offline) to a
// database created before they existed. Unlike migrateToSourceKey, these
// aren't part of the primary key, so a plain ALTER TABLE ADD COLUMN suffices
// -- no table rebuild. A no-op if the table doesn't exist yet (the preceding
// CREATE TABLE IF NOT EXISTS already included both columns) or already has
// them.
func (s *Store) migrateAddChapterOrdering() error {
	rows, err := s.db.Query(`PRAGMA table_info(downloads)`)
	if err != nil {
		return err
	}
	hasChapterNumber := false
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "chapter_number" {
			hasChapterNumber = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	if hasChapterNumber {
		return nil
	}

	// Both ALTER TABLEs run in one transaction -- SQLite DDL is
	// transactional, so a kill between them can't leave chapter_number
	// added but volume_number missing (which the guard above, checking only
	// chapter_number, would then treat as "already migrated" forever).
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`ALTER TABLE downloads ADD COLUMN chapter_number REAL`); err != nil {
		return err
	}
	if _, err := tx.Exec(`ALTER TABLE downloads ADD COLUMN volume_number REAL`); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) hasColumn(target string) (bool, error) {
	rows, err := s.db.Query(`PRAGMA table_info(downloads)`)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			return false, err
		}
		if name == target {
			return true, nil
		}
	}
	return false, rows.Err()
}

func (s *Store) migrateAddDateUploaded() error {
	has, err := s.hasColumn("date_uploaded")
	if err != nil || has {
		return err
	}
	_, err = s.db.Exec(`ALTER TABLE downloads ADD COLUMN date_uploaded INTEGER`)
	return err
}

func (s *Store) migrateAddViewer() error {
	has, err := s.hasColumn("viewer")
	if err != nil || has {
		return err
	}
	_, err = s.db.Exec(`ALTER TABLE downloads ADD COLUMN viewer INTEGER NOT NULL DEFAULT 0`)
	return err
}

func (s *Store) Close() error { return s.db.Close() }

// Record inserts or replaces the index entry for a downloaded chapter,
// computing its size from the file at path. Replacing lets a re-download
// (same source/manga/chapter, e.g. after MangaBrowser's "Re-download"
// action) update the existing row rather than accumulate duplicates.
func (s *Store) Record(sourceKey, sourcePath, mangaKey, chapterKey, path, mangaTitle, chapterTitle string, chapterNumber, volumeNumber *float32) (*Entry, error) {
	return s.RecordWithDate(sourceKey, sourcePath, mangaKey, chapterKey, path, mangaTitle, chapterTitle, chapterNumber, volumeNumber, nil)
}

// RecordWithDate is Record plus an optional source upload timestamp (unix seconds).
func (s *Store) RecordWithDate(sourceKey, sourcePath, mangaKey, chapterKey, path, mangaTitle, chapterTitle string, chapterNumber, volumeNumber *float32, dateUploaded *int64) (*Entry, error) {
	return s.RecordWithViewer(sourceKey, sourcePath, mangaKey, chapterKey, path, mangaTitle, chapterTitle, chapterNumber, volumeNumber, dateUploaded, 0)
}

// RecordWithViewer is RecordWithDate plus the manga's models.Viewer value
// (0 = Unknown, 1 = LTR, 2 = RTL, 3 = Vertical, 4 = Webtoon).
func (s *Store) RecordWithViewer(sourceKey, sourcePath, mangaKey, chapterKey, path, mangaTitle, chapterTitle string, chapterNumber, volumeNumber *float32, dateUploaded *int64, viewer uint8) (*Entry, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("downloads: stat %s: %w", path, err)
	}
	path, err = s.disambiguatePath(sourceKey, mangaKey, chapterKey, path)
	if err != nil {
		return nil, err
	}
	e := &Entry{
		SourceKey:     sourceKey,
		SourcePath:    sourcePath,
		MangaKey:      mangaKey,
		ChapterKey:    chapterKey,
		Path:          path,
		MangaTitle:    mangaTitle,
		ChapterTitle:  chapterTitle,
		SizeBytes:     info.Size(),
		DownloadedAt:  time.Now().Unix(),
		ChapterNumber: chapterNumber,
		VolumeNumber:  volumeNumber,
		DateUploaded:  dateUploaded,
		Viewer:        viewer,
	}
	_, err = s.db.Exec(upsertDownloadSQL, e.SourceKey, e.MangaKey, e.ChapterKey, e.SourcePath, e.Path, e.MangaTitle, e.ChapterTitle, e.SizeBytes, e.DownloadedAt, e.ChapterNumber, e.VolumeNumber, e.DateUploaded, e.Viewer)
	if err != nil {
		return nil, fmt.Errorf("downloads: recording: %w", err)
	}
	return e, nil
}

const upsertDownloadSQL = `
	INSERT INTO downloads (source_key, manga_key, chapter_key, source_path, path, manga_title, chapter_title, size_bytes, downloaded_at, chapter_number, volume_number, date_uploaded, viewer)
	VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT (source_key, manga_key, chapter_key) DO UPDATE SET
		source_path=excluded.source_path, path=excluded.path, manga_title=excluded.manga_title, chapter_title=excluded.chapter_title,
		size_bytes=excluded.size_bytes, downloaded_at=excluded.downloaded_at,
		chapter_number=excluded.chapter_number, volume_number=excluded.volume_number,
		date_uploaded=excluded.date_uploaded,
		viewer=CASE WHEN excluded.viewer > 0 THEN excluded.viewer ELSE downloads.viewer END
`

// BookChapterRecord describes one chapter inside a shared single-book archive (EPUB).
type BookChapterRecord struct {
	ChapterKey    string
	ChapterTitle  string
	ChapterNumber *float32
	VolumeNumber  *float32
	DateUploaded  *int64
}

// RecordBookChapters atomically upserts multiple chapter rows that share epubPath
// and updates size_bytes across all existing rows pointing to epubPath.
func (s *Store) RecordBookChapters(sourceKey, sourcePath, mangaKey, epubPath, mangaTitle string, chapters []BookChapterRecord, viewer uint8) ([]Entry, error) {
	if len(chapters) == 0 {
		return nil, nil
	}
	info, err := os.Stat(epubPath)
	if err != nil {
		return nil, fmt.Errorf("downloads: stat %s: %w", epubPath, err)
	}
	sizeBytes := info.Size()
	now := time.Now().Unix()

	tx, err := s.db.Begin()
	if err != nil {
		return nil, fmt.Errorf("downloads: beginning book record transaction: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	stmt, err := tx.Prepare(upsertDownloadSQL)
	if err != nil {
		return nil, fmt.Errorf("downloads: preparing book record: %w", err)
	}
	defer stmt.Close()

	entries := make([]Entry, 0, len(chapters))
	for _, ch := range chapters {
		e := Entry{
			SourceKey:     sourceKey,
			SourcePath:    sourcePath,
			MangaKey:      mangaKey,
			ChapterKey:    ch.ChapterKey,
			Path:          epubPath,
			MangaTitle:    mangaTitle,
			ChapterTitle:  ch.ChapterTitle,
			SizeBytes:     sizeBytes,
			DownloadedAt:  now,
			ChapterNumber: ch.ChapterNumber,
			VolumeNumber:  ch.VolumeNumber,
			DateUploaded:  ch.DateUploaded,
			Viewer:        viewer,
		}
		if _, err := stmt.Exec(
			e.SourceKey, e.MangaKey, e.ChapterKey, e.SourcePath, e.Path,
			e.MangaTitle, e.ChapterTitle, e.SizeBytes, e.DownloadedAt,
			e.ChapterNumber, e.VolumeNumber, e.DateUploaded, e.Viewer,
		); err != nil {
			return nil, fmt.Errorf("downloads: recording chapter %s: %w", ch.ChapterKey, err)
		}
		entries = append(entries, e)
	}

	if _, err := tx.Exec(`UPDATE downloads SET size_bytes = ? WHERE path = ?`, sizeBytes, epubPath); err != nil {
		return nil, fmt.Errorf("downloads: syncing shared book size: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("downloads: committing book record: %w", err)
	}
	return entries, nil
}

// DeleteBookChapterRows deletes chapterKeys for a shared EPUB and updates
// surviving rows' size_bytes if the EPUB file still exists.
func (s *Store) DeleteBookChapterRows(sourceKey, mangaKey, epubPath string, chapterKeys []string) error {
	if len(chapterKeys) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("downloads: beginning chapter delete transaction: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	for _, ck := range chapterKeys {
		if ck == "" {
			continue
		}
		if epubPath != "" {
			if _, err := tx.Exec(`DELETE FROM downloads WHERE (path = ? OR (source_key = ? AND manga_key = ?)) AND chapter_key = ?`,
				epubPath, sourceKey, mangaKey, ck); err != nil {
				return fmt.Errorf("downloads: deleting chapter %s: %w", ck, err)
			}
		} else {
			if _, err := tx.Exec(`DELETE FROM downloads WHERE source_key = ? AND manga_key = ? AND chapter_key = ?`,
				sourceKey, mangaKey, ck); err != nil {
				return fmt.Errorf("downloads: deleting chapter %s: %w", ck, err)
			}
		}
	}

	if epubPath != "" {
		if info, err := os.Stat(epubPath); err == nil {
			if _, uerr := tx.Exec(`UPDATE downloads SET size_bytes = ? WHERE path = ?`, info.Size(), epubPath); uerr != nil {
				return fmt.Errorf("downloads: updating surviving book size: %w", uerr)
			}
		}
	}

	return tx.Commit()
}

// UnusedPath returns path if no other (manga_key, chapter_key) under
// sourceKey is recorded against it, else a variant with a short hash of
// this chapter's keys appended -- two chapters whose titles sanitize to the
// same filename (e.g. both "Omake") would otherwise share one file. Callers
// should pick the write path through this *before* writing, so the second
// download never overwrites the first chapter's file.
func (s *Store) UnusedPath(sourceKey, mangaKey, chapterKey, path string) (string, error) {
	var ownerManga, ownerChapter string
	err := s.db.QueryRow(`SELECT manga_key, chapter_key FROM downloads WHERE source_key = ? AND path = ?`, sourceKey, path).Scan(&ownerManga, &ownerChapter)
	if err == sql.ErrNoRows {
		return path, nil
	}
	if err != nil {
		return "", fmt.Errorf("downloads: checking for a path collision: %w", err)
	}
	if ownerManga == mangaKey && ownerChapter == chapterKey {
		return path, nil // re-recording the same chapter -- an expected overwrite, not a collision
	}

	// mangaKey/chapterKey can be arbitrary source-provided strings unsafe
	// to use in a filename directly (same reasoning as lockPath in
	// lock.go), so a short hash of them disambiguates without risking a
	// FAT32/exFAT-illegal character sneaking back in.
	ext := filepath.Ext(path)
	sum := sha256.Sum256([]byte(mangaKey + "\x00" + chapterKey))
	return fmt.Sprintf("%s [%s]%s", strings.TrimSuffix(path, ext), hex.EncodeToString(sum[:])[:8], ext), nil
}

// disambiguatePath is Record's backstop for a collision UnusedPath couldn't
// prevent: two different same-named chapters downloading at once without
// aidoku-run's AcquirePathLock (e.g. names differing only in a way the lock
// key doesn't normalize), so neither was recorded yet when the other checked. The first chapter's bytes are already overwritten
// by then; this only renames the surviving file to the second chapter's
// unique name, leaving the first's row pointing at nothing -- which readers
// of the index treat as "not downloaded", not as the wrong content.
func (s *Store) disambiguatePath(sourceKey, mangaKey, chapterKey, path string) (string, error) {
	newPath, err := s.UnusedPath(sourceKey, mangaKey, chapterKey, path)
	if err != nil || newPath == path {
		return newPath, err
	}
	if err := os.Rename(path, newPath); err != nil {
		return "", fmt.Errorf("downloads: disambiguating colliding filename: %w", err)
	}
	return newPath, nil
}

// Path returns the local file path for a chapter, or "" if it hasn't been
// downloaded.
func (s *Store) Path(sourceKey, mangaKey, chapterKey string) (string, error) {
	var path string
	err := s.db.QueryRow(`SELECT path FROM downloads WHERE source_key=? AND manga_key=? AND chapter_key=?`,
		sourceKey, mangaKey, chapterKey).Scan(&path)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("downloads: querying: %w", err)
	}
	return path, nil
}

// BookEPUBPath returns an existing .epub path recorded for (sourceKey, mangaKey),
// or "" if none is indexed.
func (s *Store) BookEPUBPath(sourceKey, mangaKey string) (string, error) {
	var path string
	err := s.db.QueryRow(
		`SELECT path FROM downloads WHERE source_key=? AND manga_key=? AND LOWER(path) LIKE '%.epub' ORDER BY downloaded_at DESC LIMIT 1`,
		sourceKey, mangaKey,
	).Scan(&path)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("downloads: querying book epub path: %w", err)
	}
	return path, nil
}

// BookEPUBPaths returns every distinct .epub path recorded for (sourceKey, mangaKey),
// ordered most recently downloaded first.
func (s *Store) BookEPUBPaths(sourceKey, mangaKey string) ([]string, error) {
	rows, err := s.db.Query(
		`SELECT path FROM downloads WHERE source_key=? AND manga_key=? AND LOWER(path) LIKE '%.epub' GROUP BY path ORDER BY MAX(downloaded_at) DESC`,
		sourceKey, mangaKey,
	)
	if err != nil {
		return nil, fmt.Errorf("downloads: querying book epub paths: %w", err)
	}
	defer rows.Close()
	var paths []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, fmt.Errorf("downloads: scanning book epub path: %w", err)
		}
		if p != "" {
			paths = append(paths, p)
		}
	}
	return paths, rows.Err()
}

// MigrateSplitBook atomically repoints chapter rows from legacyPath (or matching
// (sourceKey, mangaKey)) to each split volume's path and size_bytes.
func (s *Store) MigrateSplitBook(sourceKey, mangaKey, legacyPath string, volumes []epub.SplitVolumeResult) error {
	if len(volumes) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("downloads: beginning split migration tx: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	for _, vol := range volumes {
		if vol.Path == "" || len(vol.ChapterKeys) == 0 {
			continue
		}
		info, err := os.Stat(vol.Path)
		if err != nil {
			return fmt.Errorf("downloads: stat split volume %s: %w", vol.Path, err)
		}
		sz := info.Size()
		for _, ck := range vol.ChapterKeys {
			if ck == "" {
				continue
			}
			if legacyPath != "" {
				if _, err := tx.Exec(
					`UPDATE downloads SET path = ?, size_bytes = ? WHERE (path = ? OR (source_key = ? AND manga_key = ?)) AND chapter_key = ?`,
					vol.Path, sz, legacyPath, sourceKey, mangaKey, ck,
				); err != nil {
					return fmt.Errorf("downloads: migrating chapter %s to %s: %w", ck, vol.Path, err)
				}
			} else {
				if _, err := tx.Exec(
					`UPDATE downloads SET path = ?, size_bytes = ? WHERE source_key = ? AND manga_key = ? AND chapter_key = ?`,
					vol.Path, sz, sourceKey, mangaKey, ck,
				); err != nil {
					return fmt.Errorf("downloads: migrating chapter %s to %s: %w", ck, vol.Path, err)
				}
			}
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("downloads: committing split migration: %w", err)
	}
	return nil
}

// nullFloat32 converts a nullable REAL column scan into the *float32
// pointer-means-absent representation Entry uses (matching models.Chapter).
func nullFloat32(n sql.NullFloat64) *float32 {
	if !n.Valid {
		return nil
	}
	v := float32(n.Float64)
	return &v
}

func nullInt64(n sql.NullInt64) *int64 {
	if !n.Valid {
		return nil
	}
	v := n.Int64
	return &v
}

const entryColumns = `source_key, source_path, manga_key, chapter_key, path, manga_title, chapter_title, size_bytes, downloaded_at, chapter_number, volume_number, date_uploaded, viewer`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanEntry(s rowScanner) (Entry, error) {
	var e Entry
	var chapterNumber, volumeNumber sql.NullFloat64
	var dateUploaded, viewer sql.NullInt64
	err := s.Scan(&e.SourceKey, &e.SourcePath, &e.MangaKey, &e.ChapterKey, &e.Path, &e.MangaTitle, &e.ChapterTitle, &e.SizeBytes, &e.DownloadedAt, &chapterNumber, &volumeNumber, &dateUploaded, &viewer)
	if err != nil {
		return Entry{}, err
	}
	e.ChapterNumber = nullFloat32(chapterNumber)
	e.VolumeNumber = nullFloat32(volumeNumber)
	e.DateUploaded = nullInt64(dateUploaded)
	if viewer.Valid && viewer.Int64 >= 0 {
		e.Viewer = uint8(viewer.Int64)
	}
	return e, nil
}

// ByPath is the reverse lookup: given a local file path (e.g. the document
// currently open in a reader), find which chapter it is. Returns nil if
// path isn't indexed.
func (s *Store) ByPath(path string) (*Entry, error) {
	e, err := scanEntry(s.db.QueryRow(`SELECT `+entryColumns+` FROM downloads WHERE path=?`, path))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("downloads: querying: %w", err)
	}
	return &e, nil
}

// Remove deletes the index entry and updates or removes its backing file.
// For shared multi-chapter EPUBs, it removes the chapter from the archive and
// repacks, deleting the file only once no chapters remain. A no-op (not an
// error) if the entry doesn't exist.
func (s *Store) Remove(sourceKey, mangaKey, chapterKey string) error {
	path, err := s.Path(sourceKey, mangaKey, chapterKey)
	if err != nil {
		return err
	}
	if path == "" {
		return nil
	}

	var refCount int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM downloads WHERE path = ?`, path).Scan(&refCount); err != nil {
		return fmt.Errorf("downloads: counting path refs for %s: %w", path, err)
	}

	if strings.HasSuffix(strings.ToLower(path), ".epub") {
		res, rerr := epub.RemoveChapters(path, []string{chapterKey})
		if rerr != nil {
			return fmt.Errorf("downloads: removing chapter from epub %s: %w", path, rerr)
		}
		if _, err := s.db.Exec(`DELETE FROM downloads WHERE source_key=? AND manga_key=? AND chapter_key=?`,
			sourceKey, mangaKey, chapterKey); err != nil {
			return fmt.Errorf("downloads: deleting index entry: %w", err)
		}
		if res != nil && res.TotalChapters > 0 {
			if info, serr := os.Stat(path); serr == nil {
				if _, uerr := s.db.Exec(`UPDATE downloads SET size_bytes = ? WHERE path = ?`, info.Size(), path); uerr != nil {
					return fmt.Errorf("downloads: updating epub size: %w", uerr)
				}
			}
		}
		_, _ = epub.SyncBookIndex(filepath.Dir(path))
		return nil
	}

	if refCount <= 1 {
		// File first: if that fails, the row stays so a later Remove/Prune can
		// retry, instead of leaving a file nothing indexes (and so nothing ever
		// deletes).
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("downloads: removing file %s: %w", path, err)
		}
	}
	if _, err := s.db.Exec(`DELETE FROM downloads WHERE source_key=? AND manga_key=? AND chapter_key=?`,
		sourceKey, mangaKey, chapterKey); err != nil {
		return fmt.Errorf("downloads: deleting index entry: %w", err)
	}
	return nil
}

// List returns every downloaded chapter, most recently downloaded first.
func (s *Store) List() ([]Entry, error) {
	rows, err := s.db.Query(`SELECT ` + entryColumns + ` FROM downloads ORDER BY downloaded_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("downloads: listing: %w", err)
	}
	defer rows.Close()
	var entries []Entry
	for rows.Next() {
		e, err := scanEntry(rows)
		if err != nil {
			return nil, fmt.Errorf("downloads: scanning: %w", err)
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// TotalBytes returns the deduplicated sum of size_bytes across unique files on disk.
func (s *Store) TotalBytes() (int64, error) {
	var total sql.NullInt64
	if err := s.db.QueryRow(`SELECT COALESCE(SUM(max_size), 0) FROM (SELECT MAX(size_bytes) AS max_size FROM downloads GROUP BY path)`).Scan(&total); err != nil {
		return 0, fmt.Errorf("downloads: summing: %w", err)
	}
	return total.Int64, nil
}

// Prune deletes the oldest-downloaded files (index entries + file), one file
// at a time, until the total is at or under limitBytes. Returns what was
// removed, oldest first. A limitBytes <= 0 is treated as "no limit" (a
// no-op), since 0 is store.lua's zero-value default meaning "unset".
func (s *Store) Prune(limitBytes int64) ([]Entry, error) {
	if limitBytes <= 0 {
		return nil, nil
	}
	total, err := s.TotalBytes()
	if err != nil {
		return nil, err
	}
	if total <= limitBytes {
		return nil, nil
	}
	entries, err := s.List() // most-recent-first
	if err != nil {
		return nil, err
	}

	type pathGroup struct {
		path    string
		size    int64
		maxAt   int64
		entries []Entry
	}
	byPath := make(map[string]*pathGroup)
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		g, ok := byPath[e.Path]
		if !ok {
			g = &pathGroup{path: e.Path, size: e.SizeBytes, maxAt: e.DownloadedAt}
			byPath[e.Path] = g
		}
		if e.SizeBytes > g.size {
			g.size = e.SizeBytes
		}
		if e.DownloadedAt > g.maxAt {
			g.maxAt = e.DownloadedAt
		}
		g.entries = append(g.entries, e)
	}
	groups := make([]*pathGroup, 0, len(byPath))
	for _, g := range byPath {
		groups = append(groups, g)
	}
	sort.SliceStable(groups, func(i, j int) bool {
		return groups[i].maxAt < groups[j].maxAt
	})

	var removed []Entry
	for _, g := range groups {
		if total <= limitBytes {
			break
		}
		if err := os.Remove(g.path); err != nil && !os.IsNotExist(err) {
			return removed, fmt.Errorf("downloads: removing file %s: %w", g.path, err)
		}
		if _, err := s.db.Exec(`DELETE FROM downloads WHERE path = ?`, g.path); err != nil {
			return removed, fmt.Errorf("downloads: deleting pruned rows for %s: %w", g.path, err)
		}
		total -= g.size
		removed = append(removed, g.entries...)
	}
	return removed, nil
}

// Reassociate repoints every entry recorded under oldSourceKey to
// newSourceKey -- a manual repair primitive for entries orphaned by a
// source rename/update that this package couldn't resolve automatically
// (see migrateToSourceKey and the package doc). Returns how many rows were
// updated. If newSourceKey already has an entry for some (manga, chapter)
// also present under oldSourceKey, the oldSourceKey row is dropped instead
// of overwriting the existing one, since the row already under
// newSourceKey is presumably the more recently verified-working one.
func (s *Store) Reassociate(oldSourceKey, newSourceKey string) (int64, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("downloads: beginning reassociate transaction: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op once committed

	if _, err := tx.Exec(`
		DELETE FROM downloads
		WHERE source_key = ?
		AND EXISTS (
			SELECT 1 FROM downloads AS d2
			WHERE d2.source_key = ? AND d2.manga_key = downloads.manga_key AND d2.chapter_key = downloads.chapter_key
		)
	`, oldSourceKey, newSourceKey); err != nil {
		return 0, fmt.Errorf("downloads: dropping conflicting rows: %w", err)
	}
	res, err := tx.Exec(`UPDATE downloads SET source_key = ? WHERE source_key = ?`, newSourceKey, oldSourceKey)
	if err != nil {
		return 0, fmt.Errorf("downloads: reassociating: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("downloads: reading rows affected: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("downloads: committing reassociate transaction: %w", err)
	}
	return n, nil
}
