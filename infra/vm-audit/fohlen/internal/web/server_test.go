package web

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/bcrypt"

	"fohlen/internal/index"
	"fohlen/internal/stats"
)

func writeHtpasswd(t *testing.T, dir, user, password string) string {
	t.Helper()
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "htpasswd")
	if err := os.WriteFile(path, []byte(user+":"+string(hash)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func newTestServer(t *testing.T) http.Handler {
	t.Helper()
	dir := t.TempDir()
	htpasswdPath := writeHtpasswd(t, dir, "auditor", "s3cret")

	ix, err := index.Open(context.Background(), filepath.Join(dir, "index.sqlite3"), 2000, 2000)
	if err != nil {
		t.Fatalf("index.Open: %v", err)
	}
	t.Cleanup(func() { ix.Close() })

	eng := stats.NewEngine(stats.Config{ShewhartSigma: 3, EWMALambda: 0.2, CUSUMK: 0.5, CUSUMH: 5, EntropySurpriseBits: 8})
	manifestPath := filepath.Join(dir, "sealed-manifest.sha256")

	h, err := New(htpasswdPath, ix, eng, manifestPath)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return h
}

func TestUnauthenticatedRequestIsRejected(t *testing.T) {
	h := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestAuthenticatedRequestsServePages(t *testing.T) {
	h := newTestServer(t)

	for _, path := range []string{"/", "/search", "/integrity", "/partials/dashboard", "/partials/integrity"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.SetBasicAuth("auditor", "s3cret")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("%s: status = %d, want 200, body=%s", path, rec.Code, rec.Body.String())
		}
	}
}

func TestWrongPasswordIsRejected(t *testing.T) {
	h := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.SetBasicAuth("auditor", "wrong-password")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}
