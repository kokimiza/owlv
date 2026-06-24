package stats

import (
	"math"
	"testing"
	"time"

	"fohlen/internal/event"
)

func almostEqual(a, b, eps float64) bool {
	return math.Abs(a-b) <= eps
}

func TestWelfordMatchesClosedForm(t *testing.T) {
	xs := []float64{2, 4, 4, 4, 5, 5, 7, 9}
	var w Welford
	for _, x := range xs {
		w.Update(x)
	}
	// Known population: mean=5, sample variance=4.5714285714...
	if !almostEqual(w.Mean, 5.0, 1e-9) {
		t.Errorf("Mean = %v, want 5.0", w.Mean)
	}
	if !almostEqual(w.Variance(), 32.0/7.0, 1e-9) {
		t.Errorf("Variance = %v, want %v", w.Variance(), 32.0/7.0)
	}
}

func TestWelfordZScoreNeedsVariance(t *testing.T) {
	var w Welford
	w.Update(10)
	if z := w.ZScore(100); z != 0 {
		t.Errorf("ZScore with single sample (stddev=0) = %v, want 0", z)
	}
}

func TestEWMARespondsToSustainedDrift(t *testing.T) {
	e := NewEWMA(0.3)
	// Stationary baseline at 10, then a small persistent shift to 14.
	for range 20 {
		e.Update(10)
	}
	before := e.Value
	for range 20 {
		e.Update(14)
	}
	after := e.Value
	if !almostEqual(before, 10, 0.5) {
		t.Errorf("baseline EWMA = %v, want ~10", before)
	}
	if after <= before+1 {
		t.Errorf("EWMA did not track sustained drift: before=%v after=%v", before, after)
	}
}

func TestCUSUMDetectsInjectedShift(t *testing.T) {
	c := NewCUSUM(0.5, 5.0)
	mean := 10.0
	var alarmed bool
	var alarmAt int
	// Stationary at the mean: must not alarm.
	for i := range 30 {
		high, low := c.Update(mean, mean)
		if high || low {
			t.Fatalf("false alarm on stationary series at i=%d", i)
		}
	}
	// Inject a sustained +3 shift; CUSUM must eventually trip.
	for i := range 30 {
		high, _ := c.Update(mean+3, mean)
		if high {
			alarmed = true
			alarmAt = i
			break
		}
	}
	if !alarmed {
		t.Fatal("CUSUM failed to detect a sustained +3 shift within 30 samples")
	}
	if alarmAt > 10 {
		t.Errorf("CUSUM detection took too long: alarmed at sample %d", alarmAt)
	}
}

func TestShannonEntropyKnownDistribution(t *testing.T) {
	f := NewFreqTable()
	// Uniform over 2 symbols -> entropy of exactly 1 bit.
	for range 50 {
		f.Observe("a")
		f.Observe("b")
	}
	if !almostEqual(f.Entropy(), 1.0, 1e-9) {
		t.Errorf("Entropy = %v, want 1.0", f.Entropy())
	}
}

func TestSelfInformationOfUnseenKeyIsInfinite(t *testing.T) {
	f := NewFreqTable()
	f.Observe("a")
	if si := f.SelfInformation("never-seen"); !math.IsInf(si, 1) {
		t.Errorf("SelfInformation of unseen key = %v, want +Inf", si)
	}
}

func TestEngineObserveCategoryCountDetectsShift(t *testing.T) {
	eng := NewEngine(Config{ShewhartSigma: 3, EWMALambda: 0.3, CUSUMK: 0.5, CUSUMH: 5, EntropySurpriseBits: 8})
	key := RateKey{SourceHost: "ap_vm", Category: event.PrivilegeEscalationAttempt}
	now := time.Now()

	for range 30 {
		eng.ObserveCategoryCount(key, 1, now)
	}

	var sawDetection bool
	for range 30 {
		dets := eng.ObserveCategoryCount(key, 10, now)
		if len(dets) > 0 {
			sawDetection = true
			break
		}
	}
	if !sawDetection {
		t.Fatal("Engine failed to flag a sustained rate increase from 1/cycle to 10/cycle")
	}
}

func TestEngineIgnoresNonRateMonitoredCategory(t *testing.T) {
	eng := NewEngine(Config{ShewhartSigma: 3, EWMALambda: 0.3, CUSUMK: 0.5, CUSUMH: 5, EntropySurpriseBits: 8})
	key := RateKey{SourceHost: "ap_vm", Category: event.ConfigIntegrityDrift}
	if dets := eng.ObserveCategoryCount(key, 1000, time.Now()); dets != nil {
		t.Errorf("expected no detections for non-rate-monitored category, got %v", dets)
	}
}

func TestWERTwoOfThreeBeyond2Sigma(t *testing.T) {
	cases := []struct {
		name     string
		history  []float64
		wantHigh bool
		wantLow  bool
	}{
		{"empty", nil, false, false},
		{"single high outlier insufficient", []float64{2.5}, false, false},
		{"two of three high", []float64{1.0, 2.1, 2.2}, true, false},
		{"two of three low", []float64{-2.1, 0.5, -2.5}, false, true},
		{"mixed sides does not trigger either", []float64{2.5, -2.5, 0.1}, false, false},
		{"within window, all three high", []float64{2.1, 2.2, 2.3}, true, false},
		{"exactly at threshold does not count (strictly greater)", []float64{2.0, 2.0, 2.0}, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			high, low := werTwoOfThreeBeyond2Sigma(tc.history)
			if high != tc.wantHigh || low != tc.wantLow {
				t.Errorf("werTwoOfThreeBeyond2Sigma(%v) = (%v,%v), want (%v,%v)", tc.history, high, low, tc.wantHigh, tc.wantLow)
			}
		})
	}
}

func TestPushZHistoryCapsAtWindowSize(t *testing.T) {
	var h []float64
	for i := 1; i <= 5; i++ {
		h = pushZHistory(h, float64(i))
	}
	if len(h) != werWindowSize {
		t.Fatalf("len(h) = %d, want %d", len(h), werWindowSize)
	}
	want := []float64{3, 4, 5} // oldest (1,2) evicted
	for i, v := range want {
		if h[i] != v {
			t.Errorf("h[%d] = %v, want %v", i, h[i], v)
		}
	}
}

func TestEngineDetectsSustainedModerateShiftViaWER(t *testing.T) {
	eng := NewEngine(Config{ShewhartSigma: 3, EWMALambda: 0.3, CUSUMK: 0.5, CUSUMH: 100 /* disable CUSUM for this test */, EntropySurpriseBits: 8})
	key := RateKey{SourceHost: "ap_vm", Category: event.AuthFailure}
	now := time.Now()

	// A large baseline (30 samples) so that a handful of anomalous points
	// barely move the cumulative Welford mean/stddev — with a small baseline,
	// each anomalous sample drags the "normal" baseline toward itself almost
	// immediately, which is precisely why CUSUM (not z-score) is the right
	// tool for a truly sustained drift (doc/audit_engine.md §4.3). This test
	// targets the WER rule's actual niche: a short run of moderate (2σ–3σ)
	// points that individually never trip the harder single-point 3σ rule.
	for i := 0; i < 10; i++ {
		eng.ObserveCategoryCount(key, 10, now)
		eng.ObserveCategoryCount(key, 11, now)
		eng.ObserveCategoryCount(key, 9, now)
	}

	// A moderate shift (z ≈ 2.4, between 2σ and 3σ) that should trip the
	// "2 of 3 beyond 2σ" rule without ever tripping the single-point 3σ rule.
	var sawWER bool
	for i := 0; i < 3; i++ {
		dets := eng.ObserveCategoryCount(key, 12, now)
		for _, d := range dets {
			if d.Method == "wer-2of3" {
				sawWER = true
			}
			if d.Method == "zscore" {
				t.Errorf("single-point 3sigma rule fired for a moderate shift, test setup needs a smaller shift: %+v", d)
			}
		}
	}
	if !sawWER {
		t.Fatal("expected Western Electric 2-of-3 rule to fire for a sustained moderate shift")
	}
}

func TestEngineSnapshotRoundTrip(t *testing.T) {
	eng := NewEngine(Config{ShewhartSigma: 3, EWMALambda: 0.3, CUSUMK: 0.5, CUSUMH: 5, EntropySurpriseBits: 8})
	key := RateKey{SourceHost: "ap_vm", Category: event.AuthFailure}
	for i := range 10 {
		eng.ObserveCategoryCount(key, float64(i), time.Now())
	}
	eng.ObserveEvent(event.AuditEvent{SourceHost: "ap_vm", Category: event.AuthFailure, Timestamp: time.Now()})

	data, err := eng.MarshalJSON()
	if err != nil {
		t.Fatalf("MarshalJSON: %v", err)
	}
	restored, err := LoadEngine(data)
	if err != nil {
		t.Fatalf("LoadEngine: %v", err)
	}

	origSt := eng.stateFor(key)
	restoredSt := restored.stateFor(key)
	if !almostEqual(origSt.Welford.Mean, restoredSt.Welford.Mean, 1e-9) {
		t.Errorf("restored mean = %v, want %v", restoredSt.Welford.Mean, origSt.Welford.Mean)
	}
	if origSt.Welford.N != restoredSt.Welford.N {
		t.Errorf("restored N = %v, want %v", restoredSt.Welford.N, origSt.Welford.N)
	}
}
