//go:build !openbsd

package sysguard

// Non-OpenBSD builds (development on other platforms) get a no-op
// implementation. pompadourd is only ever deployed on OpenBSD's Git VM
// (doc/pompadour.md §3); these stubs exist purely so the rest of the
// codebase stays buildable/testable elsewhere, never as a substitute for
// the real confinement in production.
func Unveil(path, perms string) error { return nil }

func Lock() error { return nil }

func Pledge(promises string) error { return nil }
