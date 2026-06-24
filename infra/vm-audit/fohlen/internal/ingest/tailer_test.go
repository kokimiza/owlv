package ingest

import (
	"compress/gzip"
	"context"
	"os"
	"path/filepath"
	"testing"

	"fohlen/internal/event"
	"fohlen/internal/index"
	"fohlen/internal/stats"
)

func newTestIngester(t *testing.T, logDir string) *Ingester {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "index.sqlite3")
	ix, err := index.Open(context.Background(), dbPath, 2000, 2000)
	if err != nil {
		t.Fatalf("index.Open: %v", err)
	}
	t.Cleanup(func() { ix.Close() })

	eng := stats.NewEngine(stats.Config{ShewhartSigma: 3, EWMALambda: 0.2, CUSUMK: 0.5, CUSUMH: 5, EntropySurpriseBits: 8})

	in := &Ingester{
		LogDir:         logDir,
		CheckpointPath: filepath.Join(t.TempDir(), "ingested.json"),
		Index:          ix,
		Engine:         eng,
		Rules:          event.DefaultRules(),
	}
	if err := in.Open(); err != nil {
		t.Fatalf("Open: %v", err)
	}
	return in
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o640); err != nil {
		t.Fatal(err)
	}
}

func writeGzip(t *testing.T, path, content string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	defer gz.Close()
	if _, err := gz.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
}

const sampleLine = "Jun 24 10:00:00 ap_vm sshd[1]: Accepted publickey for alice from 10.0.1.5 port 1 ssh2\n"

func TestTailLiveLogBasic(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "remote.log"), sampleLine+sampleLine)
	in := newTestIngester(t, dir)

	dets, err := in.RunCycle(context.Background())
	if err != nil {
		t.Fatalf("RunCycle: %v", err)
	}
	_ = dets

	results, err := in.Index.Search(context.Background(), index.SearchFilter{})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("got %d results, want 2", len(results))
	}
}

func TestTailLiveLogIsIncrementalAcrossCycles(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "remote.log")
	writeFile(t, logPath, sampleLine)
	in := newTestIngester(t, dir)

	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("first RunCycle: %v", err)
	}
	// Append more without truncating; offset should resume, not duplicate.
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(sampleLine)
	f.Close()

	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("second RunCycle: %v", err)
	}

	results, err := in.Index.Search(context.Background(), index.SearchFilter{})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("got %d results, want 2 (no duplicate, no loss)", len(results))
	}
}

func TestIngestSealedGenerationIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "remote.log"), "")
	writeGzip(t, filepath.Join(dir, "remote.log.0.gz"), sampleLine+sampleLine+sampleLine)
	in := newTestIngester(t, dir)

	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("first RunCycle: %v", err)
	}
	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("second RunCycle (re-ingest attempt): %v", err)
	}

	results, err := in.Index.Search(context.Background(), index.SearchFilter{})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) != 3 {
		t.Fatalf("got %d results after re-ingesting same generation twice, want 3 (idempotent)", len(results))
	}
}

func TestRotationRecoversPreRotationTail(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "remote.log")
	// First cycle ingests one line from the live log.
	writeFile(t, logPath, sampleLine)
	in := newTestIngester(t, dir)
	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("first RunCycle: %v", err)
	}

	// Simulate newsyslog rotation: old content (with one more appended,
	// unread, line) moves to remote.log.0; remote.log is truncated to 0.
	writeFile(t, filepath.Join(dir, "remote.log.0"), sampleLine+sampleLine)
	writeFile(t, logPath, "")

	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("second RunCycle (post-rotation): %v", err)
	}

	results, err := in.Index.Search(context.Background(), index.SearchFilter{})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	// 1 (first cycle) + 1 (recovered unread tail from remote.log.0) = 2.
	if len(results) != 2 {
		t.Fatalf("got %d results, want 2 (pre-rotation tail recovered, no loss/dup)", len(results))
	}

	// Now that remote.log.0 gets sealed into .gz, the already-recovered
	// bytes must be skipped.
	writeGzip(t, filepath.Join(dir, "remote.log.0.gz"), sampleLine+sampleLine)
	os.Remove(filepath.Join(dir, "remote.log.0"))
	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("third RunCycle (sealed generation): %v", err)
	}

	results, err = in.Index.Search(context.Background(), index.SearchFilter{})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("got %d results after sealing rotated file, want 2 (skip-offset prevented duplication)", len(results))
	}
}

func TestCheckpointSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ingested.json")
	cp := newCheckpoint()
	cp.LiveOffset = 12345
	cp.IngestedGenerations["remote.log.3.gz"] = true
	cp.PendingGenOffset["remote.log.0"] = 99

	if err := cp.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}
	loaded, err := LoadCheckpoint(path)
	if err != nil {
		t.Fatalf("LoadCheckpoint: %v", err)
	}
	if loaded.LiveOffset != 12345 {
		t.Errorf("LiveOffset = %d, want 12345", loaded.LiveOffset)
	}
	if !loaded.IngestedGenerations["remote.log.3.gz"] {
		t.Errorf("expected remote.log.3.gz to be marked ingested")
	}
	if loaded.PendingGenOffset["remote.log.0"] != 99 {
		t.Errorf("PendingGenOffset = %d, want 99", loaded.PendingGenOffset["remote.log.0"])
	}
}

func TestCleanupDeletedGenerationRemovesIndexRows(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "remote.log"), "")
	genPath := filepath.Join(dir, "remote.log.0.gz")
	writeGzip(t, genPath, sampleLine)
	in := newTestIngester(t, dir)

	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("RunCycle: %v", err)
	}
	results, _ := in.Index.Search(context.Background(), index.SearchFilter{})
	if len(results) != 1 {
		t.Fatalf("got %d results, want 1", len(results))
	}

	// newsyslog has rolled this generation off disk entirely.
	os.Remove(genPath)
	if _, err := in.RunCycle(context.Background()); err != nil {
		t.Fatalf("RunCycle after generation deletion: %v", err)
	}

	results, _ = in.Index.Search(context.Background(), index.SearchFilter{})
	if len(results) != 0 {
		t.Fatalf("got %d results after generation deletion, want 0 (index should shrink with the original)", len(results))
	}
}
