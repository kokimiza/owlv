// Package chatops implements the slash-command dispatch of
// doc/pompadour.md §4.1. Commands are recognized from comment text;
// privileged ones are gated on the commenter's collaborator permission
// (checked against Forgejo itself, never trusted from the comment).
package chatops

import (
	"context"
	"fmt"
	"strings"

	"pompadour/internal/forgejo"
)

// Command is one parsed slash command (the leading word) plus its
// remaining argument text.
type Command struct {
	Name string
	Args string
}

// Parse extracts a Command from a comment body if it starts with "/".
// Only the first line is considered, matching how Prow/bors parse
// ChatOps comments — trailing comment prose after the command is not a
// continuation of it.
func Parse(body string) (Command, bool) {
	line := strings.TrimSpace(strings.SplitN(body, "\n", 2)[0])
	if !strings.HasPrefix(line, "/") {
		return Command{}, false
	}
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return Command{}, false
	}
	name := strings.TrimPrefix(fields[0], "/")
	args := strings.TrimSpace(strings.TrimPrefix(line, fields[0]))
	return Command{Name: name, Args: args}, true
}

// privileged is the set of commands doc/pompadour.md §4.1 restricts to
// collaborators ("コラボレータ以上"). "/release-note" is intentionally
// excluded — it is restricted to the PR author instead, checked
// separately by its handler.
var privileged = map[string]bool{
	"assign": true,
	"help":   true, // "/help wanted" — Name is "help", Args is "wanted"
	"retest": true,
	"hold":   true,
}

// minPermission is "read"/"write"/"admin"/"owner"/"none" as Forgejo
// reports it; anything other than "none"/"read" counts as a collaborator
// for ChatOps purposes (write access is the practical floor for being
// trusted to direct CI/merge-queue actions).
func isCollaborator(permission string) bool {
	return permission == "write" || permission == "admin" || permission == "owner"
}

// Authorize reports whether commenter may run cmd against repo, fetching
// their live Forgejo permission rather than trusting anything in the
// comment itself (doc/pompadour.md §4.1's anti-impersonation rule).
func Authorize(ctx context.Context, fc *forgejo.Client, cmd Command, commenter string) (bool, error) {
	if !privileged[cmd.Name] {
		return true, nil
	}
	permission, err := fc.CollaboratorPermission(ctx, commenter)
	if err != nil {
		return false, fmt.Errorf("chatops: check permission for %q: %w", commenter, err)
	}
	return isCollaborator(permission), nil
}
