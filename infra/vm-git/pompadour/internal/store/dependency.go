package store

import (
	"context"
	"fmt"
)

// AddDependency records that prNumber depends on dependsOn
// ("Depends-on: #N" in the PR body, doc/pompadour.md §5.3).
func (s *Store) AddDependency(ctx context.Context, prNumber, dependsOn int64) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO pr_dependencies (pr_number, depends_on) VALUES (?, ?)
		 ON CONFLICT(pr_number, depends_on) DO NOTHING`,
		prNumber, dependsOn)
	if err != nil {
		return fmt.Errorf("store: add dependency %d -> %d: %w", prNumber, dependsOn, err)
	}
	return nil
}

// ClearDependencies removes all recorded dependency edges for prNumber,
// so a fresh PR-body parse can rebuild them from scratch.
func (s *Store) ClearDependencies(ctx context.Context, prNumber int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM pr_dependencies WHERE pr_number = ?`, prNumber)
	if err != nil {
		return fmt.Errorf("store: clear dependencies %d: %w", prNumber, err)
	}
	return nil
}

// Dependencies returns the PR numbers prNumber directly depends on.
func (s *Store) Dependencies(ctx context.Context, prNumber int64) ([]int64, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT depends_on FROM pr_dependencies WHERE pr_number = ?`, prNumber)
	if err != nil {
		return nil, fmt.Errorf("store: dependencies %d: %w", prNumber, err)
	}
	defer rows.Close()

	var out []int64
	for rows.Next() {
		var dep int64
		if err := rows.Scan(&dep); err != nil {
			return nil, fmt.Errorf("store: dependencies %d: scan: %w", prNumber, err)
		}
		out = append(out, dep)
	}
	return out, rows.Err()
}
