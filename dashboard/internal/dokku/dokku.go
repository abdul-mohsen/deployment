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
	"net/http"
	"net/url"
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
	Name           string
	Role           string // backend / frontend / app
	Tenant         string
	State          string // running / stopped / not-deployed / restarting / mixed / unknown
	Image          string
	Version        string
	ImageRef       string
	ImageDigest    string
	ResolvedDigest string
	Channel        string
	SourceCommit   string
	DeployedAt     string
	LastOperation  string
	LastFailure    string
	Identity       BuildIdentity
	RestartCnt     string
	Procs          []string
	IntPort        string
	HostPorts      string
	Domains        []string
	HTTPCode       string
	ContainerID    string
	Liveness       HealthCheck
	Internal       HealthCheck
	External       HealthCheck
}

type containerSummary struct {
	State          string
	Image          string
	ResolvedDigest string
	ImageDigest    string
	Version        string
	ImageRef       string
	Channel        string
	SourceCommit   string
	DeployedAt     string
	RestartCnt     string
	Env            map[string]string
}

// HealthCheck is intentionally additive to the historical HTTPCode field. A
// code of 000 is not a health state: Reason explains what prevented a response.
type HealthCheck struct {
	Status   string `json:"status"`
	HTTPCode string `json:"http_code,omitempty"`
	Reason   string `json:"reason,omitempty"`
	URL      string `json:"url,omitempty"`
}

// BuildIdentity is the non-secret provenance contract recorded by deployment
// scripts and OCI image labels.
type BuildIdentity struct {
	Channel     string `json:"channel,omitempty"`
	Version     string `json:"version,omitempty"`
	Commit      string `json:"commit,omitempty"`
	ShortCommit string `json:"short_commit,omitempty"`
	ImageRef    string `json:"image_ref,omitempty"`
	Digest      string `json:"digest,omitempty"`
	WorkflowRun string `json:"workflow_run,omitempty"`
	DeployedAt  string `json:"deployed_at,omitempty"`
	Status      string `json:"status"`
	Reason      string `json:"reason,omitempty"`
}

var (
	nameLine          = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
	semanticVersion   = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
	digestValue       = regexp.MustCompile(`^sha256:[0-9a-fA-F]{64}$`)
	workflowRunNumber = regexp.MustCompile(`^[0-9]+$`)
)

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

// AppSummary is optimized for the dashboard grid. It avoids expensive per-app
// Dokku reports and uses Docker metadata plus domains, which keeps large tenant
// lists responsive.
func (c *Client) AppSummary(ctx context.Context, name string) App {
	return c.AppSummaryFrom(ctx, name, c.ContainerIDsByApp(ctx)[name], c.DomainMap(ctx)[name])
}

func (c *Client) AppSummaryFrom(ctx context.Context, name, containerID string, domains []string) App {
	app := App{Name: name, Role: roleOf(name), Tenant: tenantOf(name), HTTPCode: "000", Domains: domains}
	app.ContainerID = containerID
	if app.ContainerID == "" {
		app.State = "not-deployed"
		app.Liveness = HealthCheck{Status: "unknown", Reason: "no running container"}
		app.Internal = HealthCheck{Status: "not-checked", Reason: "no running container"}
		app.External = externalUnavailable(domains, "container is not running")
		app.Identity = missingIdentity("container has no build identity")
		return app
	}
	container := c.containerSummary(ctx, app.ContainerID)
	switch container.State {
	case "running":
		app.State = "running"
	case "exited":
		app.State = "stopped"
	case "":
		app.State = "unknown"
	default:
		app.State = container.State
	}
	app.Image = container.Image
	app.ImageRef = container.ImageRef
	app.ResolvedDigest = container.ResolvedDigest
	if repoDigest := c.inspectField(ctx, app.ContainerID, `{{index .RepoDigests 0}}`); repoDigest != "" {
		app.ResolvedDigest = digestFromRepoDigest(repoDigest)
	}
	app.Version = container.Version
	app.Channel = container.Channel
	app.SourceCommit = container.SourceCommit
	app.DeployedAt = container.DeployedAt
	if app.Version == "" {
		app.Version = imageTag(app.Image)
	}
	if app.ImageRef == "" {
		app.ImageRef = container.Env["APP_IMAGE_REF"]
	}
	app.ImageDigest = container.ImageDigest
	if app.ResolvedDigest == "" {
		app.ResolvedDigest = app.ImageDigest
	}
	app.Identity = buildIdentity(container.Env, app.ImageRef, app.ImageDigest, app.Version)
	if app.Channel == "" {
		app.Channel = app.Version
	}
	app.RestartCnt = container.RestartCnt
	app.Liveness = livenessForState(app.State)
	path := "/"
	if app.Role == "backend" {
		path = "/healthz"
	}
	if app.State == "running" {
		app.Internal = c.httpProbe(ctx, name, path)
		app.HTTPCode = app.Internal.HTTPCode
		app.External = c.externalProbe(ctx, domains, path)
	} else {
		app.Internal = HealthCheck{Status: "not-checked", HTTPCode: "000", Reason: "container is not running"}
		app.External = externalUnavailable(domains, "container is not running")
	}
	return app
}

func (c *Client) containerSummary(ctx context.Context, cid string) containerSummary {
	out, _ := c.exec(ctx, c.dockerBin, "inspect", "-f", `{{.State.Status}}
{{.Config.Image}}
{{.Image}}
{{.Created}}
{{.RestartCount}}
{{range $k, $v := .Config.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}
{{range .Config.Env}}{{println .}}{{end}}`, cid)
	lines := strings.Split(out, "\n")
	summary := containerSummary{Env: map[string]string{}}
	if len(lines) > 0 {
		summary.State = strings.TrimSpace(lines[0])
	}
	if len(lines) > 1 {
		summary.Image = strings.TrimSpace(lines[1])
	}
	imageID := ""
	if len(lines) > 2 {
		imageID = strings.TrimSpace(lines[2])
	}
	if imageID != "" {
		summary.ImageDigest = c.inspectImageDigest(ctx, imageID)
		summary.ResolvedDigest = summary.ImageDigest
	}
	if len(lines) > 3 {
		summary.DeployedAt = strings.TrimSpace(lines[3])
	}
	if len(lines) > 4 {
		summary.RestartCnt = strings.TrimSpace(lines[4])
	}
	for _, line := range lines[5:] {
		line = strings.TrimSpace(line)
		if i := strings.IndexByte(line, '='); i > 0 {
			summary.Env[line[:i]] = line[i+1:]
		}
		if strings.HasPrefix(line, "APP_IMAGE_VERSION=") {
			summary.Version = strings.TrimPrefix(line, "APP_IMAGE_VERSION=")
		} else if strings.HasPrefix(line, "APP_IMAGE_REF=") {
			summary.ImageRef = strings.TrimPrefix(line, "APP_IMAGE_REF=")
		} else if strings.HasPrefix(line, "org.opencontainers.image.version=") && summary.Version == "" {
			summary.Version = strings.TrimPrefix(line, "org.opencontainers.image.version=")
		} else if strings.HasPrefix(line, "org.opencontainers.image.revision=") {
			summary.SourceCommit = strings.TrimPrefix(line, "org.opencontainers.image.revision=")
		} else if strings.HasPrefix(line, "org.opencontainers.image.created=") && summary.DeployedAt == "" {
			summary.DeployedAt = strings.TrimPrefix(line, "org.opencontainers.image.created=")
		} else if strings.HasPrefix(line, "org.opencontainers.image.channel=") {
			summary.Channel = strings.TrimPrefix(line, "org.opencontainers.image.channel=")
		}
	}
	if summary.ImageRef == "" {
		summary.ImageRef = summary.Image
	}
	if summary.Channel == "" {
		summary.Channel = summary.Version
	}
	return summary
}

func (c *Client) inspectImageDigest(ctx context.Context, imageID string) string {
	out, _ := c.exec(ctx, c.dockerBin, "image", "inspect", "-f", "{{index .RepoDigests 0}}", imageID)
	ref := strings.TrimSpace(out)
	if at := strings.LastIndex(ref, "@"); at >= 0 {
		return ref[at+1:]
	}
	return ""
}

func (c *Client) ContainerIDsByApp(ctx context.Context) map[string]string {
	out, _ := c.exec(ctx, c.dockerBin, "ps", "-a",
		"--filter", "label=com.dokku.app-name",
		"--format", `{{.ID}} {{.Label "com.dokku.app-name"}} {{.Label "com.dokku.process-type"}}`)
	containers := map[string]string{}
	processTypes := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		containerID := fields[0]
		appName := fields[1]
		processType := ""
		if len(fields) > 2 {
			processType = fields[2]
		}
		if containers[appName] == "" || (processTypes[appName] != "web" && processType == "web") {
			containers[appName] = containerID
			processTypes[appName] = processType
		}
	}
	return containers
}

func (c *Client) DomainMap(ctx context.Context) map[string][]string {
	script := `for app_dir in /home/dokku/*; do
  [ -f "$app_dir/VHOST" ] || continue
  app="${app_dir##*/}"
  domains="$(tr '\n' ' ' < "$app_dir/VHOST" | xargs)"
  printf '%s\t%s\n' "$app" "$domains"
done`
	out, _ := c.exec(ctx, c.dockerBin, "exec", "-i", c.dokkuName, "bash", "-lc", script)
	domains := map[string][]string{}
	for _, line := range strings.Split(out, "\n") {
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
			continue
		}
		domains[strings.TrimSpace(parts[0])] = strings.Fields(parts[1])
	}
	return domains
}

// AppDetails populates an App with current state from docker + dokku.
func (c *Client) AppDetails(ctx context.Context, name string) App {
	a := App{Name: name, Role: roleOf(name), Tenant: tenantOf(name)}
	a.ContainerID = c.containerID(ctx, name)
	a.State = c.appState(ctx, name, a.ContainerID)
	if a.ContainerID != "" {
		container := c.containerSummary(ctx, a.ContainerID)
		a.Image = container.Image
		a.Version = container.Version
		if a.Version == "" {
			a.Version = imageTag(a.Image)
		}
		a.ImageRef = container.ImageRef
		if a.ImageRef == "" {
			a.ImageRef = container.Env["APP_IMAGE_REF"]
		}
		a.ImageDigest = container.ImageDigest
		a.ResolvedDigest = container.ResolvedDigest
		a.Channel = container.Channel
		a.SourceCommit = container.SourceCommit
		a.DeployedAt = container.DeployedAt
		a.Identity = buildIdentity(container.Env, a.ImageRef, a.ImageDigest, a.Version)
		a.RestartCnt = container.RestartCnt
		if a.Channel == "" {
			a.Channel = a.Version
		}
		a.HostPorts = c.hostPorts(ctx, a.ContainerID)
	}
	a.IntPort = c.intPort(ctx, name)
	a.Procs = c.procTypes(ctx, name)
	a.Domains = c.domains(ctx, name)
	if a.ContainerID != "" && a.State == "running" {
		path := "/"
		if a.Role == "backend" {
			path = "/healthz"
		}
		a.Liveness = livenessForState(a.State)
		a.Internal = c.httpProbe(ctx, name, path)
		a.External = c.externalProbe(ctx, a.Domains, path)
		a.HTTPCode = a.Internal.HTTPCode
	} else {
		a.HTTPCode = "000"
		a.Liveness = livenessForState(a.State)
		a.Internal = HealthCheck{Status: "not-checked", HTTPCode: "000", Reason: "container is not running"}
		a.External = externalUnavailable(a.Domains, "container is not running")
		a.Identity = missingIdentity("container has no build identity")
	}
	return a
}

func (c *Client) containerIDAny(ctx context.Context, app string) string {
	id, _ := c.exec(ctx, c.dockerBin, "ps", "-a",
		"--filter", "label=com.dokku.app-name="+app,
		"--filter", "label=com.dokku.process-type=web",
		"--format", "{{.ID}}")
	id = firstLine(id)
	if id == "" {
		id, _ = c.exec(ctx, c.dockerBin, "ps", "-a",
			"--filter", "label=com.dokku.app-name="+app,
			"--format", "{{.ID}}")
		id = firstLine(id)
	}
	return id
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

func (c *Client) exposedPort(ctx context.Context, cid string) string {
	tmpl := `{{range $p, $_ := .Config.ExposedPorts}}{{println $p}}{{end}}`
	out, _ := c.exec(ctx, c.dockerBin, "inspect", "-f", tmpl, cid)
	port := firstLine(out)
	port = strings.TrimSuffix(port, "/tcp")
	port = strings.TrimSuffix(port, "/udp")
	return strings.TrimSpace(port)
}

func (c *Client) envField(ctx context.Context, cid, key string) string {
	out, _ := c.exec(ctx, c.dockerBin, "inspect", "-f", `{{range .Config.Env}}{{println .}}{{end}}`, cid)
	prefix := key + "="
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

func imageTag(image string) string {
	lastSlash := strings.LastIndex(image, "/")
	lastColon := strings.LastIndex(image, ":")
	if lastColon > lastSlash {
		return image[lastColon+1:]
	}
	return ""
}

func digestFromRepoDigest(value string) string {
	value = strings.TrimSpace(value)
	if at := strings.LastIndex(value, "@"); at >= 0 && at+1 < len(value) {
		return value[at+1:]
	}
	return value
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

func (c *Client) httpProbe(ctx context.Context, app, path string) HealthCheck {
	target := fmt.Sprintf("http://%s.web%s", app, path)
	out, err := c.exec(ctx, c.dockerBin, "exec", "-i", c.dokkuName, "bash", "-lc",
		fmt.Sprintf(`curl -sS -o /dev/null -w '%%{http_code}\t%%{errormsg}' --max-time 5 %s`, target))
	return probeResult(target, out, err, "internal service")
}

func (c *Client) externalProbe(ctx context.Context, domains []string, path string) HealthCheck {
	if len(domains) == 0 || strings.TrimSpace(domains[0]) == "" {
		return externalUnavailable(domains, "no Dokku route is configured")
	}
	host := strings.TrimSpace(domains[0])
	if !strings.Contains(host, "://") {
		host = "https://" + host
	}
	u, err := url.Parse(host)
	if err != nil || u.Host == "" {
		return HealthCheck{Status: "unavailable", HTTPCode: "000", Reason: "invalid Dokku route"}
	}
	u.Path = path
	target := u.String()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return HealthCheck{Status: "unavailable", HTTPCode: "000", Reason: "could not create external probe: " + err.Error(), URL: target}
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return HealthCheck{Status: "unavailable", HTTPCode: "000", Reason: actionableProbeError(err), URL: target}
	}
	defer resp.Body.Close()
	return HealthCheck{Status: probeStatus(resp.StatusCode), HTTPCode: fmt.Sprintf("%d", resp.StatusCode), URL: target}
}

func probeResult(target, output string, err error, service string) HealthCheck {
	output = strings.TrimSpace(output)
	code := "000"
	reason := ""
	if tab := strings.LastIndexByte(output, '\t'); tab >= 3 {
		candidate := strings.TrimSpace(output[:tab])
		if len(candidate) >= 3 && allDigits(candidate[len(candidate)-3:]) {
			code = candidate[len(candidate)-3:]
			reason = strings.TrimSpace(output[tab+1:])
		}
	} else if len(output) >= 3 && allDigits(output[:3]) {
		code = output[:3]
		reason = strings.TrimSpace(output[3:])
	}
	if code == "" {
		code = "000"
	}

	if code == "000" {
		if reason == "" && err != nil {
			reason = actionableProbeError(err)
		}
		if reason == "" {
			reason = service + " did not return an HTTP response"
		}
		return HealthCheck{Status: "unavailable", HTTPCode: code, Reason: reason, URL: target}
	}
	return HealthCheck{Status: probeStatusString(code), HTTPCode: code, Reason: reason, URL: target}
}

func allDigits(value string) bool {
	for _, r := range value {
		if r < '0' || r > '9' {
			return false
		}
	}
	return value != ""
}

func probeStatus(code int) string {
	return probeStatusString(fmt.Sprintf("%d", code))
}

func probeStatusString(code string) string {
	if len(code) == 3 && (strings.HasPrefix(code, "2") || strings.HasPrefix(code, "3")) {
		return "healthy"
	}
	return "unhealthy"
}

func livenessForState(state string) HealthCheck {
	switch state {
	case "running":
		return HealthCheck{Status: "healthy", Reason: "container is running"}
	case "not-deployed":
		return HealthCheck{Status: "unknown", Reason: "app has not been deployed"}
	case "", "unknown":
		return HealthCheck{Status: "unknown", Reason: "container state is unknown"}
	default:
		return HealthCheck{Status: "unhealthy", Reason: "container state is " + state}
	}
}

func externalUnavailable(domains []string, reason string) HealthCheck {
	check := HealthCheck{Status: "unavailable", HTTPCode: "000", Reason: reason}
	if len(domains) > 0 {
		check.URL = strings.TrimSpace(domains[0])
	}
	return check
}

func actionableProbeError(err error) string {
	if err == nil {
		return ""
	}
	return "external route unavailable: " + err.Error()
}

func missingIdentity(reason string) BuildIdentity {
	return BuildIdentity{Status: "missing", Reason: reason}
}

func buildIdentity(env map[string]string, imageRef, imageDigest, version string) BuildIdentity {
	declaredDigest := firstNonEmpty(env["APP_IMAGE_DIGEST"])
	identity := BuildIdentity{
		Channel:     firstNonEmpty(env["APP_IMAGE_CHANNEL"], env["BUILD_CHANNEL"]),
		Version:     firstNonEmpty(env["APP_IMAGE_VERSION"], version),
		Commit:      firstNonEmpty(env["APP_IMAGE_COMMIT"], env["APP_SOURCE_COMMIT"], env["BUILD_COMMIT"]),
		ShortCommit: firstNonEmpty(env["APP_IMAGE_COMMIT_SHORT"], env["APP_SOURCE_COMMIT_SHORT"]),
		ImageRef:    firstNonEmpty(imageRef, env["APP_IMAGE_REF"]),
		Digest:      firstNonEmpty(declaredDigest, imageDigest),
		WorkflowRun: firstNonEmpty(env["APP_WORKFLOW_RUN"], env["BUILD_WORKFLOW_RUN"]),
		DeployedAt:  firstNonEmpty(env["APP_DEPLOYED_AT"], env["DEPLOYED_AT"]),
		Status:      "verified",
	}
	if identity.ShortCommit == "" && len(identity.Commit) > 7 {
		identity.ShortCommit = identity.Commit[:7]
	}
	missing := []string{}
	for _, field := range []struct {
		name  string
		value string
	}{
		{"channel", identity.Channel},
		{"version", identity.Version},
		{"commit", identity.Commit},
		{"image ref", identity.ImageRef},
		{"digest", identity.Digest},
		{"workflow run", identity.WorkflowRun},
		{"deployed_at", identity.DeployedAt},
	} {
		if strings.TrimSpace(field.value) == "" {
			missing = append(missing, field.name)
		}
	}
	if len(missing) > 0 {
		identity.Status = "missing"
		identity.Reason = "missing build identity fields: " + strings.Join(missing, ", ")
	} else if declaredDigest != "" && imageDigest != "" && !strings.EqualFold(declaredDigest, imageDigest) {
		identity.Status = "mismatch"
		identity.Reason = "recorded digest does not match the running image"
	} else if identity.Version != "dev" && !semanticVersion.MatchString(identity.Version) {
		identity.Status = "invalid"
		identity.Reason = "version is not semantic vMAJOR.MINOR.PATCH"
	} else if !digestValue.MatchString(identity.Digest) {
		identity.Status = "invalid"
		identity.Reason = "digest is not an immutable sha256 digest"
	} else if !workflowRunNumber.MatchString(identity.WorkflowRun) {
		identity.Status = "invalid"
		identity.Reason = "workflow run is not numeric"
	}
	return identity
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
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

// ConfigGet returns the value of a single Dokku config var for an app.
func (c *Client) ConfigGet(ctx context.Context, app, key string) (string, error) {
	out, err := c.exec(ctx, c.dockerBin, "exec", "-i", c.dokkuName,
		"dokku", "config:get", app, key)
	return strings.TrimSpace(out), err
}

// ConfigSet sets one or more KEY=VALUE pairs for a Dokku app (no-restart).
func (c *Client) ConfigSet(ctx context.Context, app string, kvs map[string]string) error {
	args := []string{"exec", "-i", c.dokkuName, "dokku", "config:set", "--no-restart", app}
	for k, v := range kvs {
		args = append(args, k+"="+v)
	}
	_, err := c.exec(ctx, c.dockerBin, args...)
	return err
}

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
