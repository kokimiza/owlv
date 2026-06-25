// Package harvest implements doc/pompadour.md §5.7's Knowledge Harvest:
// after a PR merges, pull its "Why" explanation into
// doc/decision-log/ automatically (a mechanical transcription, no
// interpretation), and flag PRs that look architecturally significant
// for a human-confirmed ADR draft instead of committing one directly —
// doc/pompadour.md §5.7 forbids Pompadour from writing doc/adr/ itself.
package harvest

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

// whyHeading matches a "## Why" (or "### Why", any case) Markdown
// section heading, the convention doc/pompadour.md §5.7 expects PR
// authors to use.
var whyHeading = regexp.MustCompile(`(?im)^#{2,6}\s*why\s*$`)

// ExtractWhy returns the text of a PR body's "## Why" section, if
// present. It does not interpret or summarize the text — Pompadour
// transcribes verbatim; any judgment about what the text *means* is left
// to the human reader of doc/decision-log/.
func ExtractWhy(body string) (string, bool) {
	loc := whyHeading.FindStringIndex(body)
	if loc == nil {
		return "", false
	}
	rest := body[loc[1]:]
	// Stop at the next heading of equal-or-higher level, or end of body.
	if next := regexp.MustCompile(`(?m)^#{1,6}\s`).FindStringIndex(rest); next != nil {
		rest = rest[:next[0]]
	}
	text := strings.TrimSpace(rest)
	if text == "" {
		return "", false
	}
	return text, true
}

// adrSignalWords are terms whose presence in a "Why" section suggests an
// architectural decision worth an ADR, not just a routine fix. This is
// a coarse heuristic, not a classifier — false positives only cost a
// maintainer one /adr-confirm decision, which is the acceptable
// failure mode doc/pompadour.md §5.7 calls for (never auto-committing).
var adrSignalWords = []string{"architecture", "アーキテクチャ", "decided to", "trade-off", "トレードオフ", "方針"}

// LooksArchitectural applies the adrSignalWords heuristic to why.
func LooksArchitectural(why string) bool {
	lower := strings.ToLower(why)
	for _, w := range adrSignalWords {
		if strings.Contains(lower, strings.ToLower(w)) {
			return true
		}
	}
	return false
}

// DecisionLogEntry is one mechanical transcription appended to
// doc/decision-log/.
type DecisionLogEntry struct {
	MergedAt time.Time
	PRNumber int64
	PRTitle  string
	Why      string
}

// AppendDecisionLog appends entry to the markdown file at path, creating
// it (with a header) if it does not exist yet. This is the one
// auto-commit path doc/pompadour.md §5.7 allows — a flat transcription
// with no synthesis.
func AppendDecisionLog(path string, entry DecisionLogEntry) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		header := "# Decision Log\n\nPompadour が PR の `## Why` セクションをマージ時に転記したログ。解釈は加えない (doc/pompadour.md §5.7)。\n"
		if err := os.WriteFile(path, []byte(header), 0o644); err != nil {
			return fmt.Errorf("harvest: create %s: %w", path, err)
		}
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("harvest: open %s: %w", path, err)
	}
	defer f.Close()

	block := fmt.Sprintf("\n## %s — PR #%d: %s\n\n%s\n",
		entry.MergedAt.UTC().Format("2006-01-02"), entry.PRNumber, entry.PRTitle, entry.Why)
	if _, err := f.WriteString(block); err != nil {
		return fmt.Errorf("harvest: append %s: %w", path, err)
	}
	return nil
}

// ADRDraftComment is the comment Pompadour posts on a merged PR whose
// "Why" looks architectural, prompting a maintainer to run /adr-confirm
// rather than committing doc/adr/ itself.
func ADRDraftComment(why string) string {
	return fmt.Sprintf("このPRの変更はアーキテクチャ判断を含む可能性があります。\n\n> %s\n\n"+
		"ADR 起票案を doc/adr/ へ追加する場合は `/adr-confirm` を実行してください。Pompadour は確認なしに doc/adr/ を変更しません。",
		strings.ReplaceAll(why, "\n", "\n> "))
}
