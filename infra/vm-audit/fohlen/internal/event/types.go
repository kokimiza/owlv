// Package event defines the normalized audit-event model described in
// doc/audit_engine.md §4.1. RawRecord is the syntactic decomposition of a
// single syslog line; AuditEvent is the semantic classification built on
// top of it. Index (§4.2) and stats (§4.3) consume AuditEvent, never the
// raw syslog text directly.
package event

import "time"

// RawRecord is the syntactic decomposition of one syslog line. No semantic
// judgement is made at this stage (doc/audit_engine.md §4.1 ①).
type RawRecord struct {
	Timestamp  time.Time
	SourceHost string
	Tag        string
	PID        string
	Message    string
	// Raw is the original line, kept for full-text search fallback and as
	// the source of truth when classification fails.
	Raw string
}

// EventCategory is the finite category set assigned by Classify
// (doc/audit_engine.md §4.1 ②). The zero value is AuthSuccess; events that
// fail to parse or match no rule are explicitly Unclassified, never
// silently dropped.
type EventCategory int

const (
	AuthSuccess EventCategory = iota
	AuthFailure
	PrivilegeEscalationAttempt
	ConfigIntegrityDrift
	SessionForceTerminated
	Unclassified
)

func (c EventCategory) String() string {
	switch c {
	case AuthSuccess:
		return "AuthSuccess"
	case AuthFailure:
		return "AuthFailure"
	case PrivilegeEscalationAttempt:
		return "PrivilegeEscalationAttempt"
	case ConfigIntegrityDrift:
		return "ConfigIntegrityDrift"
	case SessionForceTerminated:
		return "SessionForceTerminated"
	case Unclassified:
		return "Unclassified"
	default:
		return "Unknown"
	}
}

// AuditEvent is the semantic unit that §4.2 (index) and §4.3 (stats) operate
// on (doc/audit_engine.md §4.1 ②, §4.3 lead paragraph).
type AuditEvent struct {
	Timestamp time.Time
	SourceHost string
	Category  EventCategory
	Actor     string
	Raw       RawRecord
}
