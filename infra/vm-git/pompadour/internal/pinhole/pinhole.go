// Package pinhole is the only path by which pompadourd may cause an LLM
// API call to happen, and it never makes that call itself
// (doc/pompadour.md §7). It shells out to a host-controlled script that
// opens a time-limited pf pinhole (the same pattern as DR egress,
// doc/dev_sec_ops.md §2.2), runs the isolated ai-gateway binary while
// the pinhole is open, and the script closes the pinhole on return —
// success or failure — via its own trap handler. pompadourd's process
// itself is never granted outbound network pledge for this purpose; see
// internal/sysguard and doc/pompadour.md §7 for the "inet" promise
// pompadourd needs only for its loopback Forgejo API calls.
package pinhole

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"time"
)

// Request is the task handed to the ai-gateway binary, encoded as JSON
// on its stdin. Callers (internal/labeler) decide what Kind means; this
// package is transport-only and does not interpret the payload.
type Request struct {
	Kind    string `json:"kind"` // "classify-issue" | "draft-pr"
	Payload []byte `json:"payload"`
}

// Invoke runs scriptPath (the host's pinhole-open/pinhole-close wrapper)
// with the gateway binary path as its argument, writes payload to its
// stdin, and returns its stdout. timeout bounds the whole call —
// callers must pick a value the pinhole script's own egress window
// (doc/dev_sec_ops.md §2.2) does not exceed, so an ai-gateway hang can
// never hold the pinhole open indefinitely.
func Invoke(ctx context.Context, scriptPath, gatewayBinary string, payload []byte, timeout time.Duration) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, scriptPath, gatewayBinary)
	cmd.Stdin = bytes.NewReader(payload)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("pinhole: %s %s: %w (stderr: %s)", scriptPath, gatewayBinary, err, stderr.String())
	}
	return stdout.Bytes(), nil
}
