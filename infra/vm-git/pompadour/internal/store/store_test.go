package store

import (
	"context"
	"path/filepath"
	"testing"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "pompadour.sqlite3")
	s, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestQueueFIFOOrder(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	for _, pr := range []int64{101, 102, 103} {
		if err := s.Enqueue(ctx, pr); err != nil {
			t.Fatalf("Enqueue(%d): %v", pr, err)
		}
	}
	// Re-enqueueing an already-queued PR must not reorder it.
	if err := s.Enqueue(ctx, 101); err != nil {
		t.Fatalf("re-Enqueue(101): %v", err)
	}

	head, ok, err := s.Head(ctx)
	if err != nil || !ok {
		t.Fatalf("Head: ok=%v err=%v", ok, err)
	}
	if head.PRNumber != 101 {
		t.Fatalf("Head.PRNumber = %d, want 101", head.PRNumber)
	}

	if err := s.Dequeue(ctx, 101); err != nil {
		t.Fatalf("Dequeue(101): %v", err)
	}
	head, ok, err = s.Head(ctx)
	if err != nil || !ok {
		t.Fatalf("Head after dequeue: ok=%v err=%v", ok, err)
	}
	if head.PRNumber != 102 {
		t.Fatalf("Head.PRNumber after dequeue = %d, want 102", head.PRNumber)
	}

	list, err := s.List(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("List length = %d, want 2", len(list))
	}
}

func TestQueueSetStateRejectsUnknownPR(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	err := s.SetState(ctx, 999, QueueTesting)
	if err == nil {
		t.Fatal("SetState on unqueued PR: expected error, got nil")
	}
}

func TestDependencies(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	if err := s.AddDependency(ctx, 103, 102); err != nil {
		t.Fatalf("AddDependency: %v", err)
	}
	if err := s.AddDependency(ctx, 103, 101); err != nil {
		t.Fatalf("AddDependency: %v", err)
	}

	deps, err := s.Dependencies(ctx, 103)
	if err != nil {
		t.Fatalf("Dependencies: %v", err)
	}
	if len(deps) != 2 {
		t.Fatalf("Dependencies = %v, want 2 entries", deps)
	}

	if err := s.ClearDependencies(ctx, 103); err != nil {
		t.Fatalf("ClearDependencies: %v", err)
	}
	deps, err = s.Dependencies(ctx, 103)
	if err != nil {
		t.Fatalf("Dependencies after clear: %v", err)
	}
	if len(deps) != 0 {
		t.Fatalf("Dependencies after clear = %v, want empty", deps)
	}
}

func TestReviewLoadIncrementDecrement(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	if err := s.IncrementAssigned(ctx, "alice"); err != nil {
		t.Fatalf("IncrementAssigned: %v", err)
	}
	if err := s.IncrementAssigned(ctx, "alice"); err != nil {
		t.Fatalf("IncrementAssigned: %v", err)
	}

	loads, err := s.Loads(ctx)
	if err != nil {
		t.Fatalf("Loads: %v", err)
	}
	if loads["alice"].AssignedCount != 2 {
		t.Fatalf("alice.AssignedCount = %d, want 2", loads["alice"].AssignedCount)
	}

	if err := s.DecrementAssigned(ctx, "alice"); err != nil {
		t.Fatalf("DecrementAssigned: %v", err)
	}
	loads, err = s.Loads(ctx)
	if err != nil {
		t.Fatalf("Loads: %v", err)
	}
	if loads["alice"].AssignedCount != 1 {
		t.Fatalf("alice.AssignedCount = %d, want 1", loads["alice"].AssignedCount)
	}

	// Decrementing below zero must floor at zero, not go negative.
	if err := s.DecrementAssigned(ctx, "alice"); err != nil {
		t.Fatalf("DecrementAssigned: %v", err)
	}
	if err := s.DecrementAssigned(ctx, "alice"); err != nil {
		t.Fatalf("DecrementAssigned: %v", err)
	}
	loads, err = s.Loads(ctx)
	if err != nil {
		t.Fatalf("Loads: %v", err)
	}
	if loads["alice"].AssignedCount != 0 {
		t.Fatalf("alice.AssignedCount = %d, want 0 (floored)", loads["alice"].AssignedCount)
	}
}

func TestMarkCommentSeenDedup(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	already, err := s.MarkCommentSeen(ctx, 555)
	if err != nil {
		t.Fatalf("MarkCommentSeen: %v", err)
	}
	if already {
		t.Fatal("first MarkCommentSeen reported already-seen")
	}

	already, err = s.MarkCommentSeen(ctx, 555)
	if err != nil {
		t.Fatalf("MarkCommentSeen (second call): %v", err)
	}
	if !already {
		t.Fatal("second MarkCommentSeen did not report already-seen")
	}
}
