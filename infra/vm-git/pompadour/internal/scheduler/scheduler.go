// Package scheduler runs each feature's poll cycle on its own ticker
// (doc/pompadour.md §3: polling, never inbound webhooks). It is the only
// package that owns goroutines/time.Ticker; every feature package below
// it (chatops, mergequeue, reviewbalancer, labeler, harvest) exposes a
// plain "do one cycle" function that the scheduler calls.
package scheduler

import (
	"context"
	"log"
	"time"
)

// Cycle is one feature's "do one poll iteration" function.
type Cycle struct {
	Name     string
	Interval time.Duration
	Run      func(ctx context.Context) error
}

// Run starts a goroutine per Cycle and blocks until ctx is canceled. Each
// cycle runs once immediately, then on its own interval, independently
// of the others — a slow merge-queue cycle never delays ChatOps
// responsiveness, matching the differing cadences doc/pompadour.md §3
// assigns each feature (e.g. chatops every ~20s, review balancing every
// ~5min).
func Run(ctx context.Context, cycles []Cycle) {
	done := make(chan struct{})
	for _, c := range cycles {
		go runOne(ctx, c, done)
	}
	for range cycles {
		<-done
	}
}

func runOne(ctx context.Context, c Cycle, done chan<- struct{}) {
	defer func() { done <- struct{}{} }()

	runOnce := func() {
		if err := c.Run(ctx); err != nil {
			log.Printf("pompadour: %s cycle failed: %v", c.Name, err)
		}
	}

	runOnce()
	if c.Interval <= 0 {
		return
	}
	ticker := time.NewTicker(c.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			runOnce()
		}
	}
}
