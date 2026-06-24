// Package ingest implements doc/audit_engine.md §4.1 ①: streaming
// tail-based ingestion of the live remote.log plus one-shot ingestion of
// sealed .gz generations, with rotation- and crash-safe checkpointing.
// Semantic classification (§4.1 ②) is delegated to internal/event;
// statistics (§4.3) to internal/stats; persistence (§4.2) to internal/index.
package ingest

import (
	"bufio"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"fohlen/internal/event"
	"fohlen/internal/index"
	"fohlen/internal/stats"
)

const liveLogName = "remote.log"

// Ingester drives one ingest cycle over LogDir, feeding classified events
// to Index and Engine and persisting Checkpoint after each cycle.
type Ingester struct {
	LogDir         string
	CheckpointPath string
	Index          *index.Index
	Engine         *stats.Engine
	Rules          []event.Rule

	checkpoint *Checkpoint
}

// Open loads (or initializes) the checkpoint at in.CheckpointPath.
func (in *Ingester) Open() error {
	cp, err := LoadCheckpoint(in.CheckpointPath)
	if err != nil {
		return fmt.Errorf("ingest: load checkpoint: %w", err)
	}
	in.checkpoint = cp
	return nil
}

// RunCycle performs one full ingest pass: live-log tail, any newly sealed
// generations, and cleanup of generations newsyslog has since deleted. It
// returns every statistical Detection raised while folding this cycle's
// events into Engine.
func (in *Ingester) RunCycle(ctx context.Context) ([]stats.Detection, error) {
	now := time.Now()
	var detections []stats.Detection

	liveEvents, err := in.tailLiveLog(now)
	if err != nil {
		return nil, fmt.Errorf("ingest: tail live log: %w", err)
	}
	if len(liveEvents) > 0 {
		if err := in.Index.BulkInsert(ctx, liveEvents, liveLogName); err != nil {
			return nil, fmt.Errorf("ingest: bulk insert live: %w", err)
		}
	}

	sealedEvents, err := in.ingestNewSealedGenerations(ctx, now)
	if err != nil {
		return nil, fmt.Errorf("ingest: sealed generations: %w", err)
	}

	if err := in.cleanupDeletedGenerations(ctx); err != nil {
		return nil, fmt.Errorf("ingest: cleanup deleted generations: %w", err)
	}

	allEvents := append(liveEvents, sealedEvents...)
	detections = append(detections, in.observe(allEvents, now)...)

	// Persist before returning so the dashboard's detection history
	// (doc/audit_engine.md §4.4) survives a restart — webhook notification
	// of these same detections happens separately in main.go's caller.
	if err := in.Index.InsertDetections(ctx, detections); err != nil {
		return nil, fmt.Errorf("ingest: persist detections: %w", err)
	}

	if err := in.checkpoint.Save(in.CheckpointPath); err != nil {
		return nil, fmt.Errorf("ingest: save checkpoint: %w", err)
	}
	return detections, nil
}

// tailLiveLog reads new bytes from remote.log since the last checkpoint,
// handling rotation by first recovering the pre-rotation tail from the
// just-rotated "remote.log.0" file if it is still present and uncompressed
// (doc/audit_engine.md §4.1: "ローテーション直前にまだ取り込んでいない末尾を
// 最初に処理してから新ファイルへ追従する").
func (in *Ingester) tailLiveLog(now time.Time) ([]event.AuditEvent, error) {
	livePath := filepath.Join(in.LogDir, liveLogName)
	info, err := os.Stat(livePath)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	var events []event.AuditEvent
	if info.Size() < in.checkpoint.LiveOffset {
		// Rotation occurred. Recover whatever of the pre-rotation tail is
		// still reachable via the just-rotated file before resetting.
		rotated := filepath.Join(in.LogDir, liveLogName+".0")
		if rinfo, rerr := os.Stat(rotated); rerr == nil && rinfo.Size() >= in.checkpoint.LiveOffset {
			lines, rerr := readFileLinesFrom(rotated, in.checkpoint.LiveOffset)
			if rerr != nil {
				return nil, fmt.Errorf("recovering pre-rotation tail from %s: %w", rotated, rerr)
			}
			events = append(events, in.classifyLines(lines, now)...)
			in.checkpoint.PendingGenOffset[liveLogName+".0"] = rinfo.Size()
		}
		in.checkpoint.LiveOffset = 0
	}

	lines, newOffset, err := readFileLinesFromTo(livePath, in.checkpoint.LiveOffset, info.Size())
	if err != nil {
		return nil, err
	}
	in.checkpoint.LiveOffset = newOffset
	events = append(events, in.classifyLines(lines, now)...)
	return events, nil
}

// ingestNewSealedGenerations ingests every "remote.log.*.gz" not yet
// recorded in Checkpoint.IngestedGenerations, skipping any bytes already
// covered via PendingGenOffset (doc/audit_engine.md §4.1).
func (in *Ingester) ingestNewSealedGenerations(ctx context.Context, now time.Time) ([]event.AuditEvent, error) {
	matches, err := filepath.Glob(filepath.Join(in.LogDir, liveLogName+".*.gz"))
	if err != nil {
		return nil, err
	}
	sort.Strings(matches)

	var allEvents []event.AuditEvent
	for _, path := range matches {
		name := filepath.Base(path)
		if in.checkpoint.IngestedGenerations[name] {
			continue
		}

		uncompressedName := strings.TrimSuffix(name, ".gz")
		skip := in.checkpoint.PendingGenOffset[uncompressedName]

		lines, err := readGzipLinesFrom(path, skip)
		if err != nil {
			return nil, fmt.Errorf("reading sealed generation %s: %w", name, err)
		}
		events := in.classifyLines(lines, now)
		if len(events) > 0 {
			if err := in.Index.BulkInsert(ctx, events, name); err != nil {
				return nil, fmt.Errorf("indexing sealed generation %s: %w", name, err)
			}
		}
		allEvents = append(allEvents, events...)

		in.checkpoint.IngestedGenerations[name] = true
		delete(in.checkpoint.PendingGenOffset, uncompressedName)
	}
	return allEvents, nil
}

// cleanupDeletedGenerations drops index rows for any generation recorded
// as ingested but no longer present on disk — newsyslog's 30-generation
// retention has rolled it off (doc/audit_engine.md §4.1, "索引はログの
// 写しに過ぎず、原本が消えたら追従して縮小する").
func (in *Ingester) cleanupDeletedGenerations(ctx context.Context) error {
	for name := range in.checkpoint.IngestedGenerations {
		path := filepath.Join(in.LogDir, name)
		if _, err := os.Stat(path); os.IsNotExist(err) {
			if err := in.Index.DeleteGeneration(ctx, name); err != nil {
				return err
			}
			delete(in.checkpoint.IngestedGenerations, name)
		}
	}
	return nil
}

func (in *Ingester) classifyLines(lines []string, now time.Time) []event.AuditEvent {
	events := make([]event.AuditEvent, 0, len(lines))
	for _, line := range lines {
		if line == "" {
			continue
		}
		rec, ok := event.ParseSyslogLine(line, now)
		if !ok {
			// Unparseable line: still not dropped. Treat the whole line as
			// the message of an Unclassified event so it remains
			// searchable (doc/audit_engine.md §4.1's "取りこぼし防止").
			rec = event.RawRecord{Timestamp: now, SourceHost: "unknown", Message: line, Raw: line}
			events = append(events, event.AuditEvent{Timestamp: now, SourceHost: "unknown", Category: event.Unclassified, Raw: rec})
			continue
		}
		events = append(events, event.Classify(rec, in.Rules))
	}
	return events
}

// observe folds this cycle's events into Engine: per-event entropy
// tracking, plus one rate-count sample per (source_host, category) for
// the Shewhart/EWMA/CUSUM charts (doc/audit_engine.md §4.3).
func (in *Ingester) observe(events []event.AuditEvent, now time.Time) []stats.Detection {
	var detections []stats.Detection
	counts := make(map[stats.RateKey]float64)
	var unclassifiedCount float64

	for _, ev := range events {
		if d := in.Engine.ObserveEvent(ev); d != nil {
			detections = append(detections, *d)
		}
		counts[stats.RateKey{SourceHost: ev.SourceHost, Category: ev.Category}]++
		if ev.Category == event.Unclassified {
			unclassifiedCount++
		}
	}
	for key, c := range counts {
		detections = append(detections, in.Engine.ObserveCategoryCount(key, c, now)...)
	}
	if d := in.Engine.ObserveUnclassifiedRate(unclassifiedCount, now); d != nil {
		detections = append(detections, *d)
	}
	return detections
}

func readFileLinesFrom(path string, from int64) ([]string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	lines, _, err := readFileLinesFromTo(path, from, info.Size())
	return lines, err
}

func readFileLinesFromTo(path string, from, to int64) (lines []string, newOffset int64, err error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, from, err
	}
	defer f.Close()

	if from >= to {
		return nil, from, nil
	}
	if _, err := f.Seek(from, io.SeekStart); err != nil {
		return nil, from, err
	}
	buf := make([]byte, to-from)
	n, err := io.ReadFull(f, buf)
	if err != nil && err != io.ErrUnexpectedEOF {
		return nil, from, err
	}
	buf = buf[:n]
	return splitLines(buf), from + int64(n), nil
}

func splitLines(buf []byte) []string {
	text := strings.TrimSuffix(string(buf), "\n")
	if text == "" {
		return nil
	}
	return strings.Split(text, "\n")
}

// readGzipLinesFrom decompresses path fully and returns the lines starting
// after skipBytes of *decompressed* content, matching the byte accounting
// used by tailLiveLog's PendingGenOffset (doc/audit_engine.md §4.1).
func readGzipLinesFrom(path string, skipBytes int64) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	gz, err := gzip.NewReader(f)
	if err != nil {
		return nil, err
	}
	defer gz.Close()

	scanner := bufio.NewScanner(gz)
	scanner.Buffer(make([]byte, 64*1024), 1<<20)

	var lines []string
	var pos int64
	for scanner.Scan() {
		line := scanner.Text()
		lineLen := int64(len(line)) + 1
		pos += lineLen
		if pos <= skipBytes {
			continue
		}
		lines = append(lines, line)
	}
	return lines, scanner.Err()
}
