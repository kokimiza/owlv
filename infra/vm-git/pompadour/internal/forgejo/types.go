package forgejo

import "time"

// User mirrors the subset of Forgejo's swagger User schema pompadour
// actually reads.
type User struct {
	ID       int64  `json:"id"`
	Login    string `json:"login"`
	FullName string `json:"full_name"`
}

// Label mirrors Forgejo's Label schema.
type Label struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Color string `json:"color"`
}

// Issue mirrors the subset of Forgejo's Issue schema pompadour uses for
// both true issues and pull requests (Forgejo's /issues endpoint returns
// PRs too, distinguished by PullRequest != nil).
type Issue struct {
	ID        int64     `json:"id"`
	Number    int64     `json:"number"`
	Title     string    `json:"title"`
	Body      string    `json:"body"`
	State     string    `json:"state"`
	User      User      `json:"user"`
	Labels    []Label   `json:"labels"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// Comment mirrors Forgejo's Comment schema.
type Comment struct {
	ID        int64     `json:"id"`
	Body      string    `json:"body"`
	User      User      `json:"user"`
	CreatedAt time.Time `json:"created_at"`
}

// PullRequest mirrors the subset of Forgejo's PullRequest schema
// pompadour's merge queue and dependency graph need.
type PullRequest struct {
	ID        int64  `json:"id"`
	Number    int64  `json:"number"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	State     string `json:"state"`
	Mergeable bool   `json:"mergeable"`
	Merged    bool   `json:"merged"`
	Base      struct {
		Ref string `json:"ref"`
		Sha string `json:"sha"`
	} `json:"base"`
	Head struct {
		Ref string `json:"ref"`
		Sha string `json:"sha"`
	} `json:"head"`
	User          User   `json:"user"`
	RequestedRevs []User `json:"requested_reviewers"`
}

// MergePullOptions mirrors Forgejo's MergePullRequestOption.
type MergePullOptions struct {
	Do                string `json:"Do"` // "merge", "rebase", "squash", ...
	MergeTitleField   string `json:"MergeTitleField,omitempty"`
	MergeMessageField string `json:"MergeMessageField,omitempty"`
}
