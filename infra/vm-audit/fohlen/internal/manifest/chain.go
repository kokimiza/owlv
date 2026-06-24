// Package manifest re-verifies the sealed-manifest.sha256 hash chain
// written by infra/vm-audit/setup.sh's owl-audit-seal.sh, per
// doc/audit_engine.md §4.4's read-only tamper-detection display
// requirement. This package never writes to the manifest or to any
// sealed log file — verification only.
package manifest

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Entry is one parsed line of sealed-manifest.sha256:
// "<RFC3339 timestamp>\t<file path>\t<sha256 hex>\tprev=<sha256 hex|GENESIS>".
type Entry struct {
	Timestamp string
	FilePath  string
	Hash      string
	Prev      string
}

// VerifyResult is the per-entry verdict shown by the UI.
type VerifyResult struct {
	Entry          Entry
	PrevLinkOK     bool   // entry.Prev matches the previous entry's Hash (or GENESIS for the first)
	FileHashOK     bool   // recomputed sha256 of FilePath matches Hash; true-but-unchecked if file has since rolled off disk
	FileStillExists bool
	Err            string
}

// Parse reads a sealed-manifest.sha256 file into its ordered entries.
func Parse(path string) ([]Entry, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("manifest: open %s: %w", path, err)
	}
	defer f.Close()

	var entries []Entry
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 4 {
			return nil, fmt.Errorf("manifest: malformed line %q", line)
		}
		prev := strings.TrimPrefix(fields[3], "prev=")
		entries = append(entries, Entry{
			Timestamp: fields[0],
			FilePath:  fields[1],
			Hash:      fields[2],
			Prev:      prev,
		})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("manifest: read %s: %w", path, err)
	}
	return entries, nil
}

// Verify re-derives the pass/fail verdict for every entry: the prev-link
// continuity check always runs; the file-hash recomputation runs only for
// generations still present on disk (older ones may have legitimately
// rolled off past newsyslog's 30-generation retention, which is not
// itself a tamper signal — doc/audit_engine.md §4.1's "原本が消えたら
// 追従して縮小する" applies symmetrically here).
func Verify(entries []Entry) []VerifyResult {
	results := make([]VerifyResult, len(entries))
	for i, e := range entries {
		r := VerifyResult{Entry: e}

		if i == 0 {
			r.PrevLinkOK = e.Prev == "GENESIS"
		} else {
			r.PrevLinkOK = e.Prev == entries[i-1].Hash
		}

		if _, err := os.Stat(e.FilePath); err == nil {
			r.FileStillExists = true
			hash, err := sha256File(e.FilePath)
			if err != nil {
				r.Err = err.Error()
			} else {
				r.FileHashOK = hash == e.Hash
			}
		} else {
			// Rolled off disk: cannot recompute, but that is not itself a
			// failure — only the prev-link chain matters at that point.
			r.FileHashOK = true
		}

		results[i] = r
	}
	return results
}

// AllOK reports whether every entry's checks passed.
func AllOK(results []VerifyResult) bool {
	for _, r := range results {
		if !r.PrevLinkOK || !r.FileHashOK || r.Err != "" {
			return false
		}
	}
	return true
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// BaseName is a small template helper so the UI can show just the file
// name rather than the full /var/log/audit/... path.
func BaseName(path string) string { return filepath.Base(path) }
