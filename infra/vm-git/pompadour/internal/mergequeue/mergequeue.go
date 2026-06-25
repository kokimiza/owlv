// Package mergequeue drives doc/pompadour.md §5.1/§5.2/§5.3: it is the
// only thing in pompadour that actually merges a PR to main, and it does
// so strictly in FIFO order, never on the strength of a CI run that
// predates the current queue position (the "CI通ったのにmain壊れた"
// problem bors solves). internal/store holds the queue position;
// internal/batch supplies the bisection search when a batch CI run
// fails; internal/forgejo performs the rebase/branch/merge operations.
//
// Forgejo's branch protection (required approvals, doc/dev_sec_ops.md
// §3.3) remains the authoritative gate — this package's own queue
// bookkeeping is a convenience layer on top, not a replacement for it.
// A bug here can at worst mis-order or mis-batch already-approved PRs;
// it cannot merge anything Forgejo itself would refuse.
package mergequeue

import (
	"context"
	"fmt"
	"time"

	"pompadour/internal/batch"
	"pompadour/internal/forgejo"
	"pompadour/internal/store"
)

const scratchBranchPrefix = "pompadour/batch-"

// Runner orchestrates one merge-queue processing cycle.
type Runner struct {
	Forgejo *forgejo.Client
	Store   *store.Store
	// BatchSize caps how many PRs are tried together per CI run
	// (doc/pompadour.md §5.2). A size of 1 degenerates to bors' original
	// one-PR-at-a-time behavior.
	BatchSize int
	// RunCI builds and tests the scratch branch carrying the given PRs,
	// in order, and reports pass/fail. Implemented by the caller (the
	// scheduler) since it depends on Forgejo Actions, which this package
	// does not itself drive.
	RunCI func(ctx context.Context, scratchBranch string, prs []int64) (passed bool, err error)
}

// ProcessCycle pulls a batch of size up to BatchSize from the front of
// the queue (skipping any PR whose dependencies, internal/store
// dependency edges, are not yet satisfied — doc/pompadour.md §5.3),
// CI-tests them together, and on success merges all of them in queue
// order. On failure it bisects to find the offending PR(s), evicts them
// with QueueFailed, and leaves the rest queued for the next cycle.
func (r *Runner) ProcessCycle(ctx context.Context) error {
	batchPRs, err := r.takeBatch(ctx)
	if err != nil {
		return fmt.Errorf("mergequeue: take batch: %w", err)
	}
	if len(batchPRs) == 0 {
		return nil
	}

	for _, pr := range batchPRs {
		if err := r.Store.SetState(ctx, pr, store.QueueTesting); err != nil {
			return fmt.Errorf("mergequeue: set testing %d: %w", pr, err)
		}
	}

	scratch := fmt.Sprintf("%s%d", scratchBranchPrefix, time.Now().Unix())
	passed, err := r.RunCI(ctx, scratch, batchPRs)
	if err != nil {
		return fmt.Errorf("mergequeue: run ci: %w", err)
	}

	if passed {
		return r.mergeAll(ctx, batchPRs)
	}
	return r.bisectAndEvict(ctx, scratch, batchPRs)
}

// takeBatch returns up to BatchSize PRs from the front of the queue,
// stopping early at any PR whose recorded dependencies have not yet
// merged (doc/pompadour.md §5.3) — such a PR, and anything queued
// behind it, is left for a later cycle rather than reordered around.
func (r *Runner) takeBatch(ctx context.Context) ([]int64, error) {
	entries, err := r.Store.List(ctx)
	if err != nil {
		return nil, err
	}
	var batchPRs []int64
	for _, e := range entries {
		if e.State != store.QueueQueued {
			continue // already in flight from a previous cycle
		}
		deps, err := r.Store.Dependencies(ctx, e.PRNumber)
		if err != nil {
			return nil, err
		}
		if len(deps) > 0 {
			break // unmet dependency: stop extending the batch here
		}
		batchPRs = append(batchPRs, e.PRNumber)
		if len(batchPRs) >= r.BatchSize {
			break
		}
	}
	return batchPRs, nil
}

func (r *Runner) mergeAll(ctx context.Context, prs []int64) error {
	for _, pr := range prs {
		if err := r.Store.SetState(ctx, pr, store.QueueMerging); err != nil {
			return fmt.Errorf("mergequeue: set merging %d: %w", pr, err)
		}
		if err := r.Forgejo.MergePull(ctx, pr, forgejo.MergePullOptions{Do: "rebase"}); err != nil {
			return fmt.Errorf("mergequeue: merge %d: %w", pr, err)
		}
		if err := r.Store.Dequeue(ctx, pr); err != nil {
			return fmt.Errorf("mergequeue: dequeue %d: %w", pr, err)
		}
	}
	return nil
}

// bisectAndEvict finds the PR(s) responsible for the batch failure via
// internal/batch.Bisect, evicts them (QueueFailed + a comment), and
// returns the rest to QueueQueued so the next cycle retries them
// (possibly in a smaller, now-passing batch).
func (r *Runner) bisectAndEvict(ctx context.Context, scratchPrefix string, prs []int64) error {
	test := func(subset []int64) (bool, error) {
		scratch := fmt.Sprintf("%s-bisect-%d", scratchPrefix, time.Now().UnixNano())
		return r.RunCI(ctx, scratch, subset)
	}
	bad, err := batch.Bisect(prs, test)
	if err != nil {
		return fmt.Errorf("mergequeue: bisect: %w", err)
	}

	badSet := make(map[int64]bool, len(bad))
	for _, pr := range bad {
		badSet[pr] = true
	}

	for _, pr := range prs {
		if badSet[pr] {
			if err := r.Store.SetState(ctx, pr, store.QueueFailed); err != nil {
				return fmt.Errorf("mergequeue: set failed %d: %w", pr, err)
			}
			if err := r.Store.Dequeue(ctx, pr); err != nil {
				return fmt.Errorf("mergequeue: dequeue failed %d: %w", pr, err)
			}
			if err := r.Forgejo.CreateComment(ctx, pr,
				"Merge Queue: このPRを含むバッチが CI で失敗し、原因として特定されたためキューから除外しました。再度キューに入れるには再 push してください。",
			); err != nil {
				return fmt.Errorf("mergequeue: comment failed %d: %w", pr, err)
			}
			continue
		}
		if err := r.Store.SetState(ctx, pr, store.QueueQueued); err != nil {
			return fmt.Errorf("mergequeue: requeue %d: %w", pr, err)
		}
	}
	return nil
}
