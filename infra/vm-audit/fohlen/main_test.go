package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"path/filepath"
	"testing"

	"fohlen/internal/event"
	"fohlen/internal/index"
)

func TestSumLogBytesSumsOnlyRemoteLogFiles(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "remote.log"), "0123456789")        // 10 bytes
	writeFile(t, filepath.Join(dir, "remote.log.0.gz"), "01234")        // 5 bytes
	writeFile(t, filepath.Join(dir, "sealed-manifest.sha256"), "ignore-me-not-a-log-file")
	if err := os.Mkdir(filepath.Join(dir, "remote.log.subdir"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := sumLogBytes(dir)
	if err != nil {
		t.Fatalf("sumLogBytes: %v", err)
	}
	if got != 15 {
		t.Errorf("sumLogBytes = %d, want 15 (remote.log + remote.log.0.gz only, directory excluded)", got)
	}
}

func TestSumLogBytesMissingDirIsZeroNotError(t *testing.T) {
	got, err := sumLogBytes(filepath.Join(t.TempDir(), "does-not-exist"))
	if err != nil {
		t.Fatalf("expected no error for missing log dir, got: %v", err)
	}
	if got != 0 {
		t.Errorf("got %d, want 0", got)
	}
}

func TestHealthCheckIndexSizeWarnsOnExcessiveRatio(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, "log")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// A tiny original log (a handful of bytes) makes it trivial for the
	// index file's own SQLite overhead alone to exceed the 3x ratio.
	writeFile(t, filepath.Join(logDir, "remote.log"), "x")

	ctx := context.Background()
	ix, err := index.Open(ctx, filepath.Join(dir, "index.sqlite3"), 2000, 2000)
	if err != nil {
		t.Fatalf("index.Open: %v", err)
	}
	defer ix.Close()
	if err := ix.BulkInsert(ctx, []event.AuditEvent{{Raw: event.RawRecord{Raw: "some message"}}}, "remote.log"); err != nil {
		t.Fatalf("BulkInsert: %v", err)
	}

	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	if err := healthCheckIndexSize(ctx, logDir, ix); err != nil {
		t.Fatalf("healthCheckIndexSize: %v", err)
	}
	if !bytes.Contains(buf.Bytes(), []byte("WARNING")) {
		t.Errorf("expected a WARNING log line for a tiny original log dwarfed by the SQLite index, got: %q", buf.String())
	}
}

func TestHealthCheckIndexSizeSilentWhenNoLogsYet(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()
	ix, err := index.Open(ctx, filepath.Join(dir, "index.sqlite3"), 2000, 2000)
	if err != nil {
		t.Fatalf("index.Open: %v", err)
	}
	defer ix.Close()

	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	if err := healthCheckIndexSize(ctx, filepath.Join(dir, "no-such-log-dir"), ix); err != nil {
		t.Fatalf("healthCheckIndexSize: %v", err)
	}
	if buf.Len() != 0 {
		t.Errorf("expected no log output when there is no original log volume yet, got: %q", buf.String())
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o640); err != nil {
		t.Fatal(err)
	}
}
