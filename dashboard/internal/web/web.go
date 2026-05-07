// Package web wires HTTP routes, auth, and templates for the dashboard.
package web

import (
	"context"
	"embed"
	"fmt"
	"html/template"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/gorilla/sessions"
	"golang.org/x/crypto/bcrypt"
)

//go:embed templates/*.html
var tplFS embed.FS

//go:embed static/*
var staticFS embed.FS

const sessionName = "dashboard"

type server struct {
	cfg     config.Config
	dokku   *dokku.Client
	logs    *logbuf.Store
	runner  *scripts.Runner
	pages   map[string]*template.Template
	store   *sessions.CookieStore
}

// Router builds the HTTP handler.
func Router(cfg config.Config, d *dokku.Client, l *logbuf.Store, runner *scripts.Runner) http.Handler {
	funcs := template.FuncMap{
		"join":     strings.Join,
		"now":      func() string { return time.Now().Format("2006-01-02 15:04:05") },
		"stateClr": stateClass,
		"httpClr":  httpClass,
	}
	pages := map[string]*template.Template{}
	layoutPages := []string{"index.html", "app.html", "console.html", "scripts.html", "script.html"}
	for _, name := range layoutPages {
		pages[name] = template.Must(template.New("").Funcs(funcs).ParseFS(tplFS,
			"templates/_layout.html",
			"templates/palette.html",
			"templates/"+name,
		))
	}
	pages["login.html"] = template.Must(template.New("").Funcs(funcs).ParseFS(tplFS, "templates/login.html"))

	store := sessions.NewCookieStore(cfg.SessionKey)
	store.Options = &sessions.Options{
		Path:     "/",
		HttpOnly: true,
		Secure:   cfg.CookieSecure,
		MaxAge:   60 * 60 * 12,
		SameSite: http.SameSiteLaxMode,
	}

	s := &server{cfg: cfg, dokku: d, logs: l, runner: runner, pages: pages, store: store}

	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)

	staticSub, _ := fs.Sub(staticFS, "static")
	r.Handle("/static/*", http.StripPrefix("/static/", http.FileServer(http.FS(staticSub))))
	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })

	r.Get("/login", s.handleLoginPage)
	r.Post("/login", s.handleLoginSubmit)
	r.Post("/logout", s.handleLogout)

	r.Group(func(r chi.Router) {
		r.Use(s.requireAuth)
		r.Get("/", s.handleIndex)
		r.Get("/apps/{name}", s.handleApp)
		r.Post("/apps/{name}/{verb}", s.handleAction)
		r.Get("/apps/{name}/logs", s.handleLogStream)
		r.Get("/apps/{name}/logs.txt", s.handleLogDump)
		r.Get("/api/apps", s.handleAPIApps)
		r.Get("/events", s.handleEvents)
		r.Get("/console", s.handleConsolePage)
		r.Post("/console/run", s.handleConsoleRun)
		r.Get("/console/allowed", s.handleConsoleAllowed)
		r.Get("/scripts", s.handleScriptsPage)
		r.Get("/scripts/{name}", s.handleScriptPage)
		r.Post("/scripts/{name}/run", s.handleScriptRun)
	})

	return r
}

// ---- Auth -------------------------------------------------------------------

func (s *server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sess, _ := s.store.Get(r, sessionName)
		if v, ok := sess.Values["user"].(string); !ok || v == "" {
			if r.URL.Query().Get("from") == "login" {
				http.Redirect(w, r, "/login?e=session", http.StatusSeeOther)
				return
			}
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) handleLoginPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "login.html", map[string]any{"Env": s.cfg.EnvName, "Error": r.URL.Query().Get("e")})
}

func (s *server) handleLoginSubmit(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	user := strings.TrimSpace(r.FormValue("user"))
	pass := strings.TrimSpace(r.FormValue("pass"))
	if user != s.cfg.AdminUser ||
		bcrypt.CompareHashAndPassword([]byte(s.cfg.AdminHash), []byte(pass)) != nil {
		http.Redirect(w, r, "/login?e=invalid", http.StatusSeeOther)
		return
	}
	sess, _ := s.store.Get(r, sessionName)
	sess.Values["user"] = user
	if err := sess.Save(r, w); err != nil {
		http.Redirect(w, r, "/login?e=session", http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/?from=login", http.StatusSeeOther)
}

func (s *server) handleLogout(w http.ResponseWriter, r *http.Request) {
	sess, _ := s.store.Get(r, sessionName)
	delete(sess.Values, "user")
	sess.Options.MaxAge = -1
	_ = sess.Save(r, w)
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// ---- Pages ------------------------------------------------------------------

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	apps := s.collect(r.Context())
	healthy := s.dokku.DokkuContainerHealthy(r.Context())
	data := map[string]any{
		"Env":     s.cfg.EnvName,
		"Base":    s.cfg.BaseDomain,
		"Apps":    apps,
		"Healthy": healthy,
	}
	if r.Header.Get("HX-Request") == "true" {
		s.renderPartial(w, "apps_table.html", data)
		return
	}
	s.render(w, "index.html", data)
}

func (s *server) handleApp(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	app := s.dokku.AppDetails(r.Context(), name)
	s.render(w, "app.html", map[string]any{
		"Env":  s.cfg.EnvName,
		"Base": s.cfg.BaseDomain,
		"App":  app,
	})
}

func (s *server) handleAction(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	verb := chi.URLParam(r, "verb")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	out, err := s.dokku.Action(ctx, name, verb)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if err != nil {
		w.WriteHeader(http.StatusBadGateway)
		fmt.Fprintf(w, "FAILED %s %s\n%s\n%v\n", verb, name, out, err)
		return
	}
	fmt.Fprintf(w, "OK %s %s\n%s", verb, name, out)
}

func (s *server) handleLogStream(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	for _, e := range s.logs.Snapshot(name) {
		fmt.Fprintf(w, "data: %s %s\n\n", e.At.UTC().Format(time.RFC3339), e.Line)
	}
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	_ = s.dokku.StreamLogs(r.Context(), name, w, func(line string) {
		s.logs.Append(name, line)
	})
}

func (s *server) handleLogDump(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.log"`, name))
	_, _ = w.Write([]byte(s.logs.Dump(name)))
}

func (s *server) handleAPIApps(w http.ResponseWriter, r *http.Request) {
	apps := s.collect(r.Context())
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprint(w, "[")
	for i, a := range apps {
		if i > 0 {
			fmt.Fprint(w, ",")
		}
		fmt.Fprintf(w,
			`{"name":%q,"role":%q,"tenant":%q,"state":%q,"image":%q,"http":%q,"int_port":%q,"host_ports":%q,"procs":%q,"domains":%q}`,
			a.Name, a.Role, a.Tenant, a.State, a.Image, a.HTTPCode, a.IntPort, a.HostPorts,
			strings.Join(a.Procs, ","), strings.Join(a.Domains, ","))
	}
	fmt.Fprint(w, "]")
}

// handleEvents pushes a server-sent events stream that emits a JSON snapshot
// of all apps every 3s. The browser merges deltas into the DOM with smooth
// transitions, avoiding the table-flicker of full polled re-renders.
func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)

	push := func() bool {
		apps := s.collect(r.Context())
		healthy := s.dokku.DokkuContainerHealthy(r.Context())
		var b strings.Builder
		b.WriteString(`{"healthy":`)
		if healthy {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
		b.WriteString(`,"apps":[`)
		for i, a := range apps {
			if i > 0 {
				b.WriteByte(',')
			}
			fmt.Fprintf(&b,
				`{"name":%q,"role":%q,"tenant":%q,"state":%q,"image":%q,"http":%q,"int_port":%q,"host_ports":%q,"procs":%q,"domains":%q}`,
				a.Name, a.Role, a.Tenant, a.State, a.Image, a.HTTPCode, a.IntPort, a.HostPorts,
				strings.Join(a.Procs, ","), strings.Join(a.Domains, ","))
		}
		b.WriteString("]}")
		if _, err := fmt.Fprintf(w, "event: snapshot\ndata: %s\n\n", b.String()); err != nil {
			return false
		}
		if flusher != nil {
			flusher.Flush()
		}
		return true
	}

	if !push() {
		return
	}
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-t.C:
			if !push() {
				return
			}
		}
	}
}

func (s *server) handleConsolePage(w http.ResponseWriter, _ *http.Request) {
	s.render(w, "console.html", map[string]any{
		"Env":     s.cfg.EnvName,
		"Allowed": dokku.AllowedDokkuCommands(),
	})
}

func (s *server) handleConsoleAllowed(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprint(w, "[")
	for i, a := range dokku.AllowedDokkuCommands() {
		if i > 0 {
			fmt.Fprint(w, ",")
		}
		fmt.Fprintf(w, "%q", a)
	}
	fmt.Fprint(w, "]")
}

// handleConsoleRun streams the output of a user-supplied dokku command back as
// SSE. The command is parsed, allow-listed, and executed inside the dokku
// container. Any input that contains a shell metacharacter is rejected.
func (s *server) handleConsoleRun(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	cmdLine := strings.TrimSpace(r.FormValue("cmd"))
	if cmdLine == "" {
		http.Error(w, "empty", http.StatusBadRequest)
		return
	}
	if strings.ContainsAny(cmdLine, "|;&`$<>\\\n\r") {
		http.Error(w, "shell metacharacters not allowed", http.StatusBadRequest)
		return
	}
	argv := strings.Fields(cmdLine)
	if !dokku.IsAllowedDokkuCommand(argv[0]) {
		http.Error(w, "command not allowed", http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	if err := s.dokku.RunDokku(ctx, w, argv); err != nil {
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", err.Error())
	}
	fmt.Fprint(w, "event: done\ndata: end\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// ---- Helpers ----------------------------------------------------------------

func (s *server) handleScriptsPage(w http.ResponseWriter, _ *http.Request) {
	s.render(w, "scripts.html", map[string]any{
		"Env":     s.cfg.EnvName,
		"Scripts": scripts.Catalog(),
	})
}

func (s *server) handleScriptPage(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	sc := scripts.Find(name)
	if sc == nil {
		http.NotFound(w, r)
		return
	}
	s.render(w, "script.html", map[string]any{
		"Env":             s.cfg.EnvName,
		"Script":          sc,
		"RunnerConfigured": s.cfg.ScriptsHostPath != "",
	})
}

// handleScriptRun takes form values, builds an argv, and streams the script's
// output back as SSE. Inputs are validated against the script's field schema
// and the strict character allow-list in the runner package.
func (s *server) handleScriptRun(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	sc := scripts.Find(name)
	if sc == nil {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	argv, err := buildArgv(sc, r.PostForm)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	fmt.Fprintf(w, "data: $ bash scripts/%s %s\n\n", sc.Name, strings.Join(argv, " "))
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
	defer cancel()
	if err := s.runner.Run(ctx, w, sc.Name, argv); err != nil {
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", err.Error())
	}
	fmt.Fprint(w, "event: done\ndata: end\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// buildArgv translates a posted form into the script's argv list. Positional
// fields (Name starts with "_pos_") are emitted first in declaration order;
// flag fields follow. KV ("key=value" lines) become repeated --flag pairs.
// Special: fields with Flag:"--env" are formatted as KEY=VALUE pairs.
func buildArgv(sc *scripts.Script, form url.Values) ([]string, error) {
	var positionals, flags []string
	for _, f := range sc.Fields {
		v := strings.TrimSpace(form.Get(f.Name))
		if f.Boolean {
			if form.Get(f.Name) != "" {
				flags = append(flags, f.Flag)
			}
			continue
		}
		if v == "" {
			if f.Required {
				return nil, fmt.Errorf("%s is required", f.Label)
			}
			continue
		}
		switch f.Type {
		case "kv":
			for _, ln := range strings.Split(v, "\n") {
				ln = strings.TrimSpace(ln)
				if ln == "" {
					continue
				}
				if !strings.Contains(ln, "=") {
					return nil, fmt.Errorf("%s line %q must be KEY=VALUE", f.Label, ln)
				}
				flags = append(flags, f.Flag, ln)
			}
		default:
			if strings.HasPrefix(f.Name, "_pos_") {
				positionals = append(positionals, v)
			} else if f.Flag == "--env" {
				// Convert field name to uppercase env var name (admin_user -> ADMIN_USER)
				envKey := strings.ToUpper(f.Name)
				flags = append(flags, f.Flag, envKey+"="+v)
			} else {
				flags = append(flags, f.Flag, v)
			}
		}
	}
	return append(positionals, flags...), nil
}

func (s *server) collect(ctx context.Context) []dokku.App {
	names, _ := s.dokku.AppsList(ctx)
	out := make([]dokku.App, 0, len(names))
	for _, n := range names {
		out = append(out, s.dokku.AppDetails(ctx, n))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (s *server) render(w http.ResponseWriter, name string, data any) {
	t, ok := s.pages[name]
	if !ok {
		http.Error(w, "unknown template: "+name, http.StatusInternalServerError)
		return
	}
	if m, ok := data.(map[string]any); ok {
		mysqlConfigured := s.cfg.EnvName == "prod" || strings.TrimSpace(getenv("MYSQL_ROOT_PASSWORD")) != ""
		mysqlPlaceholder := strings.TrimSpace(getenv("MYSQL_ROOT_PASSWORD")) == "changeme"
		m["MySQLConfigured"] = mysqlConfigured && !mysqlPlaceholder
		m["MySQLNeedsConfig"] = mysqlPlaceholder || !mysqlConfigured
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := t.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func (s *server) renderPartial(w http.ResponseWriter, name string, data any) {
	t, ok := s.pages[name]
	if !ok {
		http.Error(w, "unknown template: "+name, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := t.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func getenv(key string) string {
	return os.Getenv(key)
}

var validName = func() func(string) bool {
	allowed := func(r rune) bool {
		return (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-'
	}
	return func(s string) bool {
		if s == "" || len(s) > 64 {
			return false
		}
		for _, r := range s {
			if !allowed(r) {
				return false
			}
		}
		return true
	}
}()

func validAppName(s string) bool { return validName(s) }

func stateClass(state string) string {
	switch state {
	case "running":
		return "bg-emerald-500/15 text-emerald-400 ring-emerald-500/30"
	case "restarting", "mixed", "created":
		return "bg-amber-500/15 text-amber-400 ring-amber-500/30"
	case "stopped", "exited", "dead", "paused":
		return "bg-rose-500/15 text-rose-400 ring-rose-500/30"
	case "not-deployed":
		return "bg-zinc-700/40 text-zinc-300 ring-zinc-500/30"
	default:
		return "bg-zinc-700/40 text-zinc-300 ring-zinc-500/30"
	}
}

func httpClass(code string) string {
	switch {
	case strings.HasPrefix(code, "2"), strings.HasPrefix(code, "3"):
		return "text-emerald-400"
	case code == "000", code == "":
		return "text-rose-400"
	default:
		return "text-amber-400"
	}
}
