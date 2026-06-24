//go:build openbsd

// Package sysguard wraps OpenBSD's pledge(2)/unveil(2) per
// doc/audit_engine.md §7's required startup sequence. fohlen only ever
// runs on OpenBSD (the Audit VM); this file is the real implementation.
package sysguard

import "golang.org/x/sys/unix"

// Unveil restricts filesystem visibility to path with the given
// permission string (subset of "r","w","c","x").
func Unveil(path, perms string) error {
	return unix.Unveil(path, perms)
}

// Lock issues the final unveil(NULL, NULL), after which no further Unveil
// call may succeed. doc/audit_engine.md §7 mandates this happen only
// after the SQLite connection has been opened and warmed up, since
// modernc.org/sqlite's internal init can touch paths outside the
// declared set (e.g. TMPDIR) before that point.
func Lock() error {
	return unix.UnveilBlock()
}

// Pledge restricts the process to promises (and, for re-exec scenarios
// fohlen does not use, execpromises).
func Pledge(promises string) error {
	return unix.Pledge(promises, "")
}
