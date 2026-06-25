package store

import (
	"context"
	"fmt"
)

// ReviewLoad is one reviewer's current standing
// (doc/pompadour.md §5.6).
type ReviewLoad struct {
	Username           string
	AssignedCount      int
	AvgResponseSeconds float64
}

// IncrementAssigned bumps username's assigned_count by 1, creating the
// row if it does not exist yet.
func (s *Store) IncrementAssigned(ctx context.Context, username string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO review_load (username, assigned_count) VALUES (?, 1)
		 ON CONFLICT(username) DO UPDATE SET
		   assigned_count = assigned_count + 1,
		   updated_at = CURRENT_TIMESTAMP`,
		username)
	if err != nil {
		return fmt.Errorf("store: increment assigned %s: %w", username, err)
	}
	return nil
}

// DecrementAssigned drops username's assigned_count by 1 (floor 0), once
// a review is completed (PR merged, closed, or reviewer removed).
func (s *Store) DecrementAssigned(ctx context.Context, username string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE review_load SET
		   assigned_count = MAX(assigned_count - 1, 0),
		   updated_at = CURRENT_TIMESTAMP
		 WHERE username = ?`,
		username)
	if err != nil {
		return fmt.Errorf("store: decrement assigned %s: %w", username, err)
	}
	return nil
}

// Loads returns the current load of every reviewer pompadour has ever
// tracked. Pool members never assigned anything are not present here —
// callers (internal/reviewbalancer) must treat a missing entry as load 0.
func (s *Store) Loads(ctx context.Context) (map[string]ReviewLoad, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT username, assigned_count, avg_response_seconds FROM review_load`)
	if err != nil {
		return nil, fmt.Errorf("store: loads: %w", err)
	}
	defer rows.Close()

	out := make(map[string]ReviewLoad)
	for rows.Next() {
		var l ReviewLoad
		if err := rows.Scan(&l.Username, &l.AssignedCount, &l.AvgResponseSeconds); err != nil {
			return nil, fmt.Errorf("store: loads: scan: %w", err)
		}
		out[l.Username] = l
	}
	return out, rows.Err()
}
