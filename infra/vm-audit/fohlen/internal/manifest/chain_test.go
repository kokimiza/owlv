package manifest

import (
	"os"
	"path/filepath"
	"testing"
)

func writeManifestChain(t *testing.T, dir string) (manifestPath string, genPaths []string) {
	t.Helper()
	gen0 := filepath.Join(dir, "remote.log.0.gz")
	gen1 := filepath.Join(dir, "remote.log.1.gz")
	os.WriteFile(gen0, []byte("generation-0-content"), 0o640)
	os.WriteFile(gen1, []byte("generation-1-content"), 0o640)

	hash0, err := sha256File(gen0)
	if err != nil {
		t.Fatal(err)
	}
	hash1, err := sha256File(gen1)
	if err != nil {
		t.Fatal(err)
	}

	manifestPath = filepath.Join(dir, "sealed-manifest.sha256")
	content := "2026-06-24T00:00:00Z\t" + gen0 + "\t" + hash0 + "\tprev=GENESIS\n" +
		"2026-06-24T00:10:00Z\t" + gen1 + "\t" + hash1 + "\tprev=" + hash0 + "\n"
	if err := os.WriteFile(manifestPath, []byte(content), 0o640); err != nil {
		t.Fatal(err)
	}
	return manifestPath, []string{gen0, gen1}
}

func TestVerifyValidChainPasses(t *testing.T) {
	dir := t.TempDir()
	manifestPath, _ := writeManifestChain(t, dir)

	entries, err := Parse(manifestPath)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2", len(entries))
	}
	results := Verify(entries)
	if !AllOK(results) {
		t.Fatalf("expected valid chain to pass, got %+v", results)
	}
}

func TestVerifyDetectsBrokenPrevLink(t *testing.T) {
	dir := t.TempDir()
	manifestPath, _ := writeManifestChain(t, dir)

	// Corrupt the second line's prev= reference.
	entries, err := Parse(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	entries[1].Prev = "0000000000000000000000000000000000000000000000000000000000000000"
	results := Verify(entries)
	if AllOK(results) {
		t.Fatal("expected broken prev-link to fail verification")
	}
	if results[1].PrevLinkOK {
		t.Error("expected entry[1].PrevLinkOK = false")
	}
}

func TestVerifyDetectsFileTampering(t *testing.T) {
	dir := t.TempDir()
	manifestPath, genPaths := writeManifestChain(t, dir)

	// Tamper with the sealed file's content after the manifest was written.
	if err := os.WriteFile(genPaths[0], []byte("tampered-content"), 0o640); err != nil {
		t.Fatal(err)
	}

	entries, err := Parse(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	results := Verify(entries)
	if AllOK(results) {
		t.Fatal("expected tampered file content to fail hash verification")
	}
	if results[0].FileHashOK {
		t.Error("expected entry[0].FileHashOK = false after tampering")
	}
}

func TestVerifyToleratesRolledOffGeneration(t *testing.T) {
	dir := t.TempDir()
	manifestPath, genPaths := writeManifestChain(t, dir)

	// Simulate newsyslog having rolled the oldest generation off disk
	// entirely (past 30-generation retention) — not a tamper signal.
	os.Remove(genPaths[0])

	entries, err := Parse(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	results := Verify(entries)
	if results[0].FileStillExists {
		t.Error("expected FileStillExists = false for removed generation")
	}
	if !results[0].FileHashOK {
		t.Error("absence of a rolled-off file must not itself fail verification")
	}
	if !AllOK(results) {
		t.Fatalf("expected chain to still pass overall, got %+v", results)
	}
}
