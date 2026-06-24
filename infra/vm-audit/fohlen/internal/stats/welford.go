// Package stats implements the online (constant-memory, single-pass)
// statistical methods required by doc/audit_engine.md §4.3: Welford's
// running mean/variance, Shewhart/Z-score, EWMA, CUSUM and Shannon
// entropy/self-information. Every method updates in O(1) per observation
// and re-derives its verdict purely from its own formula, so detections are
// reproducible from the persisted state (§4.3 lead paragraph).
package stats

import "math"

// Welford holds the running count/mean/sum-of-squares needed to compute
// mean and variance in a single pass (Welford, 1962).
type Welford struct {
	N    int64
	Mean float64
	M2   float64 // sum of squared deviations from the running mean
}

// Update folds one observation into the running statistics.
func (w *Welford) Update(x float64) {
	w.N++
	delta := x - w.Mean
	w.Mean += delta / float64(w.N)
	delta2 := x - w.Mean
	w.M2 += delta * delta2
}

// Variance returns the sample variance, or 0 if fewer than 2 observations
// have been seen.
func (w *Welford) Variance() float64 {
	if w.N < 2 {
		return 0
	}
	return w.M2 / float64(w.N-1)
}

// StdDev returns the sample standard deviation.
func (w *Welford) StdDev() float64 {
	return math.Sqrt(w.Variance())
}

// ZScore returns (x - mean) / stddev for the current running statistics.
// Returns 0 if stddev is 0 (insufficient data to judge an outlier).
func (w *Welford) ZScore(x float64) float64 {
	sd := w.StdDev()
	if sd == 0 {
		return 0
	}
	return (x - w.Mean) / sd
}
