package web

import (
	"bufio"
	"crypto/rand"
	"encoding/base32"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

// htpasswd is an in-memory copy of /etc/owlv/audit-ui-htpasswd
// (doc/audit_engine.md §6.3: "user:bcrypt-hash" lines), the last line of
// defense behind the pf.conf host-only rule (§6.1) and the restricted SSH
// tunnel key (§6.2).
type htpasswd struct {
	hashes map[string][]byte // username -> bcrypt hash
}

func loadHtpasswd(path string) (*htpasswd, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	h := &htpasswd{hashes: make(map[string][]byte)}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		user, hash, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		h.hashes[user] = []byte(hash)
	}
	return h, scanner.Err()
}

func (h *htpasswd) check(user, password string) bool {
	hash, ok := h.hashes[user]
	if !ok {
		return false
	}
	return bcrypt.CompareHashAndPassword(hash, []byte(password)) == nil
}

// GenerateHtpasswdUser creates (or rotates) one user's entry in an
// apache-style "user:bcrypt-hash" file at path, generating a random
// password and returning it in plaintext exactly once — the file itself
// never stores anything recoverable. This is fohlen's own CLI-only
// counterpart to loadHtpasswd/check, used by `fohlen genpasswd` so
// provisioning (infra/vm-audit/setup.sh) never needs an external
// apache2-utils-style htpasswd(1) dependency on OpenBSD (doc/audit_engine.md
// §6.3, §9 "Basic認証の認証情報のローテーション運用").
func GenerateHtpasswdUser(path, username string) (plainPassword string, err error) {
	plainPassword, err = randomPassword()
	if err != nil {
		return "", fmt.Errorf("generate password: %w", err)
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(plainPassword), bcrypt.DefaultCost)
	if err != nil {
		return "", fmt.Errorf("bcrypt hash: %w", err)
	}

	lines, _ := readHtpasswdLines(path) // missing file: start from empty
	lines = upsertHtpasswdLine(lines, username, string(hash))

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", fmt.Errorf("create htpasswd dir: %w", err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write htpasswd: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return "", fmt.Errorf("rename htpasswd: %w", err)
	}
	return plainPassword, nil
}

func readHtpasswdLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		if line := strings.TrimSpace(scanner.Text()); line != "" {
			lines = append(lines, line)
		}
	}
	return lines, scanner.Err()
}

// upsertHtpasswdLine replaces the existing line for username, or appends a
// new one if absent, preserving every other user's entry untouched.
func upsertHtpasswdLine(lines []string, username, hash string) []string {
	newLine := username + ":" + hash
	for i, line := range lines {
		user, _, ok := strings.Cut(line, ":")
		if ok && user == username {
			lines[i] = newLine
			return lines
		}
	}
	return append(lines, newLine)
}

// randomPassword returns a 25-character base32 (RFC4648, no padding)
// password from 16 bytes of crypto/rand — base32 avoids the visually
// ambiguous characters base64 can produce, since this value is meant to be
// read and retyped by an operator (doc/audit_engine.md §6.3).
func randomPassword() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(buf), nil
}

// basicAuth wraps next with HTTP Basic auth, required on every route
// (doc/audit_engine.md §6.3: "UI 自体も無認証では応答しない").
func basicAuth(h *htpasswd, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || !h.check(user, pass) {
			w.Header().Set("WWW-Authenticate", `Basic realm="fohlen"`)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
