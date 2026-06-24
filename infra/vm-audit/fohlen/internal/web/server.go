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

	"fohlen/internal/event"
	"fohlen/internal/index"
	"fohlen/internal/manifest"
	"fohlen/internal/stats"
)

//go:embed templates/*.gohtml
var templateFS embed.FS

//go:embed static/*
var staticFS embed.FS

// RecentDetections is supplied by main.go's ingest loop so the dashboard
// can show the latest statistical alerts without the web package needing
// to know how ingestion is scheduled.
type RecentDetectionsProvider func() []stats.Detection

type Server struct {
	tmpl         *template.Template
	ix           *index.Index
	engine       *stats.Engine
	manifestPath string
	recent       RecentDetectionsProvider
}

// New builds the route table. htpasswdPath must point at an existing,
// readable file (doc/audit_engine.md §6.3) — Open fails loudly rather than
// silently serving unauthenticated if it cannot be loaded.
func New(htpasswdPath string, ix *index.Index, engine *stats.Engine, manifestPath string, recent RecentDetectionsProvider) (http.Handler, error) {
	tmpl, err := template.New("").Funcs(template.FuncMap{
		"basename": manifest.BaseName,
	}).ParseFS(templateFS, "templates/*.gohtml")
	if err != nil {
		return nil, err
	}

	creds, err := loadHtpasswd(htpasswdPath)
	if err != nil {
		return nil, err
	}

	s := &Server{tmpl: tmpl, ix: ix, engine: engine, manifestPath: manifestPath, recent: recent}

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

func (s *Server) handleDashboardPartial(w http.ResponseWriter, r *http.Request) {
	type viewModel struct {
		stats.EngineSummary
		RecentDetections []stats.Detection
	}
	vm := viewModel{EngineSummary: s.engine.Summary()}
	if s.recent != nil {
		vm.RecentDetections = s.recent()
	}
	s.render(w, "dashboard_partial", vm)
}

func (s *Server) handleSearchPage(w http.ResponseWriter, r *http.Request) {
	hosts, err := s.ix.DistinctSourceHosts(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	data := struct {
		Filter      index.SearchFilter
		Categories  []string
		SourceHosts []string
	}{
		Filter:      parseSearchFilter(r),
		Categories:  categoryList(),
		SourceHosts: hosts,
	}
	s.render(w, "search_page", data)
}

func (s *Server) handleSearchPartial(w http.ResponseWriter, r *http.Request) {
	filter := parseSearchFilter(r)
	results, err := s.ix.Search(r.Context(), filter)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	data := struct{ Results []index.SearchResult }{Results: results}
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

func parseSearchFilter(r *http.Request) index.SearchFilter {
	q := r.URL.Query()
	return index.SearchFilter{
		Keyword:    q.Get("q"),
		SourceHost: q.Get("source_host"),
		Category:   q.Get("category"),
	}
}
