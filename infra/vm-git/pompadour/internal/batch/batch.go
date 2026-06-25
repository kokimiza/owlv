// Package batch implements the bisection search of doc/pompadour.md §5.2:
// when a batch of PRs fails CI together, find the offending PR(s) in
// O(log n) test runs instead of re-testing every PR individually. The
// search itself is pure (no Forgejo/branch I/O) so it can be unit
// tested; internal/mergequeue is responsible for turning each Run into
// an actual disposable branch + CI invocation.
package batch

// TestFunc runs CI against the given subset of PR numbers (e.g. by
// building a disposable branch that merges them in order) and reports
// whether it passed.
type TestFunc func(prs []int64) (passed bool, err error)

// Bisect returns the subset of prs that are responsible for a failing
// batch. It assumes prs failed as a whole batch already (callers should
// not call Bisect on a batch they have not first run as one), and that
// failures are caused by one or more independently-failing PRs rather
// than purely order-dependent interaction effects — the same assumption
// Zuul's speculative pipelines make.
//
// Cost: at most O(log2(n)) calls to test in the common single-offender
// case, degrading toward O(n) only when most of the batch is broken.
func Bisect(prs []int64, test TestFunc) ([]int64, error) {
	if len(prs) == 0 {
		return nil, nil
	}
	if len(prs) == 1 {
		return prs, nil // the batch-level failure already implicates this one PR
	}

	mid := len(prs) / 2
	left, right := prs[:mid], prs[mid:]

	leftOK, err := test(left)
	if err != nil {
		return nil, err
	}
	rightOK, err := test(right)
	if err != nil {
		return nil, err
	}

	switch {
	case !leftOK && !rightOK:
		// Both halves fail independently: recurse into both and
		// concatenate (don't short-circuit on the first failing half).
		leftBad, err := Bisect(left, test)
		if err != nil {
			return nil, err
		}
		rightBad, err := Bisect(right, test)
		if err != nil {
			return nil, err
		}
		return append(leftBad, rightBad...), nil
	case !leftOK:
		return Bisect(left, test)
	case !rightOK:
		return Bisect(right, test)
	default:
		// Both halves pass in isolation: the failure is an interaction
		// effect between left and right, not attributable to a single
		// PR. Report the whole batch rather than claiming a false
		// single culprit.
		return prs, nil
	}
}
