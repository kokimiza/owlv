package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestLoadMissingFileReturnsDefault(t *testing.T) {
	cfg, err := Load("/nonexistent/pompadour.toml")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !reflect.DeepEqual(cfg, Default()) {
		t.Fatalf("expected defaults, got %+v", cfg)
	}
}

func TestLoadOverridesPartialKeys(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pompadour.toml")
	writeFile(t, path, `
[forgejo]
base_url = "http://127.0.0.1:3000"
owner = "owlv-admin"
repo = "owlv"

[reviewer]
pool = "alice, bob, carol"
max_assigned_count = 3
`)

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Forgejo.Repo != "owlv" {
		t.Errorf("Repo = %q, want owlv", cfg.Forgejo.Repo)
	}
	if cfg.Reviewer.MaxAssignedCount != 3 {
		t.Errorf("MaxAssignedCount = %d, want 3", cfg.Reviewer.MaxAssignedCount)
	}
	want := []string{"alice", "bob", "carol"}
	if len(cfg.Reviewer.Pool) != len(want) {
		t.Fatalf("Pool = %v, want %v", cfg.Reviewer.Pool, want)
	}
	for i, v := range want {
		if cfg.Reviewer.Pool[i] != v {
			t.Errorf("Pool[%d] = %q, want %q", i, cfg.Reviewer.Pool[i], v)
		}
	}
	// Unrelated default must be left untouched by the partial override.
	if cfg.Poll.ChatOpsSec != Default().Poll.ChatOpsSec {
		t.Errorf("ChatOpsSec was overridden unexpectedly: %d", cfg.Poll.ChatOpsSec)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
