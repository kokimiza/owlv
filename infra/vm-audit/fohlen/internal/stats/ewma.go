package stats

// EWMA is an exponentially weighted moving average control chart
// (Roberts, 1959), used to detect small but sustained drifts that a single
// 3-sigma check on the raw value would miss (doc/audit_engine.md §4.3).
type EWMA struct {
	Lambda      float64
	Value       float64
	Initialized bool
}

// NewEWMA constructs an EWMA with decay factor lambda in (0, 1].
func NewEWMA(lambda float64) *EWMA {
	return &EWMA{Lambda: lambda}
}

// Update folds one observation in and returns the new EWMA value.
func (e *EWMA) Update(x float64) float64 {
	if !e.Initialized {
		e.Value = x
		e.Initialized = true
		return e.Value
	}
	e.Value = e.Lambda*x + (1-e.Lambda)*e.Value
	return e.Value
}
