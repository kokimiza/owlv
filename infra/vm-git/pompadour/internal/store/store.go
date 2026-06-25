// Package store holds pompadour's own state: merge queue position, review
// load counters, PR dependency edges, and ChatOps comment dedup —
// everything Forgejo itself has no concept of (doc/pompadour.md §5.1,
// §5.3, §5.6). It uses modernc.org/sqlite, the same pure-Go,
// cgo-free driver fohlen uses (infra/vm-audit/fohlen/internal/index),
// which keeps the Build VM's OpenBSD toolchain at "go" only
// (doc/audit_engine.md, citing doc/hypervisor_rationale.md §1.1).
package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

// Open creates the parent directory if needed, opens the SQLite file at
// path, and applies the schema. SQLite's single-writer model is fine
// here: pompadourd is a single process with one scheduler loop
// (doc/pompadour.md §3), so there is no concurrent-writer contention to
// design around.
func Open(ctx context.Context, path string) (*Store, error) {
	if dir := filepath.Dir(path); dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("store: mkdir %s: %w", dir, err)
		}
	}
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", path, err)
	}
	db.SetMaxOpenConns(1) // single-writer; avoids SQLITE_BUSY churn under WAL

	s := &Store{db: db}
	if err := s.migrate(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

const schema = `
CREATE TABLE IF NOT EXISTS merge_queue (
	pr_number    INTEGER PRIMARY KEY,
	position     INTEGER NOT NULL,
	state        TEXT NOT NULL DEFAULT 'queued', -- queued|rebasing|testing|merging|failed
	batch_id     TEXT,
	enqueued_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
	updated_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pr_dependencies (
	pr_number      INTEGER NOT NULL,
	depends_on     INTEGER NOT NULL,
	PRIMARY KEY (pr_number, depends_on)
);

CREATE TABLE IF NOT EXISTS review_load (
	username             TEXT PRIMARY KEY,
	assigned_count       INTEGER NOT NULL DEFAULT 0,
	avg_response_seconds REAL NOT NULL DEFAULT 0,
	updated_at           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS seen_comments (
	comment_id  INTEGER PRIMARY KEY,
	seen_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS harvested_prs (
	pr_number   INTEGER PRIMARY KEY,
	harvested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS ai_label_proposals (
	issue_number  INTEGER NOT NULL,
	label         TEXT NOT NULL,
	proposed_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
	confirmed     INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (issue_number, label)
);
`

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, schema); err != nil {
		return fmt.Errorf("store: migrate: %w", err)
	}
	return nil
}
