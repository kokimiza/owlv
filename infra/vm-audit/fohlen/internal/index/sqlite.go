// Package index implements the full-text/structured index described in
// doc/audit_engine.md §4.2: SQLite FTS5 via modernc.org/sqlite (pure Go,
// no cgo — see §4.2's rationale tying this to the no-gcc-on-OpenBSD
// constraint). Bulk inserts are batched and followed by an explicit GC,
// per §4.2's memory-management requirements for the 256MB Audit VM.
package index

import (
	"context"
	"database/sql"
	"fmt"
	"runtime"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"fohlen/internal/event"
	"fohlen/internal/stats"
)

const schema = `
CREATE TABLE IF NOT EXISTS events (
	id          INTEGER PRIMARY KEY AUTOINCREMENT,
	timestamp   INTEGER NOT NULL,
	source_host TEXT NOT NULL,
	category    TEXT NOT NULL,
	actor       TEXT NOT NULL DEFAULT '',
	message     TEXT NOT NULL,
	generation  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_source_host ON events(source_host);
CREATE INDEX IF NOT EXISTS idx_events_category ON events(category);
CREATE INDEX IF NOT EXISTS idx_events_generation ON events(generation);

CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
	message,
	content='events',
	content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
	INSERT INTO events_fts(rowid, message) VALUES (new.id, new.message);
END;
CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
	INSERT INTO events_fts(events_fts, rowid, message) VALUES ('delete', old.id, old.message);
END;

-- Persisted statistical detections (doc/audit_engine.md §4.4 dashboard
-- "直近の逸脱検知イベント一覧"). Without this table the dashboard only ever
-- showed detections raised since the last process restart, which is not
-- an acceptable audit trail for a forensics tool.
CREATE TABLE IF NOT EXISTS detections (
	id        INTEGER PRIMARY KEY AUTOINCREMENT,
	timestamp INTEGER NOT NULL,
	key       TEXT NOT NULL,
	method    TEXT NOT NULL,
	value     REAL NOT NULL,
	message   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_detections_timestamp ON detections(timestamp);
`

// Index wraps the SQLite connection and the bulk-commit batch size
// configured via fohlen.toml (doc/audit_engine.md §4.2 "目安: 2000行").
type Index struct {
	db        *sql.DB
	batchSize int
}

// Open opens (creating if absent) the FTS5 index at path, applies the
// schema, and sets PRAGMA cache_size per §4.2's explicit memory-pressure
// guidance. cacheSizeKB is the *magnitude*; it is stored as a negative
// PRAGMA value (KB-denominated page cache) as SQLite requires.
//
// Open performs one query against the database before returning, by
// design: doc/audit_engine.md §7 requires the caller to drive
// modernc.org/sqlite's internal initialization to completion (which may
// touch TMPDIR) *before* the final unveil(2) lock, and this function
// existing as a single call makes that ordering explicit at the call site
// in main.go.
func Open(ctx context.Context, path string, batchSize, cacheSizeKB int) (*Index, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("index: open %s: %w", path, err)
	}
	db.SetMaxOpenConns(1) // single-writer, matches owlv's projector pattern (Shell.Projector)

	if _, err := db.ExecContext(ctx, fmt.Sprintf("PRAGMA cache_size = -%d;", cacheSizeKB)); err != nil {
		db.Close()
		return nil, fmt.Errorf("index: set cache_size: %w", err)
	}
	if _, err := db.ExecContext(ctx, "PRAGMA journal_mode = WAL;"); err != nil {
		db.Close()
		return nil, fmt.Errorf("index: set journal_mode: %w", err)
	}
	if _, err := db.ExecContext(ctx, schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("index: apply schema: %w", err)
	}
	// Force full internal initialization (the query that must complete
	// before the §7 final unveil lock).
	var one int
	if err := db.QueryRowContext(ctx, "SELECT 1").Scan(&one); err != nil {
		db.Close()
		return nil, fmt.Errorf("index: warm-up query: %w", err)
	}

	if batchSize <= 0 {
		batchSize = 2000
	}
	return &Index{db: db, batchSize: batchSize}, nil
}

func (ix *Index) Close() error { return ix.db.Close() }

// BulkInsert writes events tagged with the given generation (the source
// file name they came from — "remote.log" or "remote.log.N.gz") in
// batches of ix.batchSize, committing each batch in its own transaction
// and calling runtime.GC() immediately after, per
// doc/audit_engine.md §4.2's three numbered memory-management points.
func (ix *Index) BulkInsert(ctx context.Context, events []event.AuditEvent, generation string) error {
	for start := 0; start < len(events); start += ix.batchSize {
		end := min(start+ix.batchSize, len(events))
		if err := ix.insertBatch(ctx, events[start:end], generation); err != nil {
			return err
		}
		runtime.GC()
	}
	return nil
}

func (ix *Index) insertBatch(ctx context.Context, batch []event.AuditEvent, generation string) error {
	tx, err := ix.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("index: begin tx: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO events(timestamp, source_host, category, actor, message, generation) VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return fmt.Errorf("index: prepare insert: %w", err)
	}
	defer stmt.Close()

	for _, ev := range batch {
		if _, err := stmt.ExecContext(ctx, ev.Timestamp.Unix(), ev.SourceHost, ev.Category.String(), ev.Actor, ev.Raw.Raw, generation); err != nil {
			return fmt.Errorf("index: insert event: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("index: commit batch: %w", err)
	}
	return nil
}

// DeleteGeneration removes all rows for generation, used when newsyslog
// has rotated a .gz generation out past its retention window
// (doc/audit_engine.md §4.1 "newsyslog による世代削除...索引行を...削除する").
func (ix *Index) DeleteGeneration(ctx context.Context, generation string) error {
	_, err := ix.db.ExecContext(ctx, `DELETE FROM events WHERE generation = ?`, generation)
	if err != nil {
		return fmt.Errorf("index: delete generation %s: %w", generation, err)
	}
	return nil
}

// SizeBytes returns the on-disk size of the SQLite file's main database
// page allocation, used by the startup health check in
// doc/audit_engine.md §4.2 ("索引サイズが原本ログ合計サイズの3倍を超えないか").
func (ix *Index) SizeBytes(ctx context.Context) (int64, error) {
	var pageCount, pageSize int64
	if err := ix.db.QueryRowContext(ctx, "PRAGMA page_count;").Scan(&pageCount); err != nil {
		return 0, err
	}
	if err := ix.db.QueryRowContext(ctx, "PRAGMA page_size;").Scan(&pageSize); err != nil {
		return 0, err
	}
	return pageCount * pageSize, nil
}

// InsertDetections persists detections raised by one ingest cycle
// (doc/audit_engine.md §4.3 "実装要件") so the dashboard's detection
// history survives a restart instead of living only in process memory.
func (ix *Index) InsertDetections(ctx context.Context, detections []stats.Detection) error {
	if len(detections) == 0 {
		return nil
	}
	tx, err := ix.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("index: begin detections tx: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO detections(timestamp, key, method, value, message) VALUES (?, ?, ?, ?, ?)`)
	if err != nil {
		return fmt.Errorf("index: prepare detections insert: %w", err)
	}
	defer stmt.Close()

	for _, d := range detections {
		if _, err := stmt.ExecContext(ctx, d.Timestamp.Unix(), d.Key, d.Method, d.Value, d.Message); err != nil {
			return fmt.Errorf("index: insert detection: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("index: commit detections: %w", err)
	}
	return nil
}

// RecentDetections returns the most recent limit detections, newest first.
func (ix *Index) RecentDetections(ctx context.Context, limit int) ([]stats.Detection, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := ix.db.QueryContext(ctx,
		`SELECT timestamp, key, method, value, message FROM detections ORDER BY timestamp DESC, id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("index: recent detections: %w", err)
	}
	defer rows.Close()

	var out []stats.Detection
	for rows.Next() {
		var (
			ts                     int64
			key, method, message   string
			value                  float64
		)
		if err := rows.Scan(&ts, &key, &method, &value, &message); err != nil {
			return nil, fmt.Errorf("index: scan detection: %w", err)
		}
		out = append(out, stats.Detection{
			Timestamp: time.Unix(ts, 0).UTC(),
			Key:       key,
			Method:    method,
			Value:     value,
			Message:   message,
		})
	}
	return out, rows.Err()
}

// DistinctSourceHosts returns every source_host value currently indexed,
// used to populate the search UI's host filter dropdown.
func (ix *Index) DistinctSourceHosts(ctx context.Context) ([]string, error) {
	rows, err := ix.db.QueryContext(ctx, `SELECT DISTINCT source_host FROM events ORDER BY source_host`)
	if err != nil {
		return nil, fmt.Errorf("index: distinct source hosts: %w", err)
	}
	defer rows.Close()

	var hosts []string
	for rows.Next() {
		var h string
		if err := rows.Scan(&h); err != nil {
			return nil, err
		}
		hosts = append(hosts, h)
	}
	return hosts, rows.Err()
}

// SearchFilter is the combination of filters exposed by the UI
// (doc/audit_engine.md §4.2 "キーワード・時間範囲・送信元ホスト・カテゴリ").
type SearchFilter struct {
	Keyword    string // FTS5 MATCH syntax; empty means no full-text filter
	From, To   time.Time
	SourceHost string // empty means any
	Category   string // empty means any; event.EventCategory.String() value
	Limit      int
	Offset     int
}

// SearchResult is one row of a search response.
type SearchResult struct {
	Timestamp  time.Time
	SourceHost string
	Category   string
	Actor      string
	Message    string
}

// Search runs filter against the index, paginated so results are never
// fully materialized in memory at once (doc/audit_engine.md §4.2).
func (ix *Index) Search(ctx context.Context, f SearchFilter) ([]SearchResult, error) {
	if f.Limit <= 0 || f.Limit > 500 {
		f.Limit = 100
	}

	var (
		conds []string
		args  []any
	)
	from := `events`
	if f.Keyword != "" {
		from = `events JOIN events_fts ON events_fts.rowid = events.id`
		conds = append(conds, "events_fts MATCH ?")
		args = append(args, f.Keyword)
	}
	if !f.From.IsZero() {
		conds = append(conds, "events.timestamp >= ?")
		args = append(args, f.From.Unix())
	}
	if !f.To.IsZero() {
		conds = append(conds, "events.timestamp <= ?")
		args = append(args, f.To.Unix())
	}
	if f.SourceHost != "" {
		conds = append(conds, "events.source_host = ?")
		args = append(args, f.SourceHost)
	}
	if f.Category != "" {
		conds = append(conds, "events.category = ?")
		args = append(args, f.Category)
	}

	where := ""
	if len(conds) > 0 {
		where = "WHERE " + strings.Join(conds, " AND ")
	}
	query := fmt.Sprintf(
		`SELECT events.timestamp, events.source_host, events.category, events.actor, events.message
		 FROM %s %s
		 ORDER BY events.timestamp DESC
		 LIMIT ? OFFSET ?`, from, where)
	args = append(args, f.Limit, f.Offset)

	rows, err := ix.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("index: search: %w", err)
	}
	defer rows.Close()

	var results []SearchResult
	for rows.Next() {
		var (
			ts                                   int64
			sourceHost, category, actor, message string
		)
		if err := rows.Scan(&ts, &sourceHost, &category, &actor, &message); err != nil {
			return nil, fmt.Errorf("index: scan: %w", err)
		}
		results = append(results, SearchResult{
			Timestamp:  time.Unix(ts, 0).UTC(),
			SourceHost: sourceHost,
			Category:   category,
			Actor:      actor,
			Message:    message,
		})
	}
	return results, rows.Err()
}
