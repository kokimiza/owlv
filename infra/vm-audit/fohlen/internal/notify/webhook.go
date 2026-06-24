// Package notify sends statistical detections to the existing webhook
// channel already used by owl-audit-detect.sh, per doc/audit_engine.md
// §4.3's requirement to reuse that channel rather than add a new notify
// path, and §6.2's "検知から通報までを単一プロセス内で完結させる".
package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"fohlen/internal/stats"
)

// Notifier posts Detections to the webhook URL read from WebhookFile, the
// same file infra/vm-audit/setup.sh's owl-audit-detect.sh reads
// (/etc/owlv/audit-notify-webhook). An empty/missing file means
// "detection only, no external notification" — the same safe-by-default
// stance owl-config.toml documents for notify_webhook_url.
type Notifier struct {
	WebhookFile string
	Client      *http.Client
}

// NewNotifier constructs a Notifier with a bounded-timeout HTTP client.
func NewNotifier(webhookFile string) *Notifier {
	return &Notifier{
		WebhookFile: webhookFile,
		Client:      &http.Client{Timeout: 5 * time.Second},
	}
}

type webhookPayload struct {
	Text string `json:"text"`
}

// Notify sends one POST per Detection. A send failure for one detection
// does not block the others; all errors are joined and returned so the
// caller can log them (no panics, no process exit — ingestion must keep
// running regardless of webhook reachability).
func (n *Notifier) Notify(ctx context.Context, detections []stats.Detection) error {
	if len(detections) == 0 {
		return nil
	}
	url, err := n.webhookURL()
	if err != nil {
		return fmt.Errorf("notify: read webhook file: %w", err)
	}
	if url == "" {
		return nil // not configured: detection-only, matches owl-audit-detect.sh's behavior
	}

	var errs []string
	for _, d := range detections {
		if err := n.send(ctx, url, d); err != nil {
			errs = append(errs, err.Error())
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("notify: %s", strings.Join(errs, "; "))
	}
	return nil
}

func (n *Notifier) send(ctx context.Context, url string, d stats.Detection) error {
	payload := webhookPayload{Text: fmt.Sprintf("[owlv audit/fohlen] %s", d.Message)}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := n.Client.Do(req)
	if err != nil {
		return fmt.Errorf("post to webhook: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("webhook returned status %d", resp.StatusCode)
	}
	return nil
}

func (n *Notifier) webhookURL() (string, error) {
	data, err := os.ReadFile(n.WebhookFile)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}
