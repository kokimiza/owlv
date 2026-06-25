package batch

import (
	"reflect"
	"testing"
)

func passExcept(bad map[int64]bool) TestFunc {
	return func(prs []int64) (bool, error) {
		for _, pr := range prs {
			if bad[pr] {
				return false, nil
			}
		}
		return true, nil
	}
}

func TestBisectSingleOffender(t *testing.T) {
	prs := []int64{1, 2, 3, 4, 5, 6, 7}
	bad, err := Bisect(prs, passExcept(map[int64]bool{5: true}))
	if err != nil {
		t.Fatalf("Bisect: %v", err)
	}
	if !reflect.DeepEqual(bad, []int64{5}) {
		t.Fatalf("Bisect = %v, want [5]", bad)
	}
}

func TestBisectTwoIndependentOffenders(t *testing.T) {
	prs := []int64{1, 2, 3, 4, 5, 6, 7, 8}
	bad, err := Bisect(prs, passExcept(map[int64]bool{2: true, 7: true}))
	if err != nil {
		t.Fatalf("Bisect: %v", err)
	}
	got := map[int64]bool{}
	for _, pr := range bad {
		got[pr] = true
	}
	if !got[2] || !got[7] || len(got) != 2 {
		t.Fatalf("Bisect = %v, want exactly [2 7]", bad)
	}
}

func TestBisectSinglePR(t *testing.T) {
	bad, err := Bisect([]int64{42}, passExcept(nil))
	if err != nil {
		t.Fatalf("Bisect: %v", err)
	}
	if !reflect.DeepEqual(bad, []int64{42}) {
		t.Fatalf("Bisect = %v, want [42]", bad)
	}
}

func TestBisectInteractionEffectReportsWholeBatch(t *testing.T) {
	// Neither half fails on its own, but the full batch (passed in via
	// the failing batch invariant the caller upholds) is presumed bad;
	// Bisect must not fabricate a single culprit.
	prs := []int64{1, 2, 3, 4}
	bad, err := Bisect(prs, passExcept(nil)) // both halves "pass" in isolation
	if err != nil {
		t.Fatalf("Bisect: %v", err)
	}
	if !reflect.DeepEqual(bad, prs) {
		t.Fatalf("Bisect = %v, want whole batch %v", bad, prs)
	}
}

func TestBisectEmptyBatch(t *testing.T) {
	bad, err := Bisect(nil, passExcept(nil))
	if err != nil {
		t.Fatalf("Bisect: %v", err)
	}
	if len(bad) != 0 {
		t.Fatalf("Bisect(nil) = %v, want empty", bad)
	}
}
