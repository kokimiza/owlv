package ingest

import (
	"encoding/json"
	"os"
)

// Checkpoint is the persisted ingest progress (doc/audit_engine.md §4.1,
// §7 "state/ingested.json"). It is the only thing that lets a restart
// resume without re-reading the whole log or re-ingesting a generation
// (idempotency, mirrored on cqrs.md §3.3's checkpoint pattern per the
// spec's own cross-reference).
type Checkpoint struct {
	// LiveOffset is the number of bytes of the active remote.log already
	// ingested.
	LiveOffset int64 `json:"live_offset"`
	// IngestedGenerations is the set of sealed .gz generation file names
	// fully ingested already; re-ingesting one of these must be a no-op.
	IngestedGenerations map[string]bool `json:"ingested_generations"`
	// PendingGenOffset records, for a generation file observed *before* it
	// was sealed into a .gz (i.e. still "remote.logN" right after a
	// newsyslog rotation), how many of its bytes were already ingested via
	// the live-tail path. When that same generation later appears as
	// "<name>.gz", ingestion must skip this many decompressed bytes to
	// avoid double-counting the rotation boundary
	// (doc/audit_engine.md §4.1 "ローテーション直前にまだ取り込んでいない末尾").
	PendingGenOffset map[string]int64 `json:"pending_gen_offset"`
}

func newCheckpoint() *Checkpoint {
	return &Checkpoint{
		IngestedGenerations: make(map[string]bool),
		PendingGenOffset:    make(map[string]int64),
	}
}

// LoadCheckpoint reads path, returning a fresh Checkpoint if it does not
// exist yet (first run).
func LoadCheckpoint(path string) (*Checkpoint, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return newCheckpoint(), nil
	}
	if err != nil {
		return nil, err
	}
	cp := newCheckpoint()
	if err := json.Unmarshal(data, cp); err != nil {
		return nil, err
	}
	if cp.IngestedGenerations == nil {
		cp.IngestedGenerations = make(map[string]bool)
	}
	if cp.PendingGenOffset == nil {
		cp.PendingGenOffset = make(map[string]int64)
	}
	return cp, nil
}

// Save writes the checkpoint atomically (write to a temp file, then
// rename) so a crash mid-write never leaves a truncated/corrupt
// checkpoint (doc/audit_engine.md §8 "クラッシュ復旧テスト").
func (c *Checkpoint) Save(path string) error {
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
