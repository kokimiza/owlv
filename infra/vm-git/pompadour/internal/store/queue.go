package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// QueueState is the lifecycle of one merge_queue row
// (doc/pompadour.md §5.1).
type QueueState string

const (
	QueueQueued   QueueState = "queued"
	QueueRebasing QueueState = "rebasing"
	QueueTesting  QueueState = "testing"
	QueueMerging  QueueState = "merging"
	QueueFailed   QueueState = "failed"
)

// QueueEntry is one PR's position in the merge queue.
type QueueEntry struct {
	PRNumber int64
	Position int64
	State    QueueState
	BatchID  string
}

// Enqueue appends prNumber to the back of the queue if it is not already
// present. It is a no-op (not an error) if the PR is already queued, so
// callers can call it unconditionally on every poll cycle.
func (s *Store) Enqueue(ctx context.Context, prNumber int64) error {
	var maxPos sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT MAX(position) FROM merge_queue`).Scan(&maxPos); err != nil {
		return fmt.Errorf("store: enqueue: read max position: %w", err)
	}
	next := int64(0)
	if maxPos.Valid {
		next = maxPos.Int64 + 1
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO merge_queue (pr_number, position, state) VALUES (?, ?, ?)
		 ON CONFLICT(pr_number) DO NOTHING`,
		prNumber, next, QueueQueued)
	if err != nil {
		return fmt.Errorf("store: enqueue %d: %w", prNumber, err)
	}
	return nil
}

// Dequeue removes prNumber from the queue entirely (successful merge, or
// withdrawal via /hold).
func (s *Store) Dequeue(ctx context.Context, prNumber int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM merge_queue WHERE pr_number = ?`, prNumber)
	if err != nil {
		return fmt.Errorf("store: dequeue %d: %w", prNumber, err)
	}
	return nil
}

// SetState updates the lifecycle state of a queued PR.
func (s *Store) SetState(ctx context.Context, prNumber int64, state QueueState) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE merge_queue SET state = ?, updated_at = CURRENT_TIMESTAMP WHERE pr_number = ?`,
		state, prNumber)
	if err != nil {
		return fmt.Errorf("store: set state %d: %w", prNumber, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: set state %d: %w", prNumber, err)
	}
	if n == 0 {
		return fmt.Errorf("store: set state %d: %w", prNumber, ErrNotQueued)
	}
	return nil
}

// ErrNotQueued is returned when an operation targets a PR not currently
// in the merge queue.
var ErrNotQueued = errors.New("pr is not in the merge queue")

// Head returns the PR at the front of the queue (lowest position), or
// (QueueEntry{}, false, nil) if the queue is empty. The merge queue
// (doc/pompadour.md §5.1) always processes strictly in FIFO order, never
// reordering on its own — only /hold (removal) changes the order.
func (s *Store) Head(ctx context.Context) (QueueEntry, bool, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT pr_number, position, state, COALESCE(batch_id, '')
		   FROM merge_queue ORDER BY position ASC LIMIT 1`)
	var e QueueEntry
	if err := row.Scan(&e.PRNumber, &e.Position, &e.State, &e.BatchID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return QueueEntry{}, false, nil
		}
		return QueueEntry{}, false, fmt.Errorf("store: head: %w", err)
	}
	return e, true, nil
}

// List returns the full queue in order, for status reporting.
func (s *Store) List(ctx context.Context) ([]QueueEntry, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT pr_number, position, state, COALESCE(batch_id, '')
		   FROM merge_queue ORDER BY position ASC`)
	if err != nil {
		return nil, fmt.Errorf("store: list: %w", err)
	}
	defer rows.Close()

	var out []QueueEntry
	for rows.Next() {
		var e QueueEntry
		if err := rows.Scan(&e.PRNumber, &e.Position, &e.State, &e.BatchID); err != nil {
			return nil, fmt.Errorf("store: list: scan: %w", err)
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
