# fohlen

Audit VM forensics engine. Requirements: [doc/audit_engine.md](../../../doc/audit_engine.md).

## Build (on the Build VM, native OpenBSD `lang/go`)

```sh
go build -o fohlen .
go test ./...
```

`go.sum` is already committed (generated and verified with `go build`/`go vet`/`go test ./...` — all pass, 28 tests). Re-run `go mod tidy` only if you change `import` statements or bump a dependency.

`internal/web/static/htmx.min.js` is vendored (htmx 2.0.10, embedded via
`go:embed`, never fetched from a CDN at runtime — doc/audit_engine.md
§0.1). It was retrieved with:

```sh
curl -fsSL -o internal/web/static/htmx.min.js https://unpkg.com/htmx.org@2.0.10/dist/htmx.min.js
```

If it is ever updated, pin an exact version, re-run the command above with
the new version, and record its sha256 in a comment at the top of the file
so future audits can confirm the embedded copy hasn't silently drifted.

## Manual steps required before first deploy

1. **Generate `/etc/owlv/audit-ui-htpasswd`** (doc/audit_engine.md §6.3):

   ```sh
   htpasswd -nbB auditor 'choose-a-strong-passphrase' > audit-ui-htpasswd
   ```

   (or any bcrypt generator — the file format is plain `user:bcrypt-hash`
   lines, parsed by `internal/web/auth.go`.)

2. Copy `fohlen.toml.example` to `/etc/owlv/fohlen.toml` and adjust as
   needed (every key is optional; see `internal/config`).

## Residual design items

Tracked in doc/audit_engine.md §9 (UI port confirmation, threshold
calibration, htpasswd rotation policy, pentest_spec.md additions, Build VM
`lang/go` provisioning, deploy path, rule-table expansion, memory tuning
under real load).
