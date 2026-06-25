// Package reviewbalancer picks the next reviewer for an unassigned PR
// from a fixed pool, always preferring whoever currently carries the
// least load (doc/pompadour.md §5.6). The picking logic is pure so it
// can be unit tested without a Forgejo/store dependency; the scheduler
// wires it to internal/store.Loads and internal/forgejo.RequestReviewers.
package reviewbalancer

import "sort"

// Load is the subset of store.ReviewLoad the picker needs.
type Load struct {
	Username      string
	AssignedCount int
}

// Pick returns the username with the lowest AssignedCount among pool,
// excluding anyone at or above maxAssigned and anyone in exclude (e.g.
// the PR author, who cannot review their own PR). loads need not contain
// every pool member — an absent member is treated as load 0, since
// internal/store only creates a row on first assignment.
//
// Pick returns ("", false) if every pool member is excluded or at
// capacity — the caller (doc/pompadour.md §5.6) must then label the PR
// `needs-reviewer` rather than force an assignment onto an overloaded
// reviewer.
func Pick(pool []string, loads map[string]int, maxAssigned int, exclude map[string]bool) (string, bool) {
	candidates := make([]Load, 0, len(pool))
	for _, username := range pool {
		if exclude[username] {
			continue
		}
		count := loads[username]
		if count >= maxAssigned {
			continue
		}
		candidates = append(candidates, Load{Username: username, AssignedCount: count})
	}
	if len(candidates) == 0 {
		return "", false
	}

	// Stable sort by load, then by pool order (input order) as a
	// deterministic tie-breaker — avoids the appearance of favoritism
	// from an arbitrary map-iteration order.
	sort.SliceStable(candidates, func(i, j int) bool {
		return candidates[i].AssignedCount < candidates[j].AssignedCount
	})
	return candidates[0].Username, true
}

// Overloaded reports which pool members are at or above maxAssigned,
// i.e. the set the scheduler should tag with `needs-reviewer` visibility
// concerns rather than burying further work on them (doc/pompadour.md
// §5.6's "燃え尽き対策の核").
func Overloaded(pool []string, loads map[string]int, maxAssigned int) []string {
	var out []string
	for _, username := range pool {
		if loads[username] >= maxAssigned {
			out = append(out, username)
		}
	}
	return out
}
