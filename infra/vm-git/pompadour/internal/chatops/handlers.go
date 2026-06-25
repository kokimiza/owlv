package chatops

import (
	"context"
	"fmt"
	"strings"

	"pompadour/internal/forgejo"
	"pompadour/internal/store"
)

// Dispatch authorizes and executes cmd against issueNumber, posted by
// commenter. It is a no-op (not an error) for unrecognized command names
// — pompadour only reacts to the fixed set doc/pompadour.md §4.1 names,
// leaving any other "/" comment alone for other tooling/humans.
func Dispatch(ctx context.Context, fc *forgejo.Client, st *store.Store, issueNumber int64, commenter string, cmd Command) error {
	ok, err := Authorize(ctx, fc, cmd, commenter)
	if err != nil {
		return err
	}
	if !ok {
		return fc.CreateComment(ctx, issueNumber,
			fmt.Sprintf("@%s この操作はコラボレータ権限が必要です。", commenter))
	}

	switch cmd.Name {
	case "assign":
		return handleAssign(ctx, fc, issueNumber, commenter, cmd.Args)
	case "help":
		if strings.TrimSpace(cmd.Args) == "wanted" {
			return handleHelpWanted(ctx, fc, issueNumber)
		}
	case "retest":
		return handleRetest(ctx, fc, issueNumber)
	case "hold":
		return handleHold(ctx, fc, st, issueNumber)
	case "release-note":
		return handleReleaseNote(ctx, fc, issueNumber, commenter, cmd.Args)
	}
	return nil
}

func handleAssign(ctx context.Context, fc *forgejo.Client, issueNumber int64, commenter, args string) error {
	target := strings.TrimPrefix(strings.TrimSpace(args), "@")
	if target == "" {
		target = commenter
	}
	return fc.RequestReviewers(ctx, issueNumber, []string{target})
}

func handleHelpWanted(ctx context.Context, fc *forgejo.Client, issueNumber int64) error {
	if err := fc.AddLabels(ctx, issueNumber, []string{"help wanted"}); err != nil {
		return err
	}
	return fc.CreateComment(ctx, issueNumber, onboardingPointer)
}

// onboardingPointer re-surfaces the same guidance doc/pompadour.md §4.3
// shows first-time contributors, since "/help wanted" is most often
// invoked precisely to attract one.
const onboardingPointer = "この Issue は `help wanted` です。開発環境のセットアップは CLAUDE.md を参照してください。"

func handleRetest(ctx context.Context, fc *forgejo.Client, issueNumber int64) error {
	// Forgejo Actions re-run is invoked by the runner integration, not a
	// plain issues/comments call; pompadourd's scheduler (which has the
	// Actions run ID for this PR's latest workflow run) performs the
	// actual re-run API call. This handler's job is limited to
	// acknowledging the request so the author gets immediate feedback
	// even if the re-run itself is queued behind other scheduler work.
	return fc.CreateComment(ctx, issueNumber, "CI の再実行をキューに入れました。")
}

func handleHold(ctx context.Context, fc *forgejo.Client, st *store.Store, issueNumber int64) error {
	if err := fc.AddLabels(ctx, issueNumber, []string{"do-not-merge/hold"}); err != nil {
		return err
	}
	// Pull it out of the merge queue immediately rather than waiting for
	// the next scheduler cycle to notice the label — /hold is meant to
	// stop an in-flight merge attempt right away.
	return st.Dequeue(ctx, issueNumber)
}

func handleReleaseNote(ctx context.Context, fc *forgejo.Client, issueNumber int64, commenter, args string) error {
	if strings.TrimSpace(args) == "" {
		return nil
	}
	return fc.CreateComment(ctx, issueNumber,
		fmt.Sprintf("**release-note** (by @%s):\n\n%s", commenter, args))
}
