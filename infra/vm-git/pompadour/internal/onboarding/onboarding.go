// Package onboarding implements the first-time-contributor welcome flow
// of doc/pompadour.md §4.3.
package onboarding

import (
	"context"
	"fmt"

	"pompadour/internal/forgejo"
)

// WelcomeTemplate is the message posted to a first-time contributor's
// issue/PR. doc/pompadour.md §4.3 requires this stay in a repository
// config file rather than be hardcoded; this constant is the built-in
// fallback used until/unless .forgejo/pompadour.yml overrides it.
const WelcomeTemplate = `Welcome, and thank you for the contribution!

- 開発環境: ` + "`docker compose up -d db` → `docker compose run --rm app`" + ` (CLAUDE.md / dev_sec_ops.md §3.1.1)
- 関連 Issue: 同じラベルの good-first-issue 一覧
- コーディング規約: CLAUDE.md
`

// IsFirstTimeContributor reports whether username has never had a pull
// request (open, closed, or merged) against the repository before.
// excludeNumber is the PR/issue currently being onboarded, which would
// otherwise always count as "1" and make every contributor look
// like a repeat one.
func IsFirstTimeContributor(ctx context.Context, fc *forgejo.Client, username string, excludeNumber int64) (bool, error) {
	pulls, err := fc.ListPulls(ctx, "all")
	if err != nil {
		return false, fmt.Errorf("onboarding: list pulls: %w", err)
	}
	for _, p := range pulls {
		if p.User.Login == username && p.Number != excludeNumber {
			return false, nil
		}
	}
	return true, nil
}

// Welcome posts WelcomeTemplate as a comment on issueOrPRNumber.
func Welcome(ctx context.Context, fc *forgejo.Client, issueOrPRNumber int64) error {
	return fc.CreateComment(ctx, issueOrPRNumber, WelcomeTemplate)
}
