package event

import "regexp"

// Rule is one entry of the classification rule table
// (doc/audit_engine.md §4.1 ②). Rules are evaluated in order; the first
// match wins. A nil pattern matches anything.
type Rule struct {
	Category EventCategory
	Tag      *regexp.Regexp // matched against RawRecord.Tag
	Message  *regexp.Regexp // matched against RawRecord.Message
	Actor    *regexp.Regexp // optional: first capture group becomes Actor
}

func (r Rule) matches(rec RawRecord) bool {
	if r.Tag != nil && !r.Tag.MatchString(rec.Tag) {
		return false
	}
	if r.Message != nil && !r.Message.MatchString(rec.Message) {
		return false
	}
	return true
}

func (r Rule) actor(rec RawRecord) string {
	if r.Actor == nil {
		return ""
	}
	m := r.Actor.FindStringSubmatch(rec.Message)
	if len(m) < 2 {
		return ""
	}
	return m[1]
}

// DefaultRules is the initial rule set, ported (not replacing) the grep
// patterns already operated by infra/vm-audit/setup.sh's
// owl-audit-detect.sh: authentication failure / incorrect password / BAD SU
// / sshd Accepted / owl-integrity (doc/audit_engine.md §4.1, table after
// the AuditEvent type definition).
//
// su/sudo/doas failures are classified as PrivilegeEscalationAttempt rather
// than AuthFailure: that is the more specific signal, and §4.3's stats
// table tracks the two categories independently, so a single event must
// not double-count into both. AuthFailure is reserved for sshd "Failed".
// This precedence is a rule-table detail, not a domain invariant — it is
// adjustable per doc/audit_engine.md §4.1's "設定ファイルで追加・調整可能".
func DefaultRules() []Rule {
	return []Rule{
		{
			Category: AuthSuccess,
			Tag:      regexp.MustCompile(`^sshd`),
			Message:  regexp.MustCompile(`Accepted`),
			Actor:    regexp.MustCompile(`for (\S+)`),
		},
		{
			Category: AuthFailure,
			Tag:      regexp.MustCompile(`^sshd`),
			Message:  regexp.MustCompile(`Failed`),
			Actor:    regexp.MustCompile(`for (\S+)`),
		},
		{
			Category: PrivilegeEscalationAttempt,
			Tag:      regexp.MustCompile(`^(su|sudo|doas)$`),
			Message:  nil,
			Actor:    regexp.MustCompile(`(?:user|as) (\S+)`),
		},
		{
			Category: PrivilegeEscalationAttempt,
			Message:  regexp.MustCompile(`(?i)authentication failure|incorrect password|BAD SU`),
		},
		{
			Category: ConfigIntegrityDrift,
			Tag:      regexp.MustCompile(`^owl-integrity`),
		},
		{
			Category: SessionForceTerminated,
			Tag:      regexp.MustCompile(`^owl-user-sync`),
			Message:  regexp.MustCompile(`(?i)pkill|terminat`),
		},
	}
}

// Classify assigns a Category to rec using rules in order, falling back to
// Unclassified when nothing matches. Unclassified events are still returned
// (never dropped) per doc/audit_engine.md §4.1's explicit requirement that
// the category exists so full-text search keeps them and the stats engine
// can monitor their frequency via Shannon entropy (§4.3).
func Classify(rec RawRecord, rules []Rule) AuditEvent {
	for _, r := range rules {
		if r.matches(rec) {
			return AuditEvent{
				Timestamp:  rec.Timestamp,
				SourceHost: rec.SourceHost,
				Category:   r.Category,
				Actor:      r.actor(rec),
				Raw:        rec,
			}
		}
	}
	return AuditEvent{
		Timestamp:  rec.Timestamp,
		SourceHost: rec.SourceHost,
		Category:   Unclassified,
		Raw:        rec,
	}
}
