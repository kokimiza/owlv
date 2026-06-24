package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadOverridesDefaultsPartially(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "fohlen.toml")
	body := `
[server]
listen_addr = ":9999"

[stats]
cusum_h = 7.5
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Server.ListenAddr != ":9999" {
		t.Errorf("ListenAddr = %q, want :9999", cfg.Server.ListenAddr)
	}
	if cfg.Stats.CUSUMH != 7.5 {
		t.Errorf("CUSUMH = %v, want 7.5", cfg.Stats.CUSUMH)
	}
	// Unset keys keep their defaults.
	if cfg.Server.HtpasswdPath != "/etc/owlv/audit-ui-htpasswd" {
		t.Errorf("HtpasswdPath = %q, want default", cfg.Server.HtpasswdPath)
	}
	if cfg.Stats.ShewhartSigma != 3.0 {
		t.Errorf("ShewhartSigma = %v, want default 3.0", cfg.Stats.ShewhartSigma)
	}
}

func TestLoadMissingFileReturnsDefaults(t *testing.T) {
	cfg, err := Load(filepath.Join(t.TempDir(), "does-not-exist.toml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Server.ListenAddr != Default().Server.ListenAddr {
		t.Errorf("expected defaults on missing file")
	}
}
