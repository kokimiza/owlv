//go:build openbsd

// Package sysguard wraps OpenBSD's pledge(2)/unveil(2), the same hardening
// fohlen applies on the Audit VM (infra/vm-audit/fohlen/internal/sysguard).
// pompadourd runs on the Git VM (doc/dev_sec_ops.md §3.1) and confines
// itself to its config/state paths plus outbound network for the local
// Forgejo API — it never touches the audit_lan or internal_lan paths.
package sysguard

import "golang.org/x/sys/unix"

// Unveil restricts filesystem visibility to path with the given
// permission string (subset of "r","w","c","x").
func Unveil(path, perms string) error {
	return unix.Unveil(path, perms)
}

// Lock issues the final unveil(NULL, NULL), after which no further Unveil
// call may succeed.
func Lock() error {
	return unix.UnveilBlock()
}

// Pledge restricts the process to promises.
func Pledge(promises string) error {
	return unix.Pledge(promises, "")
}
