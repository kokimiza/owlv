package labeler

import (
	"context"
	"testing"
	"time"

	"pompadour/internal/store"
)

func TestPromoteCutoffIs72HoursBefore(t *testing.T) {
	now := time.Date(2026, 6, 25, 12, 0, 0, 0, time.UTC)
	got := PromoteCutoff(now)
	want := "2026-06-22 12:00:00"
	if got != want {
		t.Fatalf("PromoteCutoff = %q, want %q", got, want)
	}
}

func TestSweepDoesNotPromoteFreshProposals(t *testing.T) {
	ctx := context.Background()
	st := newTestStore(t)

	if err := st.PendingAILabel(ctx, 7, "bug"); err != nil {
		t.Fatalf("PendingAILabel: %v", err)
	}

	// A proposal created "now" must not be swept by a sweep also running
	// "now" — only one created >=72h ago should be (doc/pompadour.md §4.2).
	pending, err := st.UnconfirmedAILabelsOlderThan(ctx, PromoteCutoff(time.Now()))
	if err != nil {
		t.Fatalf("UnconfirmedAILabelsOlderThan: %v", err)
	}
	if len(pending) != 0 {
		t.Fatalf("pending = %v, want empty (proposal is not yet 72h old)", pending)
	}
}

func TestSweepPromotesProposalsOnceOver72Hours(t *testing.T) {
	ctx := context.Background()
	st := newTestStore(t)

	if err := st.PendingAILabel(ctx, 7, "bug"); err != nil {
		t.Fatalf("PendingAILabel: %v", err)
	}

	// Simulate the sweep running 73 hours after creation by computing the
	// cutoff from a "now" 73h in the future: cutoff = now+73h-72h = now+1h,
	// which is after the proposal's actual creation time, so it must
	// surface as eligible for promotion.
	simulatedNow := time.Now().Add(73 * time.Hour)
	pending, err := st.UnconfirmedAILabelsOlderThan(ctx, PromoteCutoff(simulatedNow))
	if err != nil {
		t.Fatalf("UnconfirmedAILabelsOlderThan: %v", err)
	}
	if len(pending) != 1 || pending[0].IssueNumber != 7 || pending[0].Label != "bug" {
		t.Fatalf("pending = %v, want [{7 bug}]", pending)
	}
}

func newTestStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(context.Background(), t.TempDir()+"/pompadour.sqlite3")
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}
