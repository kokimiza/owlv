// Command ai-gateway is the sole process in Pompadour allowed to call an
// external LLM API (doc/pompadour.md §7). It is deliberately a separate
// binary with no shared internal/ import from cmd/pompadourd — that
// separation is the point: pompadourd's process is never granted
// outbound internet access, only the ability to exec this binary via a
// host-controlled pinhole script (internal/pinhole) that opens a
// time-limited pf rule, runs this process, and closes the rule again
// regardless of outcome (the same DR-egress pattern as
// doc/dev_sec_ops.md §2.2). If this binary is compromised, the blast
// radius is "can talk to the configured LLM endpoint for the duration of
// one invocation" — not "has standing access to Pompadour's Forgejo
// token, SQLite state, or any internal/ package".
//
// Protocol: read one JSON request object from stdin, write one JSON
// response object to stdout, exit. internal/labeler's classifyRequest/
// classifyResponse shapes (mirrored below, not imported) define the
// "classify-issue" kind; doc/pompadour.md §5.4's AI Contributor flow is
// expected to add a "draft-pr" kind here in a later phase
// (doc/pompadour.md §8 Phase 4) without changing this isolation
// boundary.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// request/response intentionally duplicate the shape internal/labeler
// uses on the other side of the pinhole, rather than importing it — see
// the package doc above for why this binary imports nothing from
// pompadour's internal/ tree.
type request struct {
	Kind       string   `json:"kind"`
	Title      string   `json:"title"`
	Body       string   `json:"body"`
	Categories []string `json:"categories"`
}

type response struct {
	Labels []string `json:"labels"`
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "ai-gateway: %v\n", err)
		os.Exit(1)
	}
}

func run(in io.Reader, out io.Writer) error {
	endpoint := os.Getenv("AI_GATEWAY_ENDPOINT")
	apiKey := os.Getenv("AI_GATEWAY_API_KEY")
	if endpoint == "" || apiKey == "" {
		return fmt.Errorf("AI_GATEWAY_ENDPOINT and AI_GATEWAY_API_KEY must both be set")
	}

	data, err := io.ReadAll(in)
	if err != nil {
		return fmt.Errorf("read request: %w", err)
	}
	var req request
	if err := json.Unmarshal(data, &req); err != nil {
		return fmt.Errorf("decode request: %w", err)
	}

	switch req.Kind {
	case "classify-issue":
		labels, err := classify(endpoint, apiKey, req)
		if err != nil {
			return err
		}
		return json.NewEncoder(out).Encode(response{Labels: labels})
	default:
		return fmt.Errorf("unsupported kind %q", req.Kind)
	}
}

// classify calls the configured LLM endpoint and parses its answer down
// to the closed category list req.Categories — anything the model
// returns outside that list is dropped here too (defense in depth on
// top of internal/labeler's own filtering on the pompadourd side, since
// this process's output crosses the pinhole trust boundary).
func classify(endpoint, apiKey string, req request) ([]string, error) {
	prompt := fmt.Sprintf(
		"Classify the following issue into zero or more of these categories: %v.\nRespond with a JSON array of category strings only.\n\nTitle: %s\n\nBody:\n%s",
		req.Categories, req.Title, req.Body)

	body, err := json.Marshal(map[string]any{
		"model":      "claude-haiku-4-5",
		"max_tokens": 256,
		"messages":   []map[string]string{{"role": "user", "content": prompt}},
	})
	if err != nil {
		return nil, fmt.Errorf("encode llm request: %w", err)
	}

	httpReq, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build llm request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("x-api-key", apiKey)

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("call llm endpoint: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read llm response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("llm endpoint returned status %d: %s", resp.StatusCode, respBody)
	}

	labels, err := extractLabels(respBody, req.Categories)
	if err != nil {
		return nil, fmt.Errorf("parse llm response: %w", err)
	}
	return labels, nil
}

// llmContentResponse is the minimal shape ai-gateway expects back from
// the configured endpoint: a single text block holding a JSON array of
// label strings. The exact wire shape is provider-specific and
// deliberately kept narrow — ai-gateway talks to one configured
// endpoint, not a general multi-provider SDK.
type llmContentResponse struct {
	Content []struct {
		Text string `json:"text"`
	} `json:"content"`
}

func extractLabels(respBody []byte, allowed []string) ([]string, error) {
	var parsed llmContentResponse
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return nil, err
	}
	if len(parsed.Content) == 0 {
		return nil, fmt.Errorf("empty content in llm response")
	}
	var raw []string
	if err := json.Unmarshal([]byte(parsed.Content[0].Text), &raw); err != nil {
		return nil, fmt.Errorf("model did not return a JSON string array: %w", err)
	}

	allowedSet := make(map[string]bool, len(allowed))
	for _, a := range allowed {
		allowedSet[a] = true
	}
	var out []string
	for _, l := range raw {
		if allowedSet[l] {
			out = append(out, l)
		}
	}
	return out, nil
}
