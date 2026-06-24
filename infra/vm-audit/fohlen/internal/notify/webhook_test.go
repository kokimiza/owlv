package notify

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"fohlen/internal/stats"
)

func TestNotifyWithoutWebhookFileIsNoop(t *testing.T) {
	n := NewNotifier(filepath.Join(t.TempDir(), "does-not-exist"))
	err := n.Notify(context.Background(), []stats.Detection{{Message: "test"}})
	if err != nil {
		t.Fatalf("expected no-op success when webhook unconfigured, got: %v", err)
	}
}

func TestNotifyPostsExpectedPayload(t *testing.T) {
	var mu sync.Mutex
	var received []string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var p webhookPayload
		if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
			t.Errorf("decode payload: %v", err)
		}
		mu.Lock()
		received = append(received, p.Text)
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	webhookFile := filepath.Join(t.TempDir(), "audit-notify-webhook")
	if err := os.WriteFile(webhookFile, []byte(srv.URL), 0o600); err != nil {
		t.Fatal(err)
	}

	n := NewNotifier(webhookFile)
	n.Client = &http.Client{Timeout: 2 * time.Second}

	err := n.Notify(context.Background(), []stats.Detection{
		{Message: "privilege escalation rate shift"},
	})
	if err != nil {
		t.Fatalf("Notify: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(received) != 1 {
		t.Fatalf("got %d webhook calls, want 1", len(received))
	}
	if !strings.Contains(received[0], "privilege escalation rate shift") {
		t.Errorf("payload text = %q, missing detection message", received[0])
	}
}

func TestNotifyReportsErrorOnNon2xx(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	webhookFile := filepath.Join(t.TempDir(), "audit-notify-webhook")
	os.WriteFile(webhookFile, []byte(srv.URL), 0o600)

	n := NewNotifier(webhookFile)
	if err := n.Notify(context.Background(), []stats.Detection{{Message: "x"}}); err == nil {
		t.Fatal("expected error on webhook 500 response")
	}
}
