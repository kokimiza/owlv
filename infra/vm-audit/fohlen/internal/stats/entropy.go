package stats

import "math"

// FreqTable is an online observation-frequency table used for Shannon
// entropy and per-symbol self-information (Shannon, 1948). It detects
// previously-unseen (source_host, category) combinations and rising
// Unclassified frequency without any pretrained model
// (doc/audit_engine.md §4.3).
type FreqTable struct {
	Counts map[string]float64
	Total  float64
}

// NewFreqTable constructs an empty frequency table.
func NewFreqTable() *FreqTable {
	return &FreqTable{Counts: make(map[string]float64)}
}

// Observe records one occurrence of key.
func (f *FreqTable) Observe(key string) {
	if f.Counts == nil {
		f.Counts = make(map[string]float64)
	}
	f.Counts[key]++
	f.Total++
}

// Probability returns the empirical probability of key, or 0 if unseen.
func (f *FreqTable) Probability(key string) float64 {
	if f.Total == 0 {
		return 0
	}
	return f.Counts[key] / f.Total
}

// SelfInformation returns -log2(p(key)) in bits: the "surprise" of key.
// An unseen key (p=0) is treated as maximally surprising and reported as
// +Inf, so callers should special-case the first-ever occurrence rather
// than compare it numerically.
func (f *FreqTable) SelfInformation(key string) float64 {
	p := f.Probability(key)
	if p <= 0 {
		return math.Inf(1)
	}
	return -math.Log2(p)
}

// Entropy returns the Shannon entropy (in bits) of the whole observed
// distribution: H = -sum(p_i * log2(p_i)).
func (f *FreqTable) Entropy() float64 {
	if f.Total == 0 {
		return 0
	}
	var h float64
	for _, c := range f.Counts {
		p := c / f.Total
		if p <= 0 {
			continue
		}
		h -= p * math.Log2(p)
	}
	return h
}
