// Package config loads /etc/owlv/pompadour.toml. It parses only the flat
// subset of TOML pompadour actually needs ([section] headers plus
// key = value pairs of string, int or bool), the same hand-rolled
// approach fohlen uses (infra/vm-audit/fohlen/internal/config/config.go)
// to avoid pulling in a general TOML dependency for a small fixed schema
// (doc/hypervisor_rationale.md §1.1 "複雑性は脆弱性の温床").
package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Forgejo  ForgejoConfig
	Store    StoreConfig
	Poll     PollConfig
	AI       AIConfig
	Reviewer ReviewerConfig
}

// ForgejoConfig points at the local Forgejo instance. pompadourd runs on
// the same Git VM as Forgejo (doc/pompadour.md §3), so BaseURL is
// ordinarily a loopback address — there is no zone boundary to cross.
type ForgejoConfig struct {
	BaseURL  string
	Owner    string
	Repo     string
	TokenEnv string // env var name holding the bot token, never the token itself
}

type StoreConfig struct {
	Path string // SQLite file holding pompadour's own queue/load state
}

// PollConfig holds the per-feature poll intervals (doc/pompadour.md §3:
// polling, never inbound webhooks).
type PollConfig struct {
	ChatOpsSec        int
	MergeQueueSec     int
	ReviewBalancerSec int
	HarvestSec        int
}

// AIConfig configures the pinhole-isolated ai-gateway invocation
// (doc/pompadour.md §7). PompadourD never talks to the LLM endpoint
// itself; it only knows how to invoke this external helper.
type AIConfig struct {
	GatewayBinary string
	PinholeScript string
	TimeoutSec    int
}

// ReviewerConfig is the load-balancing pool (doc/pompadour.md §5.6).
// Membership changes are a human (maintainer) action, never automatic.
type ReviewerConfig struct {
	Pool             []string
	MaxAssignedCount int
}

// Default returns conservative defaults so a missing/partial config file
// still yields a safe, runnable configuration (mirrors fohlen's
// config.Default()).
func Default() Config {
	return Config{
		Forgejo: ForgejoConfig{
			BaseURL:  "http://127.0.0.1:3000",
			Owner:    "owlv-admin",
			Repo:     "owlv",
			TokenEnv: "POMPADOUR_FORGEJO_TOKEN",
		},
		Store: StoreConfig{
			Path: "/var/db/pompadour/pompadour.sqlite3",
		},
		Poll: PollConfig{
			ChatOpsSec:        20,
			MergeQueueSec:     30,
			ReviewBalancerSec: 300,
			HarvestSec:        600,
		},
		AI: AIConfig{
			GatewayBinary: "/usr/local/bin/pompadour-ai-gateway",
			PinholeScript: "/usr/local/sbin/owl-control.sh",
			TimeoutSec:    60,
		},
		Reviewer: ReviewerConfig{
			Pool:             nil,
			MaxAssignedCount: 5,
		},
	}
}

// Load reads path on top of Default(), so a partial file only overrides
// the keys it sets. A missing file is not an error: defaults apply.
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
		key, value, ok := splitKV(line)
		if !ok {
			continue
		}
		if err := apply(&cfg, section, key, value); err != nil {
			return cfg, fmt.Errorf("config: %s: %w", path, err)
		}
	}
	if err := scanner.Err(); err != nil {
		return cfg, fmt.Errorf("config: read %s: %w", path, err)
	}
	return cfg, nil
}

func splitKV(line string) (key, value string, ok bool) {
	idx := strings.Index(line, "=")
	if idx < 0 {
		return "", "", false
	}
	key = strings.TrimSpace(line[:idx])
	value = strings.TrimSpace(line[idx+1:])
	value = strings.Trim(value, `"`)
	return key, value, key != ""
}

func apply(cfg *Config, section, key, value string) error {
	switch section {
	case "forgejo":
		switch key {
		case "base_url":
			cfg.Forgejo.BaseURL = value
		case "owner":
			cfg.Forgejo.Owner = value
		case "repo":
			cfg.Forgejo.Repo = value
		case "token_env":
			cfg.Forgejo.TokenEnv = value
		}
	case "store":
		if key == "path" {
			cfg.Store.Path = value
		}
	case "poll":
		n, err := strconv.Atoi(value)
		if err != nil {
			return fmt.Errorf("[poll] %s: %w", key, err)
		}
		switch key {
		case "chatops_sec":
			cfg.Poll.ChatOpsSec = n
		case "merge_queue_sec":
			cfg.Poll.MergeQueueSec = n
		case "review_balancer_sec":
			cfg.Poll.ReviewBalancerSec = n
		case "harvest_sec":
			cfg.Poll.HarvestSec = n
		}
	case "ai":
		switch key {
		case "gateway_binary":
			cfg.AI.GatewayBinary = value
		case "pinhole_script":
			cfg.AI.PinholeScript = value
		case "timeout_sec":
			n, err := strconv.Atoi(value)
			if err != nil {
				return fmt.Errorf("[ai] timeout_sec: %w", err)
			}
			cfg.AI.TimeoutSec = n
		}
	case "reviewer":
		switch key {
		case "pool":
			cfg.Reviewer.Pool = splitList(value)
		case "max_assigned_count":
			n, err := strconv.Atoi(value)
			if err != nil {
				return fmt.Errorf("[reviewer] max_assigned_count: %w", err)
			}
			cfg.Reviewer.MaxAssignedCount = n
		}
	}
	return nil
}

// splitList parses a comma-separated value list (the schema is flat
// enough that a real TOML array parser would be overkill).
func splitList(value string) []string {
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// Token reads the bot token from the environment variable named by
// Forgejo.TokenEnv. The token itself is never read from the config file
// or committed to it (infra/vm-git/setup.sh issues per-purpose tokens;
// pompadour follows the same least-privilege split, doc/pompadour.md §7).
func (c ForgejoConfig) Token() (string, error) {
	v := os.Getenv(c.TokenEnv)
	if v == "" {
		return "", fmt.Errorf("config: env var %s is not set", c.TokenEnv)
	}
	return v, nil
}
