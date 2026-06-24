package stats

import "math"

// CUSUM is a two-sided cumulative-sum control chart (Page, 1954), used to
// detect a structural shift in the mean rate of an event category — the
// class of attack that stays under a fixed per-minute threshold but
// persists (doc/audit_engine.md §4.3, motivating owl-audit-detect.sh's
// "3回以上" threshold being insufficient).
//
// k is the allowed slack (typically half the shift size worth detecting,
// in units of the monitored quantity); h is the decision threshold.
type CUSUM struct {
	K, H   float64
	SHigh  float64
	SLow   float64
}

// NewCUSUM constructs a CUSUM chart with slack k and threshold h.
func NewCUSUM(k, h float64) *CUSUM {
	return &CUSUM{K: k, H: h}
}

// Update folds in one observation against the current process mean and
// reports whether the upper or lower cumulative sum has crossed H.
func (c *CUSUM) Update(x, mean float64) (alarmHigh, alarmLow bool) {
	c.SHigh = math.Max(0, c.SHigh+(x-mean)-c.K)
	c.SLow = math.Min(0, c.SLow+(x-mean)+c.K)
	return c.SHigh > c.H, -c.SLow > c.H
}

// Reset clears the accumulated sums, typically called after an alarm has
// been raised and acknowledged so the chart can detect the next shift.
func (c *CUSUM) Reset() {
	c.SHigh = 0
	c.SLow = 0
}
