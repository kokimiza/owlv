// Package web implements doc/audit_engine.md §4.4: a read-only htmx UI
// served by net/http + html/template only — no external web framework,
// per the project's stated rationale that Go 1.22+'s ServeMux is already
// sufficient for a server-rendered htmx app. htmx itself is embedded via
// go:embed rather than loaded from a CDN (§0.1).
package web

import (
	"embed"
	"html/template"
	"net/http"
	"strconv"
	"time"

	"fohlen/internal/event"
	"fohlen/internal/index"
	"fohlen/internal/manifest"
	"fohlen/internal/stats"
)

//go:embed templates/*.gohtml
var templateFS embed.FS

//go:embed static/*
var staticFS embed.FS

type Server struct {
	tmpl         *template.Template
	ix           *index.Index
	engine       *stats.Engine
	manifestPath string
}

// New builds the route table. htpasswdPath must point at an existing,
// readable file (doc/audit_engine.md §6.3) — Open fails loudly rather than
// silently serving unauthenticated if it cannot be loaded.
func New(htpasswdPath string, ix *index.Index, engine *stats.Engine, manifestPath string) (http.Handler, error) {
	tmpl, err := template.New("").Funcs(template.FuncMap{
		"basename": manifest.BaseName,
		"add1":     func(n int) int { return n + 1 },
		"sub":      func(a, b int) int { return a - b },
	}).ParseFS(templateFS, "templates/*.gohtml")
	if err != nil {
		return nil, err
	}

	creds, err := loadHtpasswd(htpasswdPath)
	if err != nil {
		return nil, err
	}

	s := &Server{tmpl: tmpl, ix: ix, engine: engine, manifestPath: manifestPath}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", s.handleDashboardPage)
	mux.HandleFunc("GET /search", s.handleSearchPage)
	mux.HandleFunc("GET /integrity", s.handleIntegrityPage)
	mux.HandleFunc("GET /partials/dashboard", s.handleDashboardPartial)
	mux.HandleFunc("GET /partials/search", s.handleSearchPartial)
	mux.HandleFunc("GET /partials/integrity", s.handleIntegrityPartial)
	mux.Handle("GET /static/", http.FileServerFS(staticFS))

	return basicAuth(creds, mux), nil
}

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func categoryList() []string {
	cats := []event.EventCategory{
		event.AuthSuccess, event.AuthFailure, event.PrivilegeEscalationAttempt,
		event.ConfigIntegrityDrift, event.SessionForceTerminated, event.Unclassified,
	}
	out := make([]string, len(cats))
	for i, c := range cats {
		out[i] = c.String()
	}
	return out
}

func (s *Server) handleDashboardPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "dashboard_page", nil)
}

// dashboardRecentDetections caps how many past detections the dashboard
// shows (doc/audit_engine.md §4.4 "直近の逸脱検知イベント一覧") — these are
// now read from the persisted detections table (internal/index), not an
// in-memory ring, so the history survives a restart.
const dashboardRecentDetections = 50

func (s *Server) handleDashboardPartial(w http.ResponseWriter, r *http.Request) {
	type viewModel struct {
		stats.EngineSummary
		RecentDetections []stats.Detection
	}
	vm := viewModel{EngineSummary: s.engine.Summary()}
	detections, err := s.ix.RecentDetections(r.Context(), dashboardRecentDetections)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	vm.RecentDetections = detections
	s.render(w, "dashboard_partial", vm)
}

func (s *Server) handleSearchPage(w http.ResponseWriter, r *http.Request) {
	hosts, err := s.ix.DistinctSourceHosts(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	filter, raw := parseSearchFilter(r)
	data := struct {
		Filter      index.SearchFilter
		RawFilter   rawSearchFilter
		Categories  []string
		SourceHosts []string
	}{
		Filter:      filter,
		RawFilter:   raw,
		Categories:  categoryList(),
		SourceHosts: hosts,
	}
	s.render(w, "search_page", data)
}

// searchPageSize is the fixed page size for the search UI
// (doc/audit_engine.md §4.2: "結果はページネーションし、一度に全件をメモリへ
// 展開しない"). A fixed size keeps the offset/page arithmetic in the
// template trivial (no separate "page size" input to validate).
const searchPageSize = 50

func (s *Server) handleSearchPartial(w http.ResponseWriter, r *http.Request) {
	filter, raw := parseSearchFilter(r)
	filter.Limit = searchPageSize
	results, err := s.ix.Search(r.Context(), filter)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	data := struct {
		Results    []index.SearchResult
		RawFilter  rawSearchFilter
		Page       int
		HasNext    bool
		HasPrev    bool
	}{
		Results:   results,
		RawFilter: raw,
		Page:      filter.Offset / searchPageSize,
		HasNext:   len(results) == searchPageSize,
		HasPrev:   filter.Offset > 0,
	}
	s.render(w, "search_results_partial", data)
}

func (s *Server) handleIntegrityPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "integrity_page", nil)
}

func (s *Server) handleIntegrityPartial(w http.ResponseWriter, r *http.Request) {
	entries, err := manifest.Parse(s.manifestPath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	results := manifest.Verify(entries)
	data := struct {
		Results []manifest.VerifyResult
		AllOK   bool
	}{Results: results, AllOK: manifest.AllOK(results)}
	s.render(w, "integrity_partial", data)
}

// datetimeLocalLayout matches the value format of <input type="datetime-local">
// (no timezone, no seconds) — browsers submit exactly this shape.
const datetimeLocalLayout = "2006-01-02T15:04"

// rawSearchFilter preserves the user's literal query-string input so the
// search form can re-populate itself after a search (doc/audit_engine.md
// §4.2's filter combination is otherwise lossy across requests — htmx
// re-fetches the partial but the surrounding page's inputs must still
// reflect what was actually searched).
type rawSearchFilter struct {
	Keyword    string
	SourceHost string
	Category   string
	From       string
	To         string
}

func parseSearchFilter(r *http.Request) (index.SearchFilter, rawSearchFilter) {
	q := r.URL.Query()
	raw := rawSearchFilter{
		Keyword:    q.Get("q"),
		SourceHost: q.Get("source_host"),
		Category:   q.Get("category"),
		From:       q.Get("from"),
		To:         q.Get("to"),
	}

	filter := index.SearchFilter{
		Keyword:    raw.Keyword,
		SourceHost: raw.SourceHost,
		Category:   raw.Category,
	}
	if t, err := time.ParseInLocation(datetimeLocalLayout, raw.From, time.Local); err == nil {
		filter.From = t
	}
	if t, err := time.ParseInLocation(datetimeLocalLayout, raw.To, time.Local); err == nil {
		filter.To = t
	}
	if page, err := strconv.Atoi(q.Get("page")); err == nil && page > 0 {
		filter.Offset = page * searchPageSize
	}
	return filter, raw
}
