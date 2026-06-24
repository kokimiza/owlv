package web

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGenerateHtpasswdUserCreatesAndAuthenticates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "etc", "audit-ui-htpasswd")

	password, err := GenerateHtpasswdUser(path, "auditor")
	if err != nil {
		t.Fatalf("GenerateHtpasswdUser: %v", err)
	}
	if password == "" {
		t.Fatal("expected non-empty generated password")
	}

	h, err := loadHtpasswd(path)
	if err != nil {
		t.Fatalf("loadHtpasswd: %v", err)
	}
	if !h.check("auditor", password) {
		t.Fatal("expected generated password to authenticate")
	}
	if h.check("auditor", "definitely-wrong") {
		t.Fatal("expected wrong password to be rejected")
	}
}

func TestGenerateHtpasswdUserRotatesWithoutDisturbingOthers(t *testing.T) {
	path := filepath.Join(t.TempDir(), "htpasswd")

	firstPass, err := GenerateHtpasswdUser(path, "alice")
	if err != nil {
		t.Fatalf("GenerateHtpasswdUser(alice): %v", err)
	}
	if _, err := GenerateHtpasswdUser(path, "bob"); err != nil {
		t.Fatalf("GenerateHtpasswdUser(bob): %v", err)
	}
	newAlicePass, err := GenerateHtpasswdUser(path, "alice")
	if err != nil {
		t.Fatalf("GenerateHtpasswdUser(alice rotate): %v", err)
	}
	if newAlicePass == firstPass {
		t.Fatal("expected rotation to produce a different password")
	}

	h, err := loadHtpasswd(path)
	if err != nil {
		t.Fatalf("loadHtpasswd: %v", err)
	}
	if h.check("alice", firstPass) {
		t.Fatal("old alice password should no longer authenticate after rotation")
	}
	if !h.check("alice", newAlicePass) {
		t.Fatal("rotated alice password should authenticate")
	}

	// Exactly one line per user (no duplicates, no cross-contamination from
	// the alice rotation touching bob's entry).
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected exactly 2 lines (alice, bob), got %d: %v", len(lines), lines)
	}
}
