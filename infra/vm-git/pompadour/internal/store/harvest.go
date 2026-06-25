package store

import (
	"context"
	"fmt"
)

// MarkHarvested records that prNumber's "Why" section has been
// transcribed to doc/decision-log/ (doc/pompadour.md §5.7), and reports
// whether it was already marked before this call — the scheduler polls
// closed PRs on every cycle, so this is what keeps a PR's decision-log
// entry from being appended again on every subsequent poll.
func (s *Store) MarkHarvested(ctx context.Context, prNumber int64) (alreadyHarvested bool, err error) {
	_, err = s.db.ExecContext(ctx, `INSERT INTO harvested_prs (pr_number) VALUES (?)`, prNumber)
	if err == nil {
		return false, nil
	}
	if isUniqueViolation(err) {
		return true, nil
	}
	return false, fmt.Errorf("store: mark harvested %d: %w", prNumber, err)
}
