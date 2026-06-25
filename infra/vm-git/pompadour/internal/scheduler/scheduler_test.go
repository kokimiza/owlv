package scheduler

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestRunInvokesEachCycleAtLeastOnceAndRespectsCancellation(t *testing.T) {
	var calls atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())

	cycles := []Cycle{
		{Name: "fast", Interval: 10 * time.Millisecond, Run: func(ctx context.Context) error {
			calls.Add(1)
			return nil
		}},
		{Name: "one-shot", Interval: 0, Run: func(ctx context.Context) error {
			calls.Add(1)
			return nil
		}},
	}

	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	done := make(chan struct{})
	go func() {
		Run(ctx, cycles)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after context cancellation")
	}

	if calls.Load() < 2 {
		t.Fatalf("calls = %d, want at least 2 (one per cycle)", calls.Load())
	}
}

func TestRunSurvivesCycleError(t *testing.T) {
	var calls atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cycles run exactly once (immediate run) then see ctx already done

	cycles := []Cycle{
		{Name: "erroring", Interval: time.Hour, Run: func(ctx context.Context) error {
			calls.Add(1)
			return context.DeadlineExceeded
		}},
	}

	done := make(chan struct{})
	go func() {
		Run(ctx, cycles)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return")
	}
	if calls.Load() != 1 {
		t.Fatalf("calls = %d, want 1", calls.Load())
	}
}
