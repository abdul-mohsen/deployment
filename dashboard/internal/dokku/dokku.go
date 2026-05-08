// Package dokku wraps the docker / dokku CLIs to inspect and control apps.
//
// All operations shell out to the local docker binary (which must be mounted
// from the host) and execute dokku commands inside the dokku-in-docker
// container via `docker exec`.
package dokku

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// Client is a thin wrapper around the docker + dokku CLIs.
type Client struct {
	dockerBin string
	dokkuName string
}

// New returns a client. dockerBin is the docker executable on the host
// (typically "docker"); dokkuName is the dokku container name (typically
// "dokku").
func New(dockerBin, dokkuName string) *Client {
	return &Client{dockerBin: dockerBin, dokkuName: dokkuName}
}

// App is a single Dokku app with the data needed to render the list page.
type App struct {
	Name        string
	Role        string // backend / frontend / app
	Tenant      string
	State       string // running / stopped / not-deployed / restarting / mixed / unknown
	Image       string
	RestartCnt  string
	Procs       []string
	IntPort     string
	HostPorts   string
	Domains     []string
	HTTPCode    string
	ContainerID string
}

var nameLine = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// AppsList returns all Dokku apps registered on the host.
func (c *Client) AppsList(ctx context.Context) ([]string, error) {
	out, err := c.exec(ctx, c.dockerBin, "exec", "-i", c.dokkuName, "dokku", "--quiet", "apps:list")
	if err != nil {
		return nil, err
	}
	var apps []string
	for _, ln := range strings.Split(out, "\n") {
		ln = strings.TrimSpace(ln)
		if nameLine.MatchString(ln) {
			apps = append(apps, ln)
		}
	}
	return apps, nil
}

// AppDetails populates an App with current state from docker + dokku.
func (c *Client) AppDetails(ctx context.Context, name string) App {
	a := App{Name: name, Role: roleOf(name), Tenant: tenantOf(name)}
	a.ContainerID = c.containerID(ctx, name)
	a.State = c.appState(ctx, name, a.ContainerID)
	if a.ContainerID != "" {
		a.Image = c.inspectField(ctx, a.ContainerID, "{{.Config.Image}}")
		a.RestartCnt = c.inspectField(ctx, a.ContainerID, "{{.RestartCount}}")
		a.HostPorts = c.hostPorts(ctx, a.ContainerID)
	}
	a.IntPort = c.intPort(ctx, name)
	a.Procs = c.procTypes(ctx, name)
	a.Domains = c.domains(ctx, name)
	if a.ContainerID != "" {
		path := "/"
		if a.Role == "backend" {
			path = "/healthz"
		}
		a.HTTPCode = c.httpProbe(ctx, name, path)
	} else {
		a.HTTPCode = "000"
	}
	return a
}

func (c *Client) containerID(ctx context.Context, app string) string {
	id, _ := c.exec(ctx, c.dockerBin, "ps",
		"--filter", "label=com.dokku.app-name="+app,
		"--filter", "label=com.dokku.process-type=web",
		"--format", "{{.ID}}")
	id = firstLine(id)
	if id == "" {
		id, _ = c.exec(ctx, c.dockerBin, "ps",
			"--filter", "label=com.dokku.app-name="+app,
			"--format", "{{.ID}}")
		id = firstLine(id)
	}
	return id
}

func (c *Client) appState(ctx context.Context, app, cid string) string {
	report, err := c.dokku(ctx, "ps:report", app)
	if err != nil {
		return "unknown"
	}
	deployed := fieldFromReport(report, "Deployed:")
	running := fieldFromReport(report, "Running:")
	if !strings.EqualFold(deployed, "true") {
		return "not-deployed"
	}
	state := "unknown"
	switch strings.ToLower(running) {
	case "true":
		state = "running"
	case "false":
		state = "stopped"
	case "mixed":
		state = "mixed"
	}
	if cid != "" {
		cs := c.inspectField(ctx, cid, "{{.State.Status}}")
		switch cs {
		case "restarting", "exited", "dead", "paused":
			state = cs
		}
	}
	return state
}

func (c *Client) inspectField(ctx context.Context, cid, tmpl string) string {
	out, _ := c.exec(ctx, c.dockerBin, "inspect", "-f", tmpl, cid)
	return strings.TrimSpace(out)
}

func (c *Client) hostPorts(ctx context.Context, cid string) string {
	tmpl := `{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}}->{{$p}} {{end}}{{end}}`
	out, _ := c.exec(ctx, c.dockerBin, "inspect", "-f", tmpl, cid)
	return strings.TrimSpace(out)
}

func (c *Client) intPort(ctx context.Context, app string) string {
	out, err := c.dokku(ctx, "ports:report", app)
	if err != nil {
		return ""
	}
	for _, ln := range strings.Split(out, "\n") {
		if strings.Contains(ln, "Ports map:") {
			parts := strings.Split(ln, ":")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	return ""
}

func (c *Client) procTypes(ctx context.Context, app string) []string {
	out, err := c.dokku(ctx, "ps:scale", app)
	if err != nil {
		return nil
	}
	var procs []string
	for i, ln := range strings.Split(out, "\n") {
		if i < 2 {
			continue
		}
		f := strings.Fields(ln)
		if len(f) > 0 {
			procs = append(procs, f[0])
		}
	}
	return procs
}

func (c *Client) domains(ctx context.Context, app string) []string {
	out, err := c.dokku(ctx, "domains:report", app, "--domains-app-vhosts")
	if err != nil {
		return nil
	}
	out = strings.TrimSpace(out)
	if out == "" {
		return nil
	}
	return strings.Fields(out)
}

func (c *Client) httpProbe(ctx context.Context, app, path string) string {
	out, _ := c.exec(ctx, c.dockerBin, "exec", "-i", c.dokkuName, "bash", "-lc",
		fmt.Sprintf(`curl -sS -o /dev/null -w '%%{http_code}' --max-time 5 http://%s.web%s`, app, path))
	out = strings.TrimSpace(out)
	if out == "" {
		return "000"
	}
	return out
}

// Action runs a Dokku lifecycle action against an app.
//
// verb must be one of: start, stop, restart, rebuild.
func (c *Client) Action(ctx context.Context, app, verb string) (string, error) {
	switch verb {
	case "start", "stop", "restart", "rebuild":
	default:
		return "", fmt.Errorf("invalid action %q", verb)
	}
	return c.dokku(ctx, "ps:"+verb, app)
}

// StreamLogs invokes `dokku logs --tail -t <app>` and writes lines to w until
// the context is cancelled. The writer is flushed after every line if it
// implements http.Flusher (caller's responsibility — see web.handleLogs).
func (c *Client) StreamLogs(ctx context.Context, app string, w io.Writer, onLine func(string)) error {
	cmd := exec.CommandContext(ctx, c.dockerBin, "exec", "-i", c.dokkuName,
		"dokku", "logs", app, "--tail", "-t")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return err
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if onLine != nil {
			onLine(line)
		}
		if _, err := fmt.Fprintf(w, "data: %s\n\n", line); err != nil {
			_ = cmd.Process.Kill()
			break
		}
		if f, ok := w.(interface{ Flush() }); ok {
			f.Flush()
		}
	}
	_ = cmd.Wait()
	return scanner.Err()
}

// DokkuContainerHealthy returns true when the dokku container is running.
func (c *Client) DokkuContainerHealthy(ctx context.Context) bool {
	out, err := c.exec(ctx, c.dockerBin, "inspect", "-f", "{{.State.Status}}", c.dokkuName)
	if err != nil {
		return false
	}
	return strings.TrimSpace(out) == "running"
}

func (c *Client) dokku(ctx context.Context, args ...string) (string, error) {
	full := append([]string{"exec", "-i", c.dokkuName, "dokku"}, args...)
	return c.exec(ctx, c.dockerBin, full...)
}

func (c *Client) exec(ctx context.Context, name string, args ...string) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, name, args...).CombinedOutput()
	return string(out), err
}

// Helpers ---------------------------------------------------------------------

func roleOf(app string) string {
	switch {
	case strings.HasSuffix(app, "-backend"):
		return "backend"
	case strings.HasSuffix(app, "-frontend"):
		return "frontend"
	default:
		return "app"
	}
}

func tenantOf(app string) string {
	switch {
	case strings.HasSuffix(app, "-backend"):
		return strings.TrimSuffix(app, "-backend")
	case strings.HasSuffix(app, "-frontend"):
		return strings.TrimSuffix(app, "-frontend")
	default:
		return app
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}

func fieldFromReport(report, label string) string {
	for _, ln := range strings.Split(report, "\n") {
		if i := strings.Index(ln, label); i >= 0 {
			return strings.TrimSpace(ln[i+len(label):])
		}
	}
	return ""
}
