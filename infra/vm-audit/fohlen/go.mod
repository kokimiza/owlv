module fohlen

go 1.26.4

// require versions below are unresolved placeholders: this sandbox has
// neither a Go toolchain nor network access, so `go mod tidy` could not
// be run here. Run `go mod tidy` on the Build VM (which has lang/go via
// ports, per doc/audit_engine.md §1 toolchain constraint) before the
// first build to pin exact versions and generate go.sum.
require (
	golang.org/x/crypto v0.53.0
	golang.org/x/sys v0.46.0
	modernc.org/sqlite v1.53.0
)

require (
	github.com/dustin/go-humanize v1.0.1 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/hashicorp/golang-lru/v2 v2.0.7 // indirect
	github.com/mattn/go-isatty v0.0.22 // indirect
	github.com/ncruces/go-strftime v1.0.0 // indirect
	github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec // indirect
	modernc.org/gc/v3 v3.1.5 // indirect
	modernc.org/libc v1.73.5 // indirect
	modernc.org/mathutil v1.7.1 // indirect
	modernc.org/memory v1.11.0 // indirect
	modernc.org/strutil v1.2.1 // indirect
	modernc.org/token v1.1.0 // indirect
)
