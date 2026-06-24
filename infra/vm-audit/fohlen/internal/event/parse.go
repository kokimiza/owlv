package event

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// syslogLine matches OpenBSD syslogd's on-disk format as written by the
// "*.* /var/log/audit/remote.log" selector in infra/vm-audit/setup.sh:
//
//	Jun 24 10:00:00 ap_vm sshd[1234]: Accepted publickey for alice from ...
//
// OpenBSD's default file destination does not record facility/priority in
// the line itself (it only appears for non-default targets such as
// "%dd %prog %msg"), so RawRecord deliberately carries no Facility field —
// fabricating one from a string that was never written would be incorrect.
var syslogLine = regexp.MustCompile(`^(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+(\S+)\s+([^:\[\s]+)(?:\[(\d+)\])?:\s?(.*)$`)

// ParseSyslogLine decomposes one syslog line into a RawRecord
// (doc/audit_engine.md §4.1 ①). It performs no semantic judgement.
//
// now is the wall-clock time used to resolve the year, which BSD syslog
// timestamps omit; it is a parameter (rather than time.Now()) so parsing
// stays deterministic and testable.
func ParseSyslogLine(line string, now time.Time) (RawRecord, bool) {
	m := syslogLine.FindStringSubmatch(line)
	if m == nil {
		return RawRecord{}, false
	}

	ts, ok := resolveTimestamp(m[1], now)
	if !ok {
		return RawRecord{}, false
	}

	return RawRecord{
		Timestamp:  ts,
		SourceHost: m[2],
		Tag:        m[3],
		PID:        m[4],
		Message:    strings.TrimSpace(m[5]),
		Raw:        line,
	}, true
}

// resolveTimestamp parses "Jan 2 15:04:05" against the year implied by now,
// rolling back one year if the resulting timestamp would otherwise sit more
// than a day in the future (handles ingestion running just after a
// Dec 31 -> Jan 1 rollover, when remote.log still holds prior-year lines).
func resolveTimestamp(s string, now time.Time) (time.Time, bool) {
	fields := strings.Fields(s)
	if len(fields) != 3 {
		return time.Time{}, false
	}
	candidate, err := time.ParseInLocation("Jan 2 15:04:05", fields[0]+" "+fields[1]+" "+fields[2], now.Location())
	if err != nil {
		return time.Time{}, false
	}
	candidate = candidate.AddDate(now.Year(), 0, 0)
	if candidate.After(now.Add(24 * time.Hour)) {
		candidate = candidate.AddDate(-1, 0, 0)
	}
	return candidate, true
}

// ParseInt returns 0 for an empty PID (kernel/no-pid log lines), never an
// error — PID is advisory metadata, not a parse-critical field.
func ParseInt(s string) int {
	if s == "" {
		return 0
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return n
}
