// Command fohlen is the Audit VM forensics engine described in
// doc/audit_engine.md: it tails /var/log/audit/remote.log and its sealed
// .gz generations, classifies syslog lines into AuditEvents, indexes them
// for full-text search, runs online statistical deviation detection, and
// serves a read-only htmx UI — all read-only with respect to the audit
// log itself (doc/audit_engine.md §2.2, §7).
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"fohlen/internal/config"
	"fohlen/internal/event"
	"fohlen/internal/index"
	"fohlen/internal/ingest"
	"fohlen/internal/notify"
	"fohlen/internal/stats"
	"fohlen/internal/sysguard"
	"fohlen/internal/web"
)

const configPathDefault = "/etc/owlv/fohlen.toml"

func main() {
	// genpasswd is a provisioning-time-only CLI mode (infra/vm-audit/setup.sh),
	// not the server: it exits immediately after writing one htpasswd entry.
	// This keeps OpenBSD provisioning free of an external apache2-utils-style
	// htpasswd(1) dependency by reusing fohlen's own bcrypt code path
	// (doc/audit_engine.md §6.3).
	if len(os.Args) > 1 && os.Args[1] == "genpasswd" {
		if err := runGenPasswd(os.Args[2:]); err != nil {
			log.Fatalf("fohlen genpasswd: %v", err)
		}
		return
	}

	if err := run(); err != nil {
		log.Fatalf("fohlen: %v", err)
	}
}

// runGenPasswd implements `fohlen genpasswd <username> [htpasswd-file]`.
// htpasswd-file defaults to config.Default().Server.HtpasswdPath. The new
// plaintext password is printed to stdout exactly once — the operator must
// record it immediately (mirrors infra/vm-git/setup.sh's one-time Forgejo
// admin password notice).
func runGenPasswd(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: fohlen genpasswd <username> [htpasswd-file]")
	}
	username := args[0]
	path := config.Default().Server.HtpasswdPath
	if len(args) >= 2 {
		path = args[1]
	}

	password, err := web.GenerateHtpasswdUser(path, username)
	if err != nil {
		return err
	}
	fmt.Printf("fohlen UI 認証情報を生成しました (%s):\n  user: %s\n  pass: %s\n", path, username, password)
	fmt.Println("このパスワードは二度と表示されません。今すぐ記録してください。")
	return nil
}

func run() error {
	configPath := configPathDefault
	if v := os.Getenv("FOHLEN_CONFIG"); v != "" {
		configPath = v
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	// doc/audit_engine.md §7: declare all three unveil paths up front, but
	// hold the final lock until the SQLite connection has been opened and
	// warmed up (Step below), since modernc.org/sqlite's init can touch
	// paths outside this set (e.g. TMPDIR) before that point.
	if err := sysguard.Unveil(cfg.Paths.LogDir, "r"); err != nil {
		return fmt.Errorf("unveil log_dir: %w", err)
	}
	if err := sysguard.Unveil(cfg.Paths.DBDir, "rwc"); err != nil {
		return fmt.Errorf("unveil db_dir: %w", err)
	}
	if err := sysguard.Unveil("/etc/owlv", "r"); err != nil {
		return fmt.Errorf("unveil /etc/owlv: %w", err)
	}

	tmpDir := filepath.Join(cfg.Paths.DBDir, "tmp")
	if err := os.MkdirAll(tmpDir, 0o700); err != nil {
		return fmt.Errorf("create tmpdir: %w", err)
	}
	os.Setenv("TMPDIR", tmpDir)
	if err := sysguard.Unveil(tmpDir, "rwc"); err != nil {
		return fmt.Errorf("unveil tmpdir: %w", err)
	}

	stateDir := filepath.Join(cfg.Paths.DBDir, "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return fmt.Errorf("create state dir: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ix, err := index.Open(ctx, filepath.Join(cfg.Paths.DBDir, "index.sqlite3"), cfg.Ingest.BulkCommitSize, cfg.Ingest.SQLiteCacheSizeKB)
	if err != nil {
		return fmt.Errorf("open index: %w", err)
	}
	defer ix.Close()

	// The SQLite connection above has now run a query, completing its
	// internal init. Lock unveil before doing anything else
	// (doc/audit_engine.md §7's required ordering).
	if err := sysguard.Lock(); err != nil {
		return fmt.Errorf("unveil lock: %w", err)
	}
	if err := sysguard.Pledge("stdio rpath wpath cpath inet"); err != nil {
		return fmt.Errorf("pledge: %w", err)
	}

	statsPath := filepath.Join(stateDir, "stats.json")
	engine, err := loadOrNewEngine(statsPath, cfg.Stats)
	if err != nil {
		return fmt.Errorf("load stats engine: %w", err)
	}

	ingester := &ingest.Ingester{
		LogDir:         cfg.Paths.LogDir,
		CheckpointPath: filepath.Join(stateDir, "ingested.json"),
		Index:          ix,
		Engine:         engine,
		Rules:          event.DefaultRules(),
	}
	if err := ingester.Open(); err != nil {
		return fmt.Errorf("open ingester: %w", err)
	}

	notifier := notify.NewNotifier(cfg.Paths.WebhookFile)

	if err := healthCheckIndexSize(ctx, cfg.Paths.LogDir, ix); err != nil {
		log.Printf("fohlen: index size health check failed (non-fatal): %v", err)
	}

	manifestPath := filepath.Join(cfg.Paths.LogDir, "sealed-manifest.sha256")
	handler, err := web.New(cfg.Server.HtpasswdPath, ix, engine, manifestPath)
	if err != nil {
		return fmt.Errorf("build web server: %w", err)
	}

	srv := &http.Server{Addr: cfg.Server.ListenAddr, Handler: handler}

	var wg sync.WaitGroup
	wg.Go(func() {
		runIngestLoop(ctx, ingester, notifier, engine, statsPath, cfg.Ingest.PollIntervalSec)
	})

	serveErr := make(chan error, 1)
	go func() {
		log.Printf("fohlen: listening on %s", cfg.Server.ListenAddr)
		serveErr <- srv.ListenAndServe()
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			cancel()
			wg.Wait()
			return fmt.Errorf("http server: %w", err)
		}
	case <-sigCh:
		log.Print("fohlen: shutting down")
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		srv.Shutdown(shutdownCtx)
	}

	cancel()
	wg.Wait()
	return saveEngineSnapshot(engine, statsPath)
}

func loadOrNewEngine(path string, cfg config.StatsConfig) (*stats.Engine, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return newEngine(cfg), nil
	}
	if err != nil {
		return nil, err
	}
	engine, err := stats.LoadEngine(data)
	if err != nil {
		return nil, err
	}
	return engine, nil
}

func newEngine(cfg config.StatsConfig) *stats.Engine {
	return stats.NewEngine(stats.Config{
		ShewhartSigma:       cfg.ShewhartSigma,
		EWMALambda:          cfg.EWMALambda,
		CUSUMK:              cfg.CUSUMK,
		CUSUMH:              cfg.CUSUMH,
		EntropySurpriseBits: cfg.EntropySurpriseBits,
	})
}

func saveEngineSnapshot(engine *stats.Engine, path string) error {
	data, err := engine.MarshalJSON()
	if err != nil {
		return fmt.Errorf("marshal stats snapshot: %w", err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("write stats snapshot: %w", err)
	}
	return os.Rename(tmp, path)
}

// runIngestLoop drives one ingest+detect+notify cycle every pollIntervalSec
// until ctx is canceled, persisting the stats snapshot after each cycle so
// a restart resumes learned baselines (doc/audit_engine.md §4.3). Detections
// are persisted to the index by Ingester.RunCycle itself; this loop only
// needs the returned slice to drive the webhook notifier.
func runIngestLoop(ctx context.Context, ingester *ingest.Ingester, notifier *notify.Notifier, engine *stats.Engine, statsPath string, pollIntervalSec int) {
	if pollIntervalSec <= 0 {
		pollIntervalSec = 60
	}
	ticker := time.NewTicker(time.Duration(pollIntervalSec) * time.Second)
	defer ticker.Stop()

	runOnce := func() {
		detections, err := ingester.RunCycle(ctx)
		if err != nil {
			log.Printf("fohlen: ingest cycle failed: %v", err)
			return
		}
		if len(detections) > 0 {
			if err := notifier.Notify(ctx, detections); err != nil {
				log.Printf("fohlen: notify failed: %v", err)
			}
		}
		if err := saveEngineSnapshot(engine, statsPath); err != nil {
			log.Printf("fohlen: failed to persist stats snapshot: %v", err)
		}
	}

	runOnce()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			runOnce()
		}
	}
}

// indexSizeWarnRatio is the "目安: 3倍" health-check threshold from
// doc/audit_engine.md §4.2: the index is expected to track the original
// log volume within a small multiple, and a larger ratio signals an
// unexpected blow-up (parser bug duplicating rows, runaway FTS tokenizer
// output, etc.) worth a startup warning.
const indexSizeWarnRatio = 3.0

// healthCheckIndexSize logs a warning (never fails startup) if the index
// file is disproportionately larger than the original log volume it was
// built from (doc/audit_engine.md §4.2).
func healthCheckIndexSize(ctx context.Context, logDir string, ix *index.Index) error {
	logBytes, err := sumLogBytes(logDir)
	if err != nil {
		return fmt.Errorf("sum log bytes: %w", err)
	}
	if logBytes == 0 {
		return nil // nothing ingested yet; ratio is meaningless
	}
	indexBytes, err := ix.SizeBytes(ctx)
	if err != nil {
		return fmt.Errorf("index size: %w", err)
	}
	ratio := float64(indexBytes) / float64(logBytes)
	if ratio > indexSizeWarnRatio {
		log.Printf("fohlen: WARNING index size (%d bytes) is %.1fx the original log volume (%d bytes), exceeding the %.0fx health-check threshold (doc/audit_engine.md §4.2) — investigate possible duplicate ingestion or parser bug",
			indexBytes, ratio, logBytes, indexSizeWarnRatio)
	}
	return nil
}

func sumLogBytes(logDir string) (int64, error) {
	entries, err := os.ReadDir(logDir)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	var total int64
	for _, e := range entries {
		if e.IsDir() || !strings.HasPrefix(e.Name(), "remote.log") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		total += info.Size()
	}
	return total, nil
}
