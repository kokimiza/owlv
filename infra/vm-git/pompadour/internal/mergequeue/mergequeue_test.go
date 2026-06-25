package mergequeue

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"pompadour/internal/forgejo"
	"pompadour/internal/store"
)

func newTestRunner(t *testing.T, runCI func(ctx context.Context, scratch string, prs []int64) (bool, error)) (*Runner, *recordingServer) {
	t.Helper()
	rec := &recordingServer{}
	srv := httptest.NewServer(http.HandlerFunc(rec.handle))
	t.Cleanup(srv.Close)

	st, err := store.Open(context.Background(), t.TempDir()+"/pompadour.sqlite3")
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	fc := forgejo.New(srv.URL, "owlv-admin", "owlv", "test-token")
	return &Runner{Forgejo: fc, Store: st, BatchSize: 3, RunCI: runCI}, rec
}

// recordingServer is a minimal Forgejo stand-in that records merge and
// comment calls and answers everything else with an empty JSON body.
type recordingServer struct {
	merged   []int64
	comments []int64
}

var prNumberPattern = regexp.MustCompile(`/(\d+)/(?:merge|comments)$`)

func (r *recordingServer) handle(w http.ResponseWriter, req *http.Request) {
	if m := prNumberPattern.FindStringSubmatch(req.URL.Path); req.Method == http.MethodPost && m != nil {
		n, _ := strconv.ParseInt(m[1], 10, 64)
		if strings.HasSuffix(req.URL.Path, "/merge") {
			r.merged = append(r.merged, n)
		} else {
			r.comments = append(r.comments, n)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{})
}

func TestProcessCycleMergesOnPass(t *testing.T) {
	ctx := context.Background()
	runner, rec := newTestRunner(t, func(ctx context.Context, scratch string, prs []int64) (bool, error) {
		return true, nil
	})

	for _, pr := range []int64{1, 2, 3} {
		if err := runner.Store.Enqueue(ctx, pr); err != nil {
			t.Fatalf("Enqueue: %v", err)
		}
	}

	if err := runner.ProcessCycle(ctx); err != nil {
		t.Fatalf("ProcessCycle: %v", err)
	}

	if len(rec.merged) != 3 {
		t.Fatalf("merged = %v, want 3 PRs merged", rec.merged)
	}
	list, err := runner.Store.List(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 0 {
		t.Fatalf("queue after merge = %v, want empty", list)
	}
}

func TestProcessCycleSkipsPRWithUnmetDependency(t *testing.T) {
	ctx := context.Background()
	var seenBatches [][]int64
	runner, _ := newTestRunner(t, func(ctx context.Context, scratch string, prs []int64) (bool, error) {
		seenBatches = append(seenBatches, prs)
		return true, nil
	})

	if err := runner.Store.Enqueue(ctx, 1); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	if err := runner.Store.Enqueue(ctx, 2); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	// PR 2 depends on PR 99, which is not in the queue (not yet merged).
	if err := runner.Store.AddDependency(ctx, 2, 99); err != nil {
		t.Fatalf("AddDependency: %v", err)
	}

	if err := runner.ProcessCycle(ctx); err != nil {
		t.Fatalf("ProcessCycle: %v", err)
	}

	if len(seenBatches) != 1 || len(seenBatches[0]) != 1 || seenBatches[0][0] != 1 {
		t.Fatalf("seenBatches = %v, want exactly [[1]] (PR 2 held back)", seenBatches)
	}
}

func TestProcessCycleBisectsOnFailureAndEvictsOffender(t *testing.T) {
	ctx := context.Background()
	runner, rec := newTestRunner(t, func(ctx context.Context, scratch string, prs []int64) (bool, error) {
		for _, pr := range prs {
			if pr == 2 {
				return false, nil
			}
		}
		return true, nil
	})

	for _, pr := range []int64{1, 2, 3} {
		if err := runner.Store.Enqueue(ctx, pr); err != nil {
			t.Fatalf("Enqueue: %v", err)
		}
	}

	if err := runner.ProcessCycle(ctx); err != nil {
		t.Fatalf("ProcessCycle: %v", err)
	}

	if len(rec.merged) != 0 {
		t.Fatalf("merged = %v, want none (batch failed)", rec.merged)
	}
	if len(rec.comments) != 1 || rec.comments[0] != 2 {
		t.Fatalf("comments = %v, want exactly a comment on PR 2", rec.comments)
	}

	list, err := runner.Store.List(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	remaining := map[int64]store.QueueState{}
	for _, e := range list {
		remaining[e.PRNumber] = e.State
	}
	if _, stillThere := remaining[2]; stillThere {
		t.Fatalf("PR 2 should have been evicted, queue = %v", list)
	}
	if remaining[1] != store.QueueQueued || remaining[3] != store.QueueQueued {
		t.Fatalf("PRs 1 and 3 should be requeued, queue = %v", list)
	}
}
