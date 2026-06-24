package index

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"fohlen/internal/event"
	"fohlen/internal/stats"
)

func openTestIndex(t *testing.T) *Index {
	t.Helper()
	path := filepath.Join(t.TempDir(), "index.sqlite3")
	ix, err := Open(context.Background(), path, 2000, 2000)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { ix.Close() })
	return ix
}

func mkEvent(host string, cat event.EventCategory, actor, message string, ts time.Time) event.AuditEvent {
	return event.AuditEvent{
		Timestamp:  ts,
		SourceHost: host,
		Category:   cat,
		Actor:      actor,
		Raw:        event.RawRecord{Timestamp: ts, SourceHost: host, Message: message, Raw: message},
	}
}

func TestBulkInsertAndSearchByKeyword(t *testing.T) {
	ix := openTestIndex(t)
	ctx := context.Background()
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)

	events := []event.AuditEvent{
		mkEvent("ap_vm", event.AuthSuccess, "alice", "Accepted publickey for alice from 10.0.1.5 port 1 ssh2", now),
		mkEvent("build_vm", event.PrivilegeEscalationAttempt, "bob", "authentication failure for bob", now.Add(time.Minute)),
	}
	if err := ix.BulkInsert(ctx, events, "remote.log"); err != nil {
		t.Fatalf("BulkInsert: %v", err)
	}

	results, err := ix.Search(ctx, SearchFilter{Keyword: "Accepted"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("got %d results, want 1", len(results))
	}
	if results[0].SourceHost != "ap_vm" || results[0].Actor != "alice" {
		t.Errorf("unexpected result: %+v", results[0])
	}
}

func TestSearchFiltersByHostCategoryAndTimeRange(t *testing.T) {
	ix := openTestIndex(t)
	ctx := context.Background()
	base := time.Date(2026, 6, 24, 0, 0, 0, 0, time.UTC)

	events := []event.AuditEvent{
		mkEvent("ap_vm", event.AuthSuccess, "alice", "Accepted for alice", base),
		mkEvent("db_vm", event.AuthFailure, "root", "Failed for root", base.Add(time.Hour)),
		mkEvent("ap_vm", event.AuthFailure, "mallory", "Failed for mallory", base.Add(2*time.Hour)),
	}
	if err := ix.BulkInsert(ctx, events, "remote.log"); err != nil {
		t.Fatalf("BulkInsert: %v", err)
	}

	t.Run("by source host", func(t *testing.T) {
		results, err := ix.Search(ctx, SearchFilter{SourceHost: "ap_vm"})
		if err != nil {
			t.Fatal(err)
		}
		if len(results) != 2 {
			t.Fatalf("got %d results, want 2", len(results))
		}
	})

	t.Run("by category", func(t *testing.T) {
		results, err := ix.Search(ctx, SearchFilter{Category: "AuthFailure"})
		if err != nil {
			t.Fatal(err)
		}
		if len(results) != 2 {
			t.Fatalf("got %d results, want 2", len(results))
		}
	})

	t.Run("by time range", func(t *testing.T) {
		results, err := ix.Search(ctx, SearchFilter{From: base.Add(30 * time.Minute), To: base.Add(90 * time.Minute)})
		if err != nil {
			t.Fatal(err)
		}
		if len(results) != 1 {
			t.Fatalf("got %d results, want 1 (only the middle event)", len(results))
		}
		if results[0].Actor != "root" {
			t.Errorf("unexpected result: %+v", results[0])
		}
	})

	t.Run("combined host+category", func(t *testing.T) {
		results, err := ix.Search(ctx, SearchFilter{SourceHost: "ap_vm", Category: "AuthFailure"})
		if err != nil {
			t.Fatal(err)
		}
		if len(results) != 1 || results[0].Actor != "mallory" {
			t.Fatalf("got %+v, want single mallory result", results)
		}
	})
}

func TestSearchPagination(t *testing.T) {
	ix := openTestIndex(t)
	ctx := context.Background()
	base := time.Date(2026, 6, 24, 0, 0, 0, 0, time.UTC)

	var events []event.AuditEvent
	for i := 0; i < 5; i++ {
		events = append(events, mkEvent("ap_vm", event.AuthSuccess, "alice", "Accepted", base.Add(time.Duration(i)*time.Minute)))
	}
	if err := ix.BulkInsert(ctx, events, "remote.log"); err != nil {
		t.Fatalf("BulkInsert: %v", err)
	}

	page1, err := ix.Search(ctx, SearchFilter{Limit: 2, Offset: 0})
	if err != nil {
		t.Fatal(err)
	}
	if len(page1) != 2 {
		t.Fatalf("page1: got %d, want 2", len(page1))
	}
	page2, err := ix.Search(ctx, SearchFilter{Limit: 2, Offset: 2})
	if err != nil {
		t.Fatal(err)
	}
	if len(page2) != 2 {
		t.Fatalf("page2: got %d, want 2", len(page2))
	}
	// Results are newest-first; page1's oldest must be newer than page2's newest.
	if !page1[len(page1)-1].Timestamp.After(page2[0].Timestamp) {
		t.Errorf("pages overlap or are out of order: page1=%v page2=%v", page1, page2)
	}
}

func TestDeleteGenerationRemovesOnlyThatGeneration(t *testing.T) {
	ix := openTestIndex(t)
	ctx := context.Background()
	now := time.Now()

	if err := ix.BulkInsert(ctx, []event.AuditEvent{mkEvent("ap_vm", event.AuthSuccess, "", "a", now)}, "remote.log.0.gz"); err != nil {
		t.Fatal(err)
	}
	if err := ix.BulkInsert(ctx, []event.AuditEvent{mkEvent("ap_vm", event.AuthSuccess, "", "b", now)}, "remote.log"); err != nil {
		t.Fatal(err)
	}

	if err := ix.DeleteGeneration(ctx, "remote.log.0.gz"); err != nil {
		t.Fatalf("DeleteGeneration: %v", err)
	}

	results, err := ix.Search(ctx, SearchFilter{})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].Message != "b" {
		t.Fatalf("got %+v, want only the remote.log row to survive", results)
	}
}

func TestDistinctSourceHosts(t *testing.T) {
	ix := openTestIndex(t)
	ctx := context.Background()
	now := time.Now()

	events := []event.AuditEvent{
		mkEvent("ap_vm", event.AuthSuccess, "", "a", now),
		mkEvent("db_vm", event.AuthSuccess, "", "b", now),
		mkEvent("ap_vm", event.AuthSuccess, "", "c", now),
	}
	if err := ix.BulkInsert(ctx, events, "remote.log"); err != nil {
		t.Fatal(err)
	}

	hosts, err := ix.DistinctSourceHosts(ctx)
	if err != nil {
		t.Fatalf("DistinctSourceHosts: %v", err)
	}
	if len(hosts) != 2 {
		t.Fatalf("got %v, want 2 distinct hosts", hosts)
	}
}

func TestInsertAndRecentDetections(t *testing.T) {
	ix := openTestIndex(t)
	ctx := context.Background()
	now := time.Now()

	dets := []stats.Detection{
		{Key: "ap_vm/AuthFailure", Method: "zscore", Value: 3.5, Timestamp: now, Message: "first"},
		{Key: "ap_vm/AuthFailure", Method: "cusum-high", Value: 6.0, Timestamp: now.Add(time.Minute), Message: "second"},
	}
	if err := ix.InsertDetections(ctx, dets); err != nil {
		t.Fatalf("InsertDetections: %v", err)
	}

	got, err := ix.RecentDetections(ctx, 10)
	if err != nil {
		t.Fatalf("RecentDetections: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d detections, want 2", len(got))
	}
	// Newest first.
	if got[0].Message != "second" {
		t.Errorf("got[0].Message = %q, want %q (newest first)", got[0].Message, "second")
	}
}

func TestInsertDetectionsEmptyIsNoop(t *testing.T) {
	ix := openTestIndex(t)
	if err := ix.InsertDetections(context.Background(), nil); err != nil {
		t.Fatalf("InsertDetections(nil): %v", err)
	}
}

func TestSizeBytesIsPositiveAfterInsert(t *testing.T) {
	ix := openTestIndex(t)
	ctx := context.Background()
	if err := ix.BulkInsert(ctx, []event.AuditEvent{mkEvent("ap_vm", event.AuthSuccess, "", "a", time.Now())}, "remote.log"); err != nil {
		t.Fatal(err)
	}
	size, err := ix.SizeBytes(ctx)
	if err != nil {
		t.Fatalf("SizeBytes: %v", err)
	}
	if size <= 0 {
		t.Errorf("SizeBytes = %d, want > 0", size)
	}
}
