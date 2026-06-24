package event

import (
	"testing"
	"time"
)

func TestParseAndClassify(t *testing.T) {
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	rules := DefaultRules()

	cases := []struct {
		name     string
		line     string
		wantCat  EventCategory
		wantHost string
		wantActor string
	}{
		{
			name:     "ssh accepted",
			line:     "Jun 24 10:00:00 ap_vm sshd[1234]: Accepted publickey for alice from 10.0.1.5 port 51000 ssh2",
			wantCat:  AuthSuccess,
			wantHost: "ap_vm",
			wantActor: "alice",
		},
		{
			name:     "ssh failed",
			line:     "Jun 24 10:00:01 ap_vm sshd[1234]: Failed password for root from 10.0.1.5 port 51001 ssh2",
			wantCat:  AuthFailure,
			wantHost: "ap_vm",
			wantActor: "root",
		},
		{
			name:     "sudo failure",
			line:     "Jun 24 10:00:02 build_vm sudo[42]: bob : authentication failure ; TTY=ttyp0 ; PWD=/root",
			wantCat:  PrivilegeEscalationAttempt,
			wantHost: "build_vm",
		},
		{
			name:     "owl integrity drift",
			line:     "Jun 24 10:00:03 host owl-integrity[1]: pf.conf hash mismatch detected",
			wantCat:  ConfigIntegrityDrift,
			wantHost: "host",
		},
		{
			name:     "unclassified",
			line:     "Jun 24 10:00:04 db_vm postgres[9]: checkpoint complete",
			wantCat:  Unclassified,
			wantHost: "db_vm",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec, ok := ParseSyslogLine(tc.line, now)
			if !ok {
				t.Fatalf("ParseSyslogLine failed to parse: %q", tc.line)
			}
			if rec.SourceHost != tc.wantHost {
				t.Errorf("SourceHost = %q, want %q", rec.SourceHost, tc.wantHost)
			}
			ev := Classify(rec, rules)
			if ev.Category != tc.wantCat {
				t.Errorf("Category = %v, want %v", ev.Category, tc.wantCat)
			}
			if tc.wantActor != "" && ev.Actor != tc.wantActor {
				t.Errorf("Actor = %q, want %q", ev.Actor, tc.wantActor)
			}
		})
	}
}

func TestParseSyslogLineRejectsGarbage(t *testing.T) {
	if _, ok := ParseSyslogLine("not a syslog line at all", time.Now()); ok {
		t.Fatal("expected parse failure for non-syslog input")
	}
}

func TestResolveTimestampYearRollover(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 30, 0, 0, time.UTC)
	rec, ok := ParseSyslogLine("Dec 31 23:55:00 host tag[1]: msg", now)
	if !ok {
		t.Fatal("parse failed")
	}
	if rec.Timestamp.Year() != 2025 {
		t.Errorf("expected rollback to previous year, got %d", rec.Timestamp.Year())
	}
}
