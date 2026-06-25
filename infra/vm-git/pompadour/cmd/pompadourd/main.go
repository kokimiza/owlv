// Command pompadourd is the Pompadour daemon described in
// doc/pompadour.md: it polls the local Forgejo API (no inbound
// webhooks, doc/pompadour.md §3) and drives ChatOps, the merge queue,
// the review-load balancer, AI label proposals, and Knowledge Harvest.
// It runs on the Git VM alongside Forgejo itself and never makes an
// outbound LLM call directly — that is isolated behind
// internal/pinhole (doc/pompadour.md §7).
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"pompadour/internal/chatops"
	"pompadour/internal/config"
	"pompadour/internal/forgejo"
	"pompadour/internal/harvest"
	"pompadour/internal/labeler"
	"pompadour/internal/mergequeue"
	"pompadour/internal/onboarding"
	"pompadour/internal/reviewbalancer"
	"pompadour/internal/scheduler"
	"pompadour/internal/store"
	"pompadour/internal/sysguard"
)

const configPathDefault = "/etc/owlv/pompadour.toml"

func main() {
	if err := run(); err != nil {
		log.Fatalf("pompadourd: %v", err)
	}
}

func run() error {
	configPath := configPathDefault
	if v := os.Getenv("POMPADOUR_CONFIG"); v != "" {
		configPath = v
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	token, err := cfg.Forgejo.Token()
	if err != nil {
		return err
	}

	// doc/pompadour.md §7: confine pompadourd to its own state directory
	// plus loopback network for the local Forgejo API. It never gets a
	// path or promise that would let it reach audit_lan/internal_lan, or
	// talk to the outside world on its own (that is internal/pinhole's
	// job, run as a separate process via a host-controlled script).
	if err := sysguard.Unveil(cfg.Store.Path, "rwc"); err != nil {
		return fmt.Errorf("unveil store path: %w", err)
	}
	if err := sysguard.Unveil("/etc/owlv", "r"); err != nil {
		return fmt.Errorf("unveil /etc/owlv: %w", err)
	}
	if err := sysguard.Unveil(cfg.AI.PinholeScript, "x"); err != nil {
		return fmt.Errorf("unveil pinhole script: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	st, err := store.Open(ctx, cfg.Store.Path)
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}
	defer st.Close()

	if err := sysguard.Lock(); err != nil {
		return fmt.Errorf("unveil lock: %w", err)
	}
	if err := sysguard.Pledge("stdio rpath wpath cpath inet proc exec"); err != nil {
		return fmt.Errorf("pledge: %w", err)
	}

	fc := forgejo.New(cfg.Forgejo.BaseURL, cfg.Forgejo.Owner, cfg.Forgejo.Repo, token)

	gateway := labeler.PinholeGateway{
		ScriptPath:    cfg.AI.PinholeScript,
		GatewayBinary: cfg.AI.GatewayBinary,
		Timeout:       time.Duration(cfg.AI.TimeoutSec) * time.Second,
	}

	cycles := []scheduler.Cycle{
		{
			Name:     "chatops",
			Interval: time.Duration(cfg.Poll.ChatOpsSec) * time.Second,
			Run:      func(ctx context.Context) error { return runChatOpsCycle(ctx, fc, st) },
		},
		{
			Name:     "mergequeue",
			Interval: time.Duration(cfg.Poll.MergeQueueSec) * time.Second,
			Run:      func(ctx context.Context) error { return runMergeQueueCycle(ctx, fc, st) },
		},
		{
			Name:     "reviewbalancer",
			Interval: time.Duration(cfg.Poll.ReviewBalancerSec) * time.Second,
			Run:      func(ctx context.Context) error { return runReviewBalancerCycle(ctx, fc, st, cfg) },
		},
		{
			Name:     "labeler",
			Interval: time.Duration(cfg.Poll.ChatOpsSec) * time.Second,
			Run:      func(ctx context.Context) error { return runLabelerCycle(ctx, fc, st, gateway) },
		},
		{
			Name:     "harvest",
			Interval: time.Duration(cfg.Poll.HarvestSec) * time.Second,
			Run:      func(ctx context.Context) error { return runHarvestCycle(ctx, fc, st) },
		},
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Print("pompadourd: shutting down")
		cancel()
	}()

	log.Printf("pompadourd: started, polling %s/%s as %s", cfg.Forgejo.Owner, cfg.Forgejo.Repo, cfg.Forgejo.BaseURL)
	scheduler.Run(ctx, cycles)
	return nil
}

// runChatOpsCycle implements doc/pompadour.md §4.1: poll open issues/PRs
// for new comments, dedupe via st, and dispatch recognized slash
// commands. It also runs the first-time-contributor welcome
// (doc/pompadour.md §4.3) for any commenter pompadour hasn't seen
// before.
func runChatOpsCycle(ctx context.Context, fc *forgejo.Client, st *store.Store) error {
	issues, err := fc.ListOpenIssues(ctx)
	if err != nil {
		return fmt.Errorf("chatops: list issues: %w", err)
	}
	pulls, err := fc.ListOpenPulls(ctx)
	if err != nil {
		return fmt.Errorf("chatops: list pulls: %w", err)
	}

	numbers := make([]int64, 0, len(issues)+len(pulls))
	for _, i := range issues {
		numbers = append(numbers, i.Number)
	}
	for _, p := range pulls {
		numbers = append(numbers, p.Number)
	}

	for _, number := range numbers {
		comments, err := fc.ListIssueComments(ctx, number)
		if err != nil {
			return fmt.Errorf("chatops: list comments #%d: %w", number, err)
		}
		for _, c := range comments {
			already, err := st.MarkCommentSeen(ctx, c.ID)
			if err != nil {
				return fmt.Errorf("chatops: mark seen #%d: %w", number, err)
			}
			if already {
				continue
			}
			cmd, ok := chatops.Parse(c.Body)
			if !ok {
				continue
			}
			if err := chatops.Dispatch(ctx, fc, st, number, c.User.Login, cmd); err != nil {
				log.Printf("pompadourd: chatops dispatch #%d %s: %v", number, cmd.Name, err)
			}
		}
	}

	return runOnboardingCycle(ctx, fc, pulls)
}

// runOnboardingCycle implements doc/pompadour.md §4.3.
func runOnboardingCycle(ctx context.Context, fc *forgejo.Client, pulls []forgejo.PullRequest) error {
	for _, p := range pulls {
		first, err := onboarding.IsFirstTimeContributor(ctx, fc, p.User.Login, p.Number)
		if err != nil {
			return fmt.Errorf("onboarding: check #%d: %w", p.Number, err)
		}
		if first {
			if err := onboarding.Welcome(ctx, fc, p.Number); err != nil {
				return fmt.Errorf("onboarding: welcome #%d: %w", p.Number, err)
			}
		}
	}
	return nil
}

// runMergeQueueCycle implements doc/pompadour.md §5.1/§5.2/§5.3. New
// approved PRs are enqueued here (Forgejo itself remains the source of
// truth for "approved" — pompadour only reads that state, never sets
// it); the actual rebase/CI/merge/bisect logic lives in
// internal/mergequeue.
func runMergeQueueCycle(ctx context.Context, fc *forgejo.Client, st *store.Store) error {
	pulls, err := fc.ListOpenPulls(ctx)
	if err != nil {
		return fmt.Errorf("mergequeue: list pulls: %w", err)
	}
	for _, p := range pulls {
		if !p.Mergeable {
			continue
		}
		if err := st.Enqueue(ctx, p.Number); err != nil {
			return fmt.Errorf("mergequeue: enqueue #%d: %w", p.Number, err)
		}
	}

	runner := &mergequeue.Runner{
		Forgejo:   fc,
		Store:     st,
		BatchSize: 3,
		RunCI:     runScratchBranchCI(fc),
	}
	return runner.ProcessCycle(ctx)
}

// runScratchBranchCI builds the disposable batch-testing branch of
// doc/pompadour.md §5.2 and reports CI pass/fail. The real CI trigger
// and result polling go through the same Forgejo Actions job
// (dev_sec_ops.md §4.1) build.yml already runs on every push; wiring
// that run-id polling is the one piece intentionally left as a TODO here
// — everything else in the merge queue (FIFO ordering, bisection,
// eviction) does not depend on how CI completion is detected.
func runScratchBranchCI(fc *forgejo.Client) func(ctx context.Context, scratch string, prs []int64) (bool, error) {
	return func(ctx context.Context, scratch string, prs []int64) (bool, error) {
		if err := fc.CreateBranch(ctx, scratch, "main"); err != nil {
			return false, fmt.Errorf("create scratch branch %s: %w", scratch, err)
		}
		defer fc.DeleteBranch(ctx, scratch) //nolint:errcheck // best-effort cleanup; doc/pompadour.md §5.2 mandates trying regardless of CI outcome

		// TODO(doc/pompadour.md §5.2): merge each PR's head into scratch
		// in order, trigger build.yml against scratch, and poll its
		// Forgejo Actions run to completion. Until that polling loop is
		// wired up, batches are not actually exercised against real CI.
		_ = prs
		return false, fmt.Errorf("runScratchBranchCI: CI trigger/poll not yet implemented")
	}
}

// runReviewBalancerCycle implements doc/pompadour.md §5.6: assign a
// reviewer to any open PR that has none, picking the least-loaded member
// of the configured pool.
func runReviewBalancerCycle(ctx context.Context, fc *forgejo.Client, st *store.Store, cfg config.Config) error {
	if len(cfg.Reviewer.Pool) == 0 {
		return nil // no pool configured: a human hasn't opted in yet (doc/pompadour.md §5.6)
	}

	pulls, err := fc.ListOpenPulls(ctx)
	if err != nil {
		return fmt.Errorf("reviewbalancer: list pulls: %w", err)
	}
	loadsByName, err := st.Loads(ctx)
	if err != nil {
		return fmt.Errorf("reviewbalancer: loads: %w", err)
	}
	counts := make(map[string]int, len(loadsByName))
	for name, l := range loadsByName {
		counts[name] = l.AssignedCount
	}

	for _, p := range pulls {
		if len(p.RequestedRevs) > 0 {
			continue
		}
		exclude := map[string]bool{p.User.Login: true}
		reviewer, ok := reviewbalancer.Pick(cfg.Reviewer.Pool, counts, cfg.Reviewer.MaxAssignedCount, exclude)
		if !ok {
			if err := fc.AddLabels(ctx, p.Number, []string{"needs-reviewer"}); err != nil {
				return fmt.Errorf("reviewbalancer: label #%d: %w", p.Number, err)
			}
			continue
		}
		if err := fc.RequestReviewers(ctx, p.Number, []string{reviewer}); err != nil {
			return fmt.Errorf("reviewbalancer: request #%d: %w", p.Number, err)
		}
		if err := st.IncrementAssigned(ctx, reviewer); err != nil {
			return fmt.Errorf("reviewbalancer: increment %s: %w", reviewer, err)
		}
		counts[reviewer]++
	}
	return nil
}

// runLabelerCycle implements doc/pompadour.md §4.2: propose AI labels
// for newly-seen issues, and sweep 72h-old unconfirmed proposals into
// confirmed ones.
func runLabelerCycle(ctx context.Context, fc *forgejo.Client, st *store.Store, gw labeler.Gateway) error {
	issues, err := fc.ListOpenIssues(ctx)
	if err != nil {
		return fmt.Errorf("labeler: list issues: %w", err)
	}
	for _, issue := range issues {
		if hasAnyLabel(issue.Labels) {
			continue // already triaged (manually or by a prior cycle)
		}
		if err := labeler.ProposeForIssue(ctx, gw, fc, st, issue); err != nil {
			log.Printf("pompadourd: labeler propose #%d: %v", issue.Number, err)
		}
	}
	return labeler.Sweep(ctx, fc, st, time.Now())
}

func hasAnyLabel(labels []forgejo.Label) bool {
	return len(labels) > 0
}

// runHarvestCycle implements doc/pompadour.md §5.7's mechanical
// transcription half (decision-log auto-commit); the ADR-draft half
// requires a human /adr-confirm and is posted as a comment, never
// auto-committed.
func runHarvestCycle(ctx context.Context, fc *forgejo.Client, st *store.Store) error {
	pulls, err := fc.ListPulls(ctx, "closed")
	if err != nil {
		return fmt.Errorf("harvest: list closed pulls: %w", err)
	}
	for _, p := range pulls {
		if !p.Merged {
			continue // doc/pompadour.md §5.7 harvests merged PRs only
		}
		already, err := st.MarkHarvested(ctx, p.Number)
		if err != nil {
			return fmt.Errorf("harvest: mark #%d: %w", p.Number, err)
		}
		if already {
			continue
		}
		why, ok := harvest.ExtractWhy(p.Body)
		if !ok {
			continue
		}
		if err := harvest.AppendDecisionLog("doc/decision-log/decision-log.md", harvest.DecisionLogEntry{
			MergedAt: time.Now(),
			PRNumber: p.Number,
			PRTitle:  p.Title,
			Why:      why,
		}); err != nil {
			return fmt.Errorf("harvest: append #%d: %w", p.Number, err)
		}
		if harvest.LooksArchitectural(why) {
			if err := fc.CreateComment(ctx, p.Number, harvest.ADRDraftComment(why)); err != nil {
				return fmt.Errorf("harvest: comment #%d: %w", p.Number, err)
			}
		}
	}
	return nil
}
