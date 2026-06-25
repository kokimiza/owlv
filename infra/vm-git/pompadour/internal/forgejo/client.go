// Package forgejo is a minimal REST client for the subset of the Forgejo
// API pompadour needs (issues, pulls, labels, comments, collaborators,
// branches). pompadourd talks to it over loopback (doc/pompadour.md §3:
// Pompadour and Forgejo share the Git VM, so there is no zone boundary
// to cross and no case for a general-purpose SDK dependency).
package forgejo

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// Client talks to one Forgejo repository's API.
type Client struct {
	BaseURL string // e.g. "http://127.0.0.1:3000"
	Owner   string
	Repo    string
	Token   string
	HTTP    *http.Client
}

// New builds a Client with a bounded-timeout HTTP client. baseURL must not
// have a trailing slash.
func New(baseURL, owner, repo, token string) *Client {
	return &Client{
		BaseURL: baseURL,
		Owner:   owner,
		Repo:    repo,
		Token:   token,
		HTTP:    &http.Client{Timeout: 15 * time.Second},
	}
}

// APIError is returned for any non-2xx response, carrying the status code
// so callers can distinguish e.g. 404 (not found) from 5xx (retry later).
type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("forgejo: status %d: %s", e.Status, e.Body)
}

func (c *Client) repoPath(format string, args ...any) string {
	prefix := fmt.Sprintf("/api/v1/repos/%s/%s/", url.PathEscape(c.Owner), url.PathEscape(c.Repo))
	return prefix + fmt.Sprintf(format, args...)
}

// do issues an authenticated request and decodes a JSON response body
// into out (when out is non-nil). A nil body is sent for GET/DELETE.
func (c *Client) do(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("forgejo: encode request: %w", err)
		}
		reader = bytes.NewReader(b)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
	if err != nil {
		return fmt.Errorf("forgejo: build request: %w", err)
	}
	req.Header.Set("Authorization", "token "+c.Token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("forgejo: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("forgejo: read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &APIError{Status: resp.StatusCode, Body: string(respBody)}
	}
	if out == nil || len(respBody) == 0 {
		return nil
	}
	if err := json.Unmarshal(respBody, out); err != nil {
		return fmt.Errorf("forgejo: decode response: %w", err)
	}
	return nil
}

// ListOpenIssues returns open issues (Forgejo's filter excludes PRs when
// the "type=issues" query is set).
func (c *Client) ListOpenIssues(ctx context.Context) ([]Issue, error) {
	var out []Issue
	err := c.do(ctx, http.MethodGet, c.repoPath("issues?state=open&type=issues"), nil, &out)
	return out, err
}

// ListOpenPulls returns open pull requests.
func (c *Client) ListOpenPulls(ctx context.Context) ([]PullRequest, error) {
	return c.ListPulls(ctx, "open")
}

// ListPulls returns pull requests in the given state ("open", "closed",
// or "all"). internal/onboarding uses "all" to check a contributor's
// full history, not just their currently-open PRs.
func (c *Client) ListPulls(ctx context.Context, state string) ([]PullRequest, error) {
	var out []PullRequest
	err := c.do(ctx, http.MethodGet, c.repoPath("pulls?state=%s", url.QueryEscape(state)), nil, &out)
	return out, err
}

// GetPull returns a single pull request by number.
func (c *Client) GetPull(ctx context.Context, number int64) (PullRequest, error) {
	var out PullRequest
	err := c.do(ctx, http.MethodGet, c.repoPath("pulls/%d", number), nil, &out)
	return out, err
}

// ListIssueComments returns the comments on an issue or PR (Forgejo
// shares the comment endpoint between the two).
func (c *Client) ListIssueComments(ctx context.Context, number int64) ([]Comment, error) {
	var out []Comment
	err := c.do(ctx, http.MethodGet, c.repoPath("issues/%d/comments", number), nil, &out)
	return out, err
}

// CreateComment posts a comment on an issue or PR.
func (c *Client) CreateComment(ctx context.Context, number int64, body string) error {
	return c.do(ctx, http.MethodPost, c.repoPath("issues/%d/comments", number),
		map[string]string{"body": body}, nil)
}

// AddLabels attaches labels (by name) to an issue or PR. Forgejo's label
// endpoint takes label IDs, so callers needing exact ID control should use
// AddLabelIDs; this convenience wrapper resolves names via ListLabels.
func (c *Client) AddLabels(ctx context.Context, number int64, names []string) error {
	all, err := c.ListLabels(ctx)
	if err != nil {
		return fmt.Errorf("forgejo: resolve labels: %w", err)
	}
	byName := make(map[string]int64, len(all))
	for _, l := range all {
		byName[l.Name] = l.ID
	}
	ids := make([]int64, 0, len(names))
	for _, n := range names {
		if id, ok := byName[n]; ok {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return nil
	}
	return c.do(ctx, http.MethodPost, c.repoPath("issues/%d/labels", number),
		map[string][]int64{"labels": ids}, nil)
}

// RemoveLabel detaches a single label (by name) from an issue or PR. A
// label that is not currently attached is treated as success, matching
// Forgejo's own idempotent behavior for this endpoint.
func (c *Client) RemoveLabel(ctx context.Context, number int64, name string) error {
	all, err := c.ListLabels(ctx)
	if err != nil {
		return fmt.Errorf("forgejo: resolve label %q: %w", name, err)
	}
	for _, l := range all {
		if l.Name == name {
			return c.do(ctx, http.MethodDelete, c.repoPath("issues/%d/labels/%d", number, l.ID), nil, nil)
		}
	}
	return nil
}

// ListLabels returns all labels defined on the repository.
func (c *Client) ListLabels(ctx context.Context) ([]Label, error) {
	var out []Label
	err := c.do(ctx, http.MethodGet, c.repoPath("labels"), nil, &out)
	return out, err
}

// CollaboratorPermission returns the access level Forgejo reports for
// username ("none", "read", "write", "admin", "owner"). ChatOps handlers
// (doc/pompadour.md §4.1) must call this before honoring any
// privilege-bearing slash command, to stop a non-collaborator from
// impersonating instructions via a comment.
func (c *Client) CollaboratorPermission(ctx context.Context, username string) (string, error) {
	var out struct {
		Permission string `json:"permission"`
	}
	path := c.repoPath("collaborators/%s/permission", url.PathEscape(username))
	if err := c.do(ctx, http.MethodGet, path, nil, &out); err != nil {
		var apiErr *APIError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			return "none", nil
		}
		return "", err
	}
	return out.Permission, nil
}

// RequestReviewers adds reviewers to a pull request.
func (c *Client) RequestReviewers(ctx context.Context, number int64, usernames []string) error {
	return c.do(ctx, http.MethodPost, c.repoPath("pulls/%d/requested_reviewers", number),
		map[string][]string{"reviewers": usernames}, nil)
}

// MergePull merges a pull request using the given strategy.
func (c *Client) MergePull(ctx context.Context, number int64, opts MergePullOptions) error {
	return c.do(ctx, http.MethodPost, c.repoPath("pulls/%d/merge", number), opts, nil)
}

// CreateBranch creates a new branch from an existing one, for the
// disposable batch-testing branches of doc/pompadour.md §5.2.
func (c *Client) CreateBranch(ctx context.Context, newName, oldName string) error {
	return c.do(ctx, http.MethodPost, c.repoPath("branches"),
		map[string]string{"new_branch_name": newName, "old_branch_name": oldName}, nil)
}

// DeleteBranch removes a branch. Batch-testing scratch branches
// (doc/pompadour.md §5.2) must always be deleted after use.
func (c *Client) DeleteBranch(ctx context.Context, name string) error {
	return c.do(ctx, http.MethodDelete, c.repoPath("branches/%s", url.PathEscape(name)), nil, nil)
}

// FormatInt is a tiny helper used by handlers that build comment bodies
// referencing issue/PR numbers without pulling in fmt at every call site.
func FormatInt(n int64) string {
	return strconv.FormatInt(n, 10)
}
