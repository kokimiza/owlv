package stats

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"fohlen/internal/event"
)

// RateKey identifies one (source_host, category) monitoring stream.
type RateKey struct {
	SourceHost string
	Category   event.EventCategory
}

func (k RateKey) String() string {
	return k.SourceHost + "/" + k.Category.String()
}

// rateMonitored is the subset of categories §4.3 tracks via
// Z-score/EWMA/CUSUM on unit-time counts (doc/audit_engine.md §4.3 table).
// PrivilegeEscalationAttempt and AuthFailure additionally get CUSUM.
var rateMonitored = map[event.EventCategory]bool{
	event.AuthSuccess:                 true,
	event.AuthFailure:                 true,
	event.PrivilegeEscalationAttempt:  true,
}

var cusumMonitored = map[event.EventCategory]bool{
	event.PrivilegeEscalationAttempt: true,
	event.AuthFailure:                true,
}

// RateState is the online state for one RateKey.
type RateState struct {
	Welford Welford
	EWMA    *EWMA
	CUSUM   *CUSUM // nil for categories not in cusumMonitored

	// RecentZ holds the last werWindowSize z-scores (oldest first), used by
	// the Western Electric "2 of 3" rule (doc/audit_engine.md §4.3 table
	// cites Western Electric Rules alongside the plain 3σ check). A single
	// 3σ outlier and a "2 of the last 3 beyond 2σ on the same side" pattern
	// are different anomaly shapes — the latter catches a sustained-but-
	// moderate shift that never crosses the harder 3σ bar on any one point.
	RecentZ []float64
}

// Detection is one statistically-flagged deviation, ready to hand to the
// notifier (doc/audit_engine.md §4.3 "実装要件").
type Detection struct {
	Key       string
	Method    string // "zscore" | "ewma-zscore" | "cusum-high" | "cusum-low" | "entropy"
	Value     float64
	Timestamp time.Time
	Message   string
}

// Engine aggregates all per-key online statistics plus the global
// frequency table used for Shannon entropy / self-information.
type Engine struct {
	mu sync.Mutex

	sigma       float64
	ewmaLambda  float64
	cusumK      float64
	cusumH      float64
	entropySurpriseBits float64 // self-information threshold for "novel combination" alerts

	rates map[string]*RateState
	freq  *FreqTable // keyed by RateKey.String()

	unclassifiedFreq *Welford // tracks unclassified rate-per-cycle, same rate-monitoring machinery
	unclassifiedEWMA *EWMA
}

// Config bundles the threshold parameters configurable via fohlen.toml
// (doc/audit_engine.md §4.3 "実装要件").
type Config struct {
	ShewhartSigma       float64
	EWMALambda          float64
	CUSUMK              float64
	CUSUMH              float64
	EntropySurpriseBits float64
}

// NewEngine constructs an empty Engine. Use LoadSnapshot to restore
// persisted state instead, when resuming after a restart.
func NewEngine(cfg Config) *Engine {
	return &Engine{
		sigma:               cfg.ShewhartSigma,
		ewmaLambda:          cfg.EWMALambda,
		cusumK:              cfg.CUSUMK,
		cusumH:              cfg.CUSUMH,
		entropySurpriseBits: cfg.EntropySurpriseBits,
		rates:               make(map[string]*RateState),
		freq:                NewFreqTable(),
		unclassifiedFreq:    &Welford{},
		unclassifiedEWMA:    NewEWMA(cfg.EWMALambda),
	}
}

func (e *Engine) stateFor(key RateKey) *RateState {
	k := key.String()
	st, ok := e.rates[k]
	if !ok {
		st = &RateState{EWMA: NewEWMA(e.ewmaLambda)}
		if cusumMonitored[key.Category] {
			st.CUSUM = NewCUSUM(e.cusumK, e.cusumH)
		}
		e.rates[k] = st
	}
	return st
}

// ObserveEvent folds one AuditEvent into the entropy frequency table. This
// is the per-event, constant-time update (doc/audit_engine.md §4.3
// "AuditEvent 1件ごとに定数時間で更新").
func (e *Engine) ObserveEvent(ev event.AuditEvent) *Detection {
	e.mu.Lock()
	defer e.mu.Unlock()

	key := RateKey{SourceHost: ev.SourceHost, Category: ev.Category}.String()
	surprise := e.freq.SelfInformation(key)
	e.freq.Observe(key)

	if surprise >= e.entropySurpriseBits {
		return &Detection{
			Key:       key,
			Method:    "entropy",
			Value:     surprise,
			Timestamp: ev.Timestamp,
			Message:   fmt.Sprintf("novel or rare (source_host,category) combination %s: self-information %.2f bits", key, surprise),
		}
	}
	return nil
}

// ObserveCategoryCount folds one unit-time count (e.g. events seen for this
// category in the latest ingest cycle) into the Shewhart/EWMA/CUSUM charts
// for that RateKey, returning any detections raised
// (doc/audit_engine.md §4.3, applies only to rateMonitored categories).
func (e *Engine) ObserveCategoryCount(key RateKey, count float64, t time.Time) []Detection {
	if !rateMonitored[key.Category] {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()

	st := e.stateFor(key)
	var detections []Detection

	// Z-score is evaluated against the *prior* mean/stddev, then the new
	// observation is folded in — judging an observation against a baseline
	// that already includes itself would dilute every anomaly toward zero.
	z := st.Welford.ZScore(count)
	if st.Welford.N >= 2 && abs(z) > e.sigma {
		detections = append(detections, Detection{
			Key: key.String(), Method: "zscore", Value: z, Timestamp: t,
			Message: fmt.Sprintf("%s: count=%.0f is %.1fσ from baseline mean=%.2f", key, count, z, st.Welford.Mean),
		})
	}
	if st.Welford.N >= 2 {
		st.RecentZ = pushZHistory(st.RecentZ, z)
		if high, low := werTwoOfThreeBeyond2Sigma(st.RecentZ); high || low {
			side := "上方"
			if low {
				side = "下方"
			}
			detections = append(detections, Detection{
				Key: key.String(), Method: "wer-2of3", Value: z, Timestamp: t,
				Message: fmt.Sprintf("%s: 直近3点中2点以上が%s2σを超える持続的なズレ (Western Electric rule, 単発の3σ未満でも検知)", key, side),
			})
		}
	}
	st.Welford.Update(count)

	ewmaVal := st.EWMA.Update(count)
	ewmaZ := st.Welford.ZScore(ewmaVal)
	if st.Welford.N >= 2 && abs(ewmaZ) > e.sigma {
		detections = append(detections, Detection{
			Key: key.String(), Method: "ewma-zscore", Value: ewmaZ, Timestamp: t,
			Message: fmt.Sprintf("%s: EWMA=%.2f drifted %.1fσ from baseline mean=%.2f", key, ewmaVal, ewmaZ, st.Welford.Mean),
		})
	}

	if st.CUSUM != nil {
		high, low := st.CUSUM.Update(count, st.Welford.Mean)
		if high {
			detections = append(detections, Detection{
				Key: key.String(), Method: "cusum-high", Value: st.CUSUM.SHigh, Timestamp: t,
				Message: fmt.Sprintf("%s: CUSUM upper shift detected (S+=%.2f > h=%.2f)", key, st.CUSUM.SHigh, e.cusumH),
			})
			st.CUSUM.Reset()
		}
		if low {
			detections = append(detections, Detection{
				Key: key.String(), Method: "cusum-low", Value: st.CUSUM.SLow, Timestamp: t,
				Message: fmt.Sprintf("%s: CUSUM lower shift detected (S-=%.2f)", key, st.CUSUM.SLow),
			})
			st.CUSUM.Reset()
		}
	}

	return detections
}

// ObserveUnclassifiedRate tracks the per-cycle count of Unclassified events
// across all hosts as its own rate series — the structural insurance policy
// described in doc/audit_engine.md §4.1: rising Unclassified frequency
// signals a gap in the rule table itself, independent of any specific
// category's baseline.
func (e *Engine) ObserveUnclassifiedRate(count float64, t time.Time) *Detection {
	e.mu.Lock()
	defer e.mu.Unlock()

	z := e.unclassifiedFreq.ZScore(count)
	e.unclassifiedFreq.Update(count)
	e.unclassifiedEWMA.Update(count)
	if e.unclassifiedFreq.N >= 2 && abs(z) > e.sigma {
		return &Detection{
			Key: "Unclassified", Method: "zscore", Value: z, Timestamp: t,
			Message: fmt.Sprintf("Unclassified rate count=%.0f is %.1fσ from baseline — rule table may need new categories", count, z),
		}
	}
	return nil
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

// werWindowSize/werHitsRequired/werSigmaThreshold implement the Western
// Electric "2 of 3" rule: 2 of the last 3 consecutive points more than 2
// standard deviations from the centerline, on the same side
// (doc/audit_engine.md §4.3 table; Shewhart's 3σ single-point rule is
// checked separately in ObserveCategoryCount).
const (
	werWindowSize     = 3
	werHitsRequired   = 2
	werSigmaThreshold = 2.0
)

// pushZHistory appends z to history, keeping only the most recent
// werWindowSize entries (oldest first).
func pushZHistory(history []float64, z float64) []float64 {
	history = append(history, z)
	if len(history) > werWindowSize {
		history = history[len(history)-werWindowSize:]
	}
	return history
}

// werTwoOfThreeBeyond2Sigma reports whether at least werHitsRequired of the
// points in history exceed werSigmaThreshold on the high side (high) or the
// low side (low).
func werTwoOfThreeBeyond2Sigma(history []float64) (high, low bool) {
	var hi, lo int
	for _, z := range history {
		switch {
		case z > werSigmaThreshold:
			hi++
		case z < -werSigmaThreshold:
			lo++
		}
	}
	return hi >= werHitsRequired, lo >= werHitsRequired
}

// RateSummary is the UI-facing view of one RateKey's current statistics
// (doc/audit_engine.md §4.4 dashboard requirement).
type RateSummary struct {
	Key       string
	Mean      float64
	StdDev    float64
	EWMA      float64
	CUSUMHigh float64
	CUSUMLow  float64
	HasCUSUM  bool
}

// EngineSummary is everything the dashboard partial needs to render in one
// call, without exposing Engine's internal locking to the web package.
type EngineSummary struct {
	Rates              []RateSummary
	UnclassifiedMean   float64
	UnclassifiedEWMA   float64
	Entropy            float64
}

// Summary returns a read-only snapshot for display
// (doc/audit_engine.md §4.4: "各カテゴリの現在の統計量...Unclassified の
// 出現率も常時表示する").
func (e *Engine) Summary() EngineSummary {
	e.mu.Lock()
	defer e.mu.Unlock()

	s := EngineSummary{
		UnclassifiedMean: e.unclassifiedFreq.Mean,
		UnclassifiedEWMA: e.unclassifiedEWMA.Value,
		Entropy:          e.freq.Entropy(),
	}
	for k, st := range e.rates {
		rs := RateSummary{
			Key:    k,
			Mean:   st.Welford.Mean,
			StdDev: st.Welford.StdDev(),
			EWMA:   st.EWMA.Value,
		}
		if st.CUSUM != nil {
			rs.HasCUSUM = true
			rs.CUSUMHigh = st.CUSUM.SHigh
			rs.CUSUMLow = st.CUSUM.SLow
		}
		s.Rates = append(s.Rates, rs)
	}
	return s
}

// snapshot is the JSON-serializable form of Engine state, persisted to
// state/stats.json (doc/audit_engine.md §4.3, §7) so a restart resumes
// without re-learning baselines from scratch.
type snapshot struct {
	Sigma               float64               `json:"sigma"`
	EWMALambda          float64               `json:"ewma_lambda"`
	CUSUMK              float64               `json:"cusum_k"`
	CUSUMH              float64               `json:"cusum_h"`
	EntropySurpriseBits float64               `json:"entropy_surprise_bits"`
	Rates               map[string]rateSnap   `json:"rates"`
	Freq                map[string]float64    `json:"freq_counts"`
	FreqTotal           float64               `json:"freq_total"`
	UnclassifiedWelford Welford               `json:"unclassified_welford"`
	UnclassifiedEWMA    float64               `json:"unclassified_ewma"`
}

type rateSnap struct {
	Welford    Welford   `json:"welford"`
	EWMA       float64   `json:"ewma"`
	EWMAInit   bool      `json:"ewma_init"`
	HasCUSUM   bool      `json:"has_cusum"`
	CUSUMSHigh float64   `json:"cusum_s_high"`
	CUSUMSLow  float64   `json:"cusum_s_low"`
	RecentZ    []float64 `json:"recent_z"`
}

// MarshalJSON serializes the full engine state.
func (e *Engine) MarshalJSON() ([]byte, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	s := snapshot{
		Sigma:               e.sigma,
		EWMALambda:          e.ewmaLambda,
		CUSUMK:              e.cusumK,
		CUSUMH:              e.cusumH,
		EntropySurpriseBits: e.entropySurpriseBits,
		Rates:               make(map[string]rateSnap, len(e.rates)),
		Freq:                e.freq.Counts,
		FreqTotal:           e.freq.Total,
		UnclassifiedWelford: *e.unclassifiedFreq,
		UnclassifiedEWMA:    e.unclassifiedEWMA.Value,
	}
	for k, st := range e.rates {
		rs := rateSnap{Welford: st.Welford, EWMA: st.EWMA.Value, EWMAInit: st.EWMA.Initialized, RecentZ: st.RecentZ}
		if st.CUSUM != nil {
			rs.HasCUSUM = true
			rs.CUSUMSHigh = st.CUSUM.SHigh
			rs.CUSUMSLow = st.CUSUM.SLow
		}
		s.Rates[k] = rs
	}
	return json.Marshal(s)
}

// LoadEngine restores an Engine from a previously marshaled snapshot.
func LoadEngine(data []byte) (*Engine, error) {
	var s snapshot
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	e := NewEngine(Config{
		ShewhartSigma:       s.Sigma,
		EWMALambda:          s.EWMALambda,
		CUSUMK:              s.CUSUMK,
		CUSUMH:              s.CUSUMH,
		EntropySurpriseBits: s.EntropySurpriseBits,
	})
	e.freq.Counts = s.Freq
	if e.freq.Counts == nil {
		e.freq.Counts = make(map[string]float64)
	}
	e.freq.Total = s.FreqTotal
	w := s.UnclassifiedWelford
	e.unclassifiedFreq = &w
	e.unclassifiedEWMA.Value = s.UnclassifiedEWMA
	e.unclassifiedEWMA.Initialized = true

	for k, rs := range s.Rates {
		st := &RateState{Welford: rs.Welford, EWMA: &EWMA{Lambda: e.ewmaLambda, Value: rs.EWMA, Initialized: rs.EWMAInit}, RecentZ: rs.RecentZ}
		if rs.HasCUSUM {
			st.CUSUM = &CUSUM{K: e.cusumK, H: e.cusumH, SHigh: rs.CUSUMSHigh, SLow: rs.CUSUMSLow}
		}
		e.rates[k] = st
	}
	return e, nil
}
