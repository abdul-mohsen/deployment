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
	"strconv"
	"strings"
	"sync"
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
	cfg       config.Config
	dokku     *dokku.Client
	logs      *logbuf.Store
	runner    *scripts.Runner
	pages     map[string]*template.Template
	store     *sessions.CookieStore
	snapshots *snapshotCache
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
	layoutPages := []string{"index.html", "app.html", "tenant.html", "scripts.html", "script.html"}
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
	s.snapshots = newSnapshotCache(60*time.Second, s.collectSnapshot)
	s.snapshots.Start(context.Background())

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
		r.Get("/tenants/{name}", s.handleTenant)
		r.Post("/tenants/{name}/{verb}", s.handleTenantAction)
		r.Get("/apps/{name}", s.handleApp)
		r.Post("/apps/{name}/{verb}", s.handleAction)
		r.Get("/apps/{name}/logs", s.handleLogStream)
		r.Get("/apps/{name}/logs.txt", s.handleLogDump)
		r.Get("/api/apps", s.handleAPIApps)
		r.Get("/events", s.handleEvents)
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
	snap, _ := s.snapshots.Snapshot()
	data := map[string]any{
		"Env":        s.cfg.EnvName,
		"Base":       s.cfg.BaseDomain,
		"Apps":       snap.Apps,
		"Healthy":    snap.Healthy,
		"UpdatedAt":  snap.UpdatedAt,
		"Refreshing": snap.Refreshing,
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

func (s *server) handleTenant(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	apps := s.appsForTenant(r.Context(), name)
	if len(apps) == 0 {
		http.NotFound(w, r)
		return
	}
	for i := range apps {
		apps[i] = s.dokku.AppDetails(r.Context(), apps[i].Name)
	}
	var backend, frontend *dokku.App
	for i := range apps {
		switch apps[i].Role {
		case "backend":
			backend = &apps[i]
		case "frontend":
			frontend = &apps[i]
		}
	}
	s.render(w, "tenant.html", map[string]any{
		"Env":            s.cfg.EnvName,
		"Base":           s.cfg.BaseDomain,
		"Tenant":         name,
		"Apps":           apps,
		"Backend":        backend,
		"Frontend":       frontend,
		"Versions":       scripts.VersionCatalog(),
		"DefaultVersion": scripts.DefaultImageVersion(),
	})
}

func (s *server) handleTenantAction(w http.ResponseWriter, r *http.Request) {
	tenant := chi.URLParam(r, "name")
	verb := chi.URLParam(r, "verb")
	if !validAppName(tenant) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	if verb != "start" && verb != "stop" && verb != "restart" && verb != "rebuild" {
		http.Error(w, "invalid action", http.StatusBadRequest)
		return
	}
	apps := s.appsForTenant(r.Context(), tenant)
	if len(apps) == 0 {
		http.NotFound(w, r)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	failed := false
	var body strings.Builder
	for _, app := range apps {
		out, err := s.dokku.Action(ctx, app.Name, verb)
		if err != nil {
			failed = true
			fmt.Fprintf(&body, "FAILED %s %s\n%s\n%v\n", verb, app.Name, out, err)
			continue
		}
		fmt.Fprintf(&body, "OK %s %s\n%s\n", verb, app.Name, out)
	}
	s.snapshots.RefreshSoon()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if failed {
		w.WriteHeader(http.StatusBadGateway)
	}
	fmt.Fprint(w, body.String())
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
	s.snapshots.RefreshSoon()
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
	snap, _ := s.snapshots.Snapshot()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprint(w, appsJSON(snap.Apps))
}

// handleEvents pushes cached snapshots as the background collector refreshes.
func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)

	push := func(snap appSnapshot) bool {
		if _, err := fmt.Fprintf(w, "event: snapshot\ndata: %s\n\n", snapshotJSON(snap)); err != nil {
			return false
		}
		if flusher != nil {
			flusher.Flush()
		}
		return true
	}

	snap, seq := s.snapshots.Snapshot()
	if !push(snap) {
		return
	}
	for {
		next, nextSeq, ok := s.snapshots.Wait(r.Context(), seq)
		if !ok {
			return
		}
		seq = nextSeq
		if !push(next) {
			return
		}
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
		"Env":              s.cfg.EnvName,
		"Script":           sc,
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

	fmt.Fprintf(w, "data: $ bash scripts/%s %s\n\n", sc.Name, strings.Join(displayArgv(sc, argv), " "))
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
	form, err := expandImageVersion(sc, form)
	if err != nil {
		return nil, err
	}
	var positionals, flags []string
	for _, f := range sc.Fields {
		v := strings.TrimSpace(form.Get(f.Name))
		if f.Boolean {
			if form.Get(f.Name) != "" {
				flags = append(flags, f.Flag)
			}
			continue
		}
		if v == "" && f.Default != "" {
			v = f.Default
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
			} else if f.Flag == "" {
				continue
			} else if f.Flag == "--env" {
				// Convert field name to uppercase env var name (admin_user -> ADMIN_USER)
				envKey := strings.ToUpper(f.Name)
				flags = append(flags, f.Flag, envKey+"="+v)
			} else {
				flags = append(flags, f.Flag, v)
			}
		}
	}
	// Cross-field validation: if a manager username is supplied, demand a password too.
	if mu := strings.TrimSpace(form.Get("manager_user")); mu != "" {
		if strings.TrimSpace(form.Get("manager_password")) == "" {
			return nil, fmt.Errorf("Manager password is required when a Manager username is set")
		}
	}
	return append(positionals, flags...), nil
}

func expandImageVersion(sc *scripts.Script, form url.Values) (url.Values, error) {
	version := strings.TrimSpace(form.Get("image_version"))
	if version == "" {
		version = defaultFieldValue(sc, "image_version")
	}
	if version == "" {
		return form, nil
	}
	resolved, ok := scripts.ResolveImageVersion(version)
	if !ok {
		return nil, fmt.Errorf("unknown image version %q", version)
	}
	out := cloneValues(form)
	if scriptHasField(sc, "backend_image") && strings.TrimSpace(out.Get("backend_image")) == "" {
		out.Set("backend_image", resolved.BackendImage)
	}
	if scriptHasField(sc, "frontend_image") && strings.TrimSpace(out.Get("frontend_image")) == "" {
		out.Set("frontend_image", resolved.FrontendImage)
	}
	if scriptHasField(sc, "backend") && strings.TrimSpace(out.Get("backend")) == "" {
		out.Set("backend", resolved.BackendImage)
	}
	if scriptHasField(sc, "frontend") && strings.TrimSpace(out.Get("frontend")) == "" {
		out.Set("frontend", resolved.FrontendImage)
	}
	if scriptHasField(sc, "_pos_image") && strings.TrimSpace(out.Get("_pos_image")) == "" {
		image := resolved.BackendImage
		if strings.TrimSpace(out.Get("type")) == "frontend" {
			image = resolved.FrontendImage
		}
		out.Set("_pos_image", image)
	}
	if scriptHasField(sc, "to") && strings.TrimSpace(out.Get("to")) == "" {
		image := resolved.BackendImage
		if strings.TrimSpace(out.Get("type")) == "frontend" {
			image = resolved.FrontendImage
		}
		out.Set("to", image)
	}
	return out, nil
}

func defaultFieldValue(sc *scripts.Script, name string) string {
	for _, f := range sc.Fields {
		if f.Name == name {
			return strings.TrimSpace(f.Default)
		}
	}
	return ""
}

func scriptHasField(sc *scripts.Script, name string) bool {
	for _, f := range sc.Fields {
		if f.Name == name {
			return true
		}
	}
	return false
}

func cloneValues(in url.Values) url.Values {
	out := make(url.Values, len(in))
	for k, v := range in {
		vv := make([]string, len(v))
		copy(vv, v)
		out[k] = vv
	}
	return out
}

// displayArgv returns argv with values of secret fields replaced by ***
// for safe echoing in the streamed command line.
func displayArgv(sc *scripts.Script, argv []string) []string {
	secretEnv := map[string]bool{}
	for _, f := range sc.Fields {
		if f.Secret && f.Flag == "--env" {
			secretEnv[strings.ToUpper(f.Name)+"="] = true
		}
	}
	if len(secretEnv) == 0 {
		return argv
	}
	out := make([]string, len(argv))
	copy(out, argv)
	for i, a := range out {
		for prefix := range secretEnv {
			if strings.HasPrefix(a, prefix) {
				out[i] = prefix + "***"
				break
			}
		}
	}
	return out
}

func (s *server) collectSnapshot(ctx context.Context) appSnapshot {
	names, err := s.dokku.AppsList(ctx)
	containerIDs := s.dokku.ContainerIDsByApp(ctx)
	domains := s.dokku.DomainMap(ctx)
	detail := func(ctx context.Context, name string) dokku.App {
		return s.dokku.AppSummaryFrom(ctx, name, containerIDs[name], domains[name])
	}
	out := collectAppDetails(ctx, names, snapshotWorkerLimit(len(names)), detail)
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	snap := appSnapshot{
		Apps:    out,
		Healthy: s.dokku.DokkuContainerHealthy(ctx),
	}
	if err != nil {
		snap.Error = err.Error()
	}
	return snap
}

func collectAppDetails(ctx context.Context, names []string, workerLimit int, detail func(context.Context, string) dokku.App) []dokku.App {
	if len(names) == 0 {
		return nil
	}
	if workerLimit < 1 {
		workerLimit = 1
	}
	if workerLimit > len(names) {
		workerLimit = len(names)
	}

	jobs := make(chan string)
	results := make(chan dokku.App, len(names))
	var workers sync.WaitGroup

	for workerIndex := 0; workerIndex < workerLimit; workerIndex++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for appName := range jobs {
				select {
				case <-ctx.Done():
					return
				default:
				}
				app := detail(ctx, appName)
				select {
				case results <- app:
				case <-ctx.Done():
					return
				}
			}
		}()
	}

	go func() {
		defer close(jobs)
		for _, appName := range names {
			select {
			case jobs <- appName:
			case <-ctx.Done():
				return
			}
		}
	}()

	workers.Wait()
	close(results)

	out := make([]dokku.App, 0, len(names))
	for app := range results {
		out = append(out, app)
	}
	return out
}

func snapshotWorkerLimit(appCount int) int {
	if appCount <= 1 {
		return appCount
	}
	limit := 8
	if raw := strings.TrimSpace(os.Getenv("DASHBOARD_SNAPSHOT_WORKERS")); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			limit = parsed
		}
	}
	if limit < 1 {
		limit = 1
	}
	if limit > 16 {
		limit = 16
	}
	if limit > appCount {
		limit = appCount
	}
	return limit
}

func (s *server) appsForTenant(ctx context.Context, tenant string) []dokku.App {
	snap, _ := s.snapshots.Snapshot()
	apps := make([]dokku.App, 0, 2)
	for _, app := range snap.Apps {
		if app.Tenant == tenant {
			apps = append(apps, app)
		}
	}
	if len(apps) == 0 {
		names, err := s.dokku.AppsList(ctx)
		if err == nil {
			for _, name := range names {
				if name == tenant+"-backend" || name == tenant+"-frontend" {
					apps = append(apps, s.dokku.AppSummary(ctx, name))
				}
			}
		}
	}
	sort.Slice(apps, func(i, j int) bool { return apps[i].Name < apps[j].Name })
	return apps
}

func (s *server) render(w http.ResponseWriter, name string, data any) {
	t, ok := s.pages[name]
	if !ok {
		http.Error(w, "unknown template: "+name, http.StatusInternalServerError)
		return
	}
	if m, ok := data.(map[string]any); ok {
		pw := strings.TrimSpace(getenv("MYSQL_ROOT_PASSWORD"))
		user := strings.TrimSpace(getenv("MYSQL_ROOT_USER"))
		configured := pw != "" && pw != "changeme"
		m["MySQLConfigured"] = configured
		m["MySQLNeedsConfig"] = !configured
		m["MySQLAdminUser"] = user
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
