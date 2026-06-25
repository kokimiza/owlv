package harvest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestExtractWhy(t *testing.T) {
	body := "Fixes the thing.\n\n## Why\n\nBecause the old behavior was wrong.\n\n## Test plan\n\n- ran it\n"
	got, ok := ExtractWhy(body)
	if !ok {
		t.Fatal("ExtractWhy: expected a match")
	}
	if got != "Because the old behavior was wrong." {
		t.Fatalf("ExtractWhy = %q", got)
	}
}

func TestExtractWhyAbsent(t *testing.T) {
	_, ok := ExtractWhy("Just a PR body with no sections.")
	if ok {
		t.Fatal("ExtractWhy: expected no match")
	}
}

func TestLooksArchitectural(t *testing.T) {
	if !LooksArchitectural("We decided to switch the queue to a different trade-off.") {
		t.Fatal("expected architectural signal to be detected")
	}
	if LooksArchitectural("Fixed a typo in the README.") {
		t.Fatal("expected no architectural signal")
	}
}

func TestAppendDecisionLogCreatesAndAppends(t *testing.T) {
	path := filepath.Join(t.TempDir(), "decision-log.md")
	entry := DecisionLogEntry{
		MergedAt: time.Date(2026, 6, 25, 0, 0, 0, 0, time.UTC),
		PRNumber: 42,
		PRTitle:  "Fix the thing",
		Why:      "Because reasons.",
	}
	if err := AppendDecisionLog(path, entry); err != nil {
		t.Fatalf("AppendDecisionLog: %v", err)
	}
	if err := AppendDecisionLog(path, entry); err != nil {
		t.Fatalf("AppendDecisionLog (second call): %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	content := string(data)
	if strings.Count(content, "PR #42") != 2 {
		t.Fatalf("expected two appended entries, got:\n%s", content)
	}
	if !strings.Contains(content, "Because reasons.") {
		t.Fatalf("missing Why text in:\n%s", content)
	}
}
