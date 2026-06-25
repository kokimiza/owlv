package store

import (
	"context"
	"fmt"
	"strings"
)

// MarkCommentSeen records commentID as processed and reports whether it
// was already seen before this call. ChatOps (doc/pompadour.md §4.1)
// polls comments on an interval, so the same comment is read on every
// cycle until it scrolls out of the page window — this is the dedup
// guard that keeps a single "/retest" from re-triggering forever.
func (s *Store) MarkCommentSeen(ctx context.Context, commentID int64) (alreadySeen bool, err error) {
	_, err = s.db.ExecContext(ctx, `INSERT INTO seen_comments (comment_id) VALUES (?)`, commentID)
	if err == nil {
		return false, nil
	}
	if isUniqueViolation(err) {
		return true, nil
	}
	return false, fmt.Errorf("store: mark comment seen %d: %w", commentID, err)
}

// isUniqueViolation reports whether err is a SQLite primary-key/unique
// constraint failure. modernc.org/sqlite reports this via a plain error
// message rather than a typed sentinel, so we match on the message — an
// acceptable trade-off here because the only INSERT that can violate a
// constraint in this table is the primary key itself.
func isUniqueViolation(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

// PendingAILabel records a not-yet-confirmed `ai-suggested/<label>`
// proposal (doc/pompadour.md §4.2).
func (s *Store) PendingAILabel(ctx context.Context, issueNumber int64, label string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO ai_label_proposals (issue_number, label) VALUES (?, ?)
		 ON CONFLICT(issue_number, label) DO NOTHING`,
		issueNumber, label)
	if err != nil {
		return fmt.Errorf("store: pending ai label %d/%s: %w", issueNumber, label, err)
	}
	return nil
}

// ConfirmAILabel marks a proposal as confirmed (via /confirm-label or the
// 72h auto-promotion in doc/pompadour.md §4.2).
func (s *Store) ConfirmAILabel(ctx context.Context, issueNumber int64, label string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE ai_label_proposals SET confirmed = 1 WHERE issue_number = ? AND label = ?`,
		issueNumber, label)
	if err != nil {
		return fmt.Errorf("store: confirm ai label %d/%s: %w", issueNumber, label, err)
	}
	return nil
}

// AILabelProposal is one row of ai_label_proposals.
type AILabelProposal struct {
	IssueNumber int64
	Label       string
}

// UnconfirmedAILabelsOlderThan returns proposals made at or before
// cutoffSQL (a "YYYY-MM-DD HH:MM:SS" SQLite datetime string) that are
// still unconfirmed, for the scheduler's 72-hour auto-promotion sweep
// (doc/pompadour.md §4.2).
func (s *Store) UnconfirmedAILabelsOlderThan(ctx context.Context, cutoffSQL string) ([]AILabelProposal, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT issue_number, label FROM ai_label_proposals
		   WHERE confirmed = 0 AND proposed_at <= ?`, cutoffSQL)
	if err != nil {
		return nil, fmt.Errorf("store: unconfirmed ai labels: %w", err)
	}
	defer rows.Close()

	var out []AILabelProposal
	for rows.Next() {
		var p AILabelProposal
		if err := rows.Scan(&p.IssueNumber, &p.Label); err != nil {
			return nil, fmt.Errorf("store: unconfirmed ai labels: scan: %w", err)
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
