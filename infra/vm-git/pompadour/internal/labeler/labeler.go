// Package labeler implements the AI auto-labeling flow of
// doc/pompadour.md §4.2: classify a new issue's title/body into a
// closed set of categories, attach the result as `ai-suggested/<label>`
// (never the bare label — see Propose), and let a human confirm or let
// the 72h sweep auto-promote it.
package labeler

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"pompadour/internal/forgejo"
	"pompadour/internal/pinhole"
	"pompadour/internal/store"
)

// Categories is the closed label set doc/pompadour.md §4.2 names. The
// AI gateway is asked to choose from exactly this list, never to invent
// a new label.
var Categories = []string{"bug", "security", "enhancement", "documentation", "good-first-issue"}

const proposedPrefix = "ai-suggested/"

// classifyRequest/classifyResponse are the wire format exchanged with
// the isolated ai-gateway binary over internal/pinhole. Kept local to
// this package since no other caller needs them.
type classifyRequest struct {
	Title      string   `json:"title"`
	Body       string   `json:"body"`
	Categories []string `json:"categories"`
}

type classifyResponse struct {
	Labels []string `json:"labels"`
}

// Gateway abstracts the pinhole invocation so tests can substitute a
// fake without shelling out to a real script/binary.
type Gateway interface {
	Classify(ctx context.Context, title, body string, categories []string) ([]string, error)
}

// PinholeGateway is the production Gateway: it drives internal/pinhole.
type PinholeGateway struct {
	ScriptPath    string
	GatewayBinary string
	Timeout       time.Duration
}

func (g PinholeGateway) Classify(ctx context.Context, title, body string, categories []string) ([]string, error) {
	reqBody, err := json.Marshal(classifyRequest{Title: title, Body: body, Categories: categories})
	if err != nil {
		return nil, fmt.Errorf("labeler: encode request: %w", err)
	}
	out, err := pinhole.Invoke(ctx, g.ScriptPath, g.GatewayBinary, reqBody, g.Timeout)
	if err != nil {
		return nil, fmt.Errorf("labeler: invoke gateway: %w", err)
	}
	var resp classifyResponse
	if err := json.Unmarshal(out, &resp); err != nil {
		return nil, fmt.Errorf("labeler: decode response: %w", err)
	}
	return resp.Labels, nil
}

// ProposeForIssue classifies issue and attaches `ai-suggested/<label>`
// for each category the gateway returned, recording each as a pending
// proposal in st so the 72h auto-promotion sweep (Sweep) can find it.
// Labels outside Categories are dropped defensively — the gateway is
// untrusted output, and doc/pompadour.md §4.2 requires the label set to
// stay closed regardless of what the model says.
func ProposeForIssue(ctx context.Context, gw Gateway, fc *forgejo.Client, st *store.Store, issue forgejo.Issue) error {
	allowed := make(map[string]bool, len(Categories))
	for _, c := range Categories {
		allowed[c] = true
	}

	labels, err := gw.Classify(ctx, issue.Title, issue.Body, Categories)
	if err != nil {
		return fmt.Errorf("labeler: classify issue #%d: %w", issue.Number, err)
	}

	var proposed []string
	for _, l := range labels {
		if !allowed[l] {
			continue
		}
		name := proposedPrefix + l
		proposed = append(proposed, name)
		if err := st.PendingAILabel(ctx, issue.Number, l); err != nil {
			return fmt.Errorf("labeler: record proposal #%d/%s: %w", issue.Number, l, err)
		}
	}
	if len(proposed) == 0 {
		return nil
	}
	if err := fc.AddLabels(ctx, issue.Number, proposed); err != nil {
		return fmt.Errorf("labeler: attach proposed labels #%d: %w", issue.Number, err)
	}
	return nil
}

// PromoteCutoff returns the SQLite-formatted timestamp boundary for the
// 72-hour auto-promotion sweep (doc/pompadour.md §4.2), as of now.
func PromoteCutoff(now time.Time) string {
	return now.Add(-72 * time.Hour).UTC().Format("2006-01-02 15:04:05")
}

// Sweep promotes any proposal older than the 72h cutoff: it attaches the
// bare (confirmed) label and removes the `ai-suggested/` one, then marks
// the proposal confirmed in st.
func Sweep(ctx context.Context, fc *forgejo.Client, st *store.Store, now time.Time) error {
	pending, err := st.UnconfirmedAILabelsOlderThan(ctx, PromoteCutoff(now))
	if err != nil {
		return fmt.Errorf("labeler: sweep: list pending: %w", err)
	}
	for _, p := range pending {
		if err := fc.AddLabels(ctx, p.IssueNumber, []string{p.Label}); err != nil {
			return fmt.Errorf("labeler: sweep: promote #%d/%s: %w", p.IssueNumber, p.Label, err)
		}
		if err := fc.RemoveLabel(ctx, p.IssueNumber, proposedPrefix+p.Label); err != nil {
			return fmt.Errorf("labeler: sweep: remove proposal label #%d/%s: %w", p.IssueNumber, p.Label, err)
		}
		if err := st.ConfirmAILabel(ctx, p.IssueNumber, p.Label); err != nil {
			return fmt.Errorf("labeler: sweep: confirm #%d/%s: %w", p.IssueNumber, p.Label, err)
		}
	}
	return nil
}
