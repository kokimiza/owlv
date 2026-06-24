// Package config loads /etc/owlv/fohlen.toml (doc/audit_engine.md §7, §9
// "UI ポート番号の確定"). It parses only the flat subset of TOML fohlen
// actually needs ([section] headers plus key = value pairs of string,
// int or float) rather than pulling in a general TOML dependency — the
// schema is small, fixed, and worth keeping dependency-free per
// hypervisor_rationale.md §1.1's "複雑性は脆弱性の温床" cited in
// doc/audit_engine.md §4.2.
package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Server ServerConfig
	Paths  PathsConfig
	Ingest IngestConfig
	Stats  StatsConfig
}

type ServerConfig struct {
	ListenAddr   string
	HtpasswdPath string
}

type PathsConfig struct {
	LogDir      string
	DBDir       string
	WebhookFile string
}

type IngestConfig struct {
	BulkCommitSize    int
	SQLiteCacheSizeKB int
	PollIntervalSec   int
}

type StatsConfig struct {
	ShewhartSigma       float64
	EWMALambda          float64
	CUSUMK              float64
	CUSUMH              float64
	EntropySurpriseBits float64
}

// Default returns the conservative defaults documented in
// doc/audit_engine.md §4.2 ("目安") and §9 ("初期値は保守的に設定").
func Default() Config {
	return Config{
		Server: ServerConfig{
			ListenAddr:   ":9090",
			HtpasswdPath: "/etc/owlv/audit-ui-htpasswd",
		},
		Paths: PathsConfig{
			LogDir:      "/var/log/audit",
			DBDir:       "/var/db/fohlen",
			WebhookFile: "/etc/owlv/audit-notify-webhook",
		},
		Ingest: IngestConfig{
			BulkCommitSize:    2000,
			SQLiteCacheSizeKB: 2000,
			PollIntervalSec:   60,
		},
		Stats: StatsConfig{
			ShewhartSigma:       3.0,
			EWMALambda:          0.2,
			CUSUMK:              0.5,
			CUSUMH:              5.0,
			EntropySurpriseBits: 8.0,
		},
	}
}

// Load reads path on top of Default(), so a partial file only overrides
// the keys it sets. A missing file is not an error: defaults apply
// (mirrors owl-config.toml's "空欄のままだと...安全側デフォルト" pattern).
func Load(path string) (Config, error) {
	cfg := Default()
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return cfg, nil
	}
	if err != nil {
		return cfg, fmt.Errorf("config: open %s: %w", path, err)
	}
	defer f.Close()

	section := ""
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			continue
		}
		key, val, ok := splitKV(line)
		if !ok {
			continue
		}
		if err := cfg.apply(section, key, val); err != nil {
			return cfg, fmt.Errorf("config: %s: %w", path, err)
		}
	}
	if err := scanner.Err(); err != nil {
		return cfg, fmt.Errorf("config: read %s: %w", path, err)
	}
	return cfg, nil
}

func splitKV(line string) (key, val string, ok bool) {
	before, after, ok0 := strings.Cut(line, "=")
	if !ok0 {
		return "", "", false
	}
	key = strings.TrimSpace(before)
	val = strings.TrimSpace(after)
	val = strings.TrimSuffix(val, "\"")
	val = strings.TrimPrefix(val, "\"")
	return key, val, true
}

func (c *Config) apply(section, key, val string) error {
	switch section {
	case "server":
		switch key {
		case "listen_addr":
			c.Server.ListenAddr = val
		case "htpasswd_path":
			c.Server.HtpasswdPath = val
		}
	case "paths":
		switch key {
		case "log_dir":
			c.Paths.LogDir = val
		case "db_dir":
			c.Paths.DBDir = val
		case "webhook_file":
			c.Paths.WebhookFile = val
		}
	case "ingest":
		switch key {
		case "bulk_commit_size":
			n, err := strconv.Atoi(val)
			if err != nil {
				return fmt.Errorf("ingest.bulk_commit_size: %w", err)
			}
			c.Ingest.BulkCommitSize = n
		case "sqlite_cache_size_kb":
			n, err := strconv.Atoi(val)
			if err != nil {
				return fmt.Errorf("ingest.sqlite_cache_size_kb: %w", err)
			}
			c.Ingest.SQLiteCacheSizeKB = n
		case "poll_interval_seconds":
			n, err := strconv.Atoi(val)
			if err != nil {
				return fmt.Errorf("ingest.poll_interval_seconds: %w", err)
			}
			c.Ingest.PollIntervalSec = n
		}
	case "stats":
		f, err := strconv.ParseFloat(val, 64)
		if err != nil {
			return fmt.Errorf("stats.%s: %w", key, err)
		}
		switch key {
		case "shewhart_sigma":
			c.Stats.ShewhartSigma = f
		case "ewma_lambda":
			c.Stats.EWMALambda = f
		case "cusum_k":
			c.Stats.CUSUMK = f
		case "cusum_h":
			c.Stats.CUSUMH = f
		case "entropy_surprise_bits":
			c.Stats.EntropySurpriseBits = f
		}
	}
	return nil
}
