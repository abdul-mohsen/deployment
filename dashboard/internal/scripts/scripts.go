// Package scripts knows about the deployment shell scripts and how to invoke
// them safely.
//
// Scripts are not executed inside the dashboard container directly: instead
// the dashboard spawns a one-shot `docker run` of the BASH_RUNNER_IMAGE with
// the scripts directory mounted in. This avoids having to install bash, the
// mysql client, and friends into the dashboard image (which is impossible
// behind some corporate TLS proxies). The spawned container talks to the
// host's Docker daemon via the same socket the dashboard uses.
package scripts

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

// Field describes one input on a script's form.
type Field struct {
	Name        string   // form field name (also used in argv synthesis when --arg-style)
	Label       string
	Help        string
	Type        string   // "text" | "select" | "checkbox" | "kv" (KEY=VALUE list)
	Placeholder string
	Required    bool
	Options     []string // for type=select
	Flag        string   // CLI flag, e.g. "--type"; empty -> positional
	Boolean     bool     // when true, presence appends Flag (no value)
}

// Script is a registered orchestration script the UI can invoke.
type Script struct {
	Name    string  // script file name in scripts/ (e.g. "create-tenant.sh")
	Title   string
	Summary string
	Danger  bool    // confirmation required in UI
	Image   string  // override runner image; empty -> Runner.runnerImage default
	Fields  []Field // ordered
}

// Catalog returns the curated list of scripts the dashboard exposes.
//
// Adding a new script: drop it into ./scripts/ and add an entry here. Only
// scripts in this list are executable; anything else is rejected.
func Catalog() []Script {
	return []Script{
		{
			Name: "status.sh", Title: "Status", Summary: "Live tenant health overview.",
			Fields: []Field{
				{Name: "tenant", Label: "Tenant filter", Flag: "--tenant", Type: "text", Placeholder: "(all)"},
				{Name: "json", Label: "JSON output", Flag: "--json", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "list-tenants.sh", Title: "List tenants", Summary: "Tenant pairs and their status.",
		},
		{
			Name: "create-tenant.sh", Title: "Create tenant",
			Summary: "Provision a new tenant (backend + frontend + storage + SSL).",
			Danger:  true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true, Placeholder: "acme"},
				{Name: "admin_user", Label: "Admin username", Flag: "--env", Type: "text", Required: true, Placeholder: "admin"},
				{Name: "company_name", Label: "Company name", Flag: "--env", Type: "text", Required: true, Placeholder: "ACME Corp"},
				{Name: "backend_image", Label: "Backend image", Flag: "--backend-image", Type: "text", Placeholder: "ssdawweq/ifritah-api:dev",
					Help: "Requires database provisioning to be configured in config.env, or explicit DATABASE_URL/DB_* env vars below."},
				{Name: "frontend_image", Label: "Frontend image", Flag: "--frontend-image", Type: "text", Placeholder: "ssdawweq/ifritah-web:dev"},
				{Name: "backend_port", Label: "Backend port", Flag: "--backend-port", Type: "text", Placeholder: "8090"},
				{Name: "frontend_port", Label: "Frontend port", Flag: "--frontend-port", Type: "text", Placeholder: "8000"},
				{Name: "no_database", Label: "Skip database", Flag: "--no-database", Type: "checkbox", Boolean: true,
					Help: "Only use this if the backend can boot without a DB, or if you provide DATABASE_URL/DB_* in Env vars."},
				{Name: "git_only", Label: "Git-only (no deploy)", Flag: "--git-only", Type: "checkbox", Boolean: true},
				{Name: "dry_run", Label: "Dry run", Flag: "--dry-run", Type: "checkbox", Boolean: true},
				{Name: "envs", Label: "Env vars", Flag: "--env", Type: "kv",
					Help: "One KEY=VALUE per line; each becomes a separate --env flag. Use this for DATABASE_URL or DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD when not provisioning MySQL from this script."},
			},
		},
		{
			Name: "remove-tenant.sh", Title: "Remove tenant", Summary: "Tear down a tenant.", Danger: true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true},
				{Name: "delete_data", Label: "Delete data", Flag: "--delete-data", Type: "checkbox", Boolean: true},
				{Name: "force", Label: "Force", Flag: "--force", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "deploy-all.sh", Title: "Deploy image",
			Summary: "Roll an image to all tenants (canary-first), or a single tenant.",
			Danger:  true,
			Fields: []Field{
				{Name: "_pos_image", Label: "Image", Type: "text", Required: true, Placeholder: "ssdawweq/ifritah-api:dev"},
				{Name: "type", Label: "App type", Flag: "--type", Type: "select", Options: []string{"backend", "frontend"}},
				{Name: "tenant", Label: "Single tenant", Flag: "--tenant", Type: "text"},
				{Name: "skip_canary", Label: "Skip canary", Flag: "--skip-canary", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "rollback-tenant.sh", Title: "Rollback tenant",
			Summary: "Roll a tenant back to a previous image.", Danger: true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true},
				{Name: "type", Label: "App type", Flag: "--type", Type: "select", Options: []string{"backend", "frontend"}},
				{Name: "to", Label: "Image to roll back to", Flag: "--to", Type: "text"},
				{Name: "list", Label: "List recent deploys", Flag: "--list", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "set-tenant-image.sh", Title: "Pin image",
			Summary: "Pin (or unpin) a tenant to a specific image.",
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Placeholder: "(omit with --list)"},
				{Name: "backend", Label: "Backend image", Flag: "--backend", Type: "text"},
				{Name: "frontend", Label: "Frontend image", Flag: "--frontend", Type: "text"},
				{Name: "unpin", Label: "Unpin", Flag: "--unpin", Type: "checkbox", Boolean: true},
				{Name: "list", Label: "List pins", Flag: "--list", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "update-tenant.sh", Title: "Update tenant", Summary: "Update images, env, scale, restart.",
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true},
				{Name: "backend_image", Label: "Backend image", Flag: "--backend-image", Type: "text"},
				{Name: "frontend_image", Label: "Frontend image", Flag: "--frontend-image", Type: "text"},
				{Name: "scale", Label: "Backend scale", Flag: "--scale", Type: "text", Placeholder: "1"},
				{Name: "restart", Label: "Restart", Flag: "--restart", Type: "checkbox", Boolean: true},
				{Name: "envs", Label: "Env vars", Flag: "--env", Type: "kv"},
			},
		},
		{
			Name: "backup-tenant.sh", Title: "Backup tenant", Summary: "Dump a tenant's data + DB.",
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant (or leave blank with --all)", Type: "text"},
				{Name: "all", Label: "All tenants", Flag: "--all", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "tail-logs.sh", Title: "Aggregate logs",
			Summary: "Tail logs from one or all tenants. Use --since to limit.",
			Fields: []Field{
				{Name: "tenant", Label: "Tenant", Flag: "--tenant", Type: "text"},
				{Name: "type", Label: "App type", Flag: "--type", Type: "select", Options: []string{"backend", "frontend"}},
				{Name: "grep", Label: "Pattern", Flag: "--grep", Type: "text"},
				{Name: "since", Label: "Since (e.g. 1h)", Flag: "--since", Type: "text"},
			},
		},
		{
			Name: "verify-mysql.sh", Title: "Verify MySQL", Summary: "Sanity-check the admin connection from a container.",
		},
		{
			Name: "auto-pull.sh", Title: "Run auto-pull",
			Summary: "Force one auto-pull cycle (normally cron does this every 2m).",
			Fields: []Field{
				{Name: "type", Label: "Type", Flag: "--type", Type: "select", Options: []string{"both", "backend", "frontend"}},
			},
		},
		{
			Name: "setup-dev-tenant.sh", Title: "Setup dev tenant", Summary: "Idempotently create the dev tenant.",
			Fields: []Field{
				{Name: "name", Label: "Tenant name", Flag: "--name", Type: "text"},
				{Name: "tag", Label: "Image tag", Flag: "--tag", Type: "text"},
				{Name: "frontend", Label: "Pin frontend too", Flag: "--frontend", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "cleanup-old-files.sh", Title: "Cleanup old files",
			Summary: "Remove leftover Compose+Traefik files from the pre-Dokku layout.", Danger: true,
		},
	}
}

// Find returns the script with the given file name, or nil.
func Find(name string) *Script {
	for i := range Catalog() {
		if Catalog()[i].Name == name {
			s := Catalog()[i]
			return &s
		}
	}
	return nil
}

// Runner executes scripts in a one-shot sidecar container so the dashboard
// image doesn't need bash / mysql-client / curl installed locally.
type Runner struct {
	dockerBin       string
	runnerImage     string // e.g. "mysql:8.0" — has bash, curl, mysql client
	scriptsHostPath string // host path to /opt/deployment (mounted into runner)
	configFile      string // optional --config path inside runner
}

// NewRunner builds a runner. scriptsHostPath is the path on the docker
// daemon's host (NOT inside the dashboard container) to the deployment dir.
func NewRunner(dockerBin, runnerImage, scriptsHostPath, configFile string) *Runner {
	if runnerImage == "" {
		runnerImage = "dokku/dokku:latest"
	}
	return &Runner{
		dockerBin:       dockerBin,
		runnerImage:     runnerImage,
		scriptsHostPath: scriptsHostPath,
		configFile:      configFile,
	}
}

// safeArg only allows characters that cannot escape an argv slot. We split on
// whitespace ourselves and pass each piece as a discrete argv element, but we
// still defensively reject anything that looks like a shell metachar so a
// pasted command can't surprise us. Spaces and tabs are safe in arg values.
var safeArg = regexp.MustCompile(`^[A-Za-z0-9._@/:=+,\-\s]+$`)

func validateArgs(argv []string) error {
	for _, a := range argv {
		if a == "" {
			return errors.New("empty argument")
		}
		if !safeArg.MatchString(a) {
			return fmt.Errorf("argument %q contains disallowed characters", a)
		}
	}
	return nil
}

// Run executes a script with already-built argv (extra flags after the script
// name). Output is streamed to w line-by-line as SSE `data:` frames.
func (r *Runner) Run(ctx context.Context, w io.Writer, scriptName string, argv []string) error {
	sc := Find(scriptName)
	if sc == nil {
		return fmt.Errorf("script %q is not in the catalog", scriptName)
	}
	img := sc.Image
	if img == "" {
		img = r.runnerImage
	}
	if r.scriptsHostPath == "" {
		return errors.New("SCRIPTS_HOST_PATH is not set; cannot mount scripts into runner container")
	}
	if err := validateArgs(argv); err != nil {
		return err
	}
	if r.configFile != "" {
		argv = append(argv, "--config", r.configFile)
	}

	full := []string{
		"run", "--rm", "-i",
		"-v", "/var/run/docker.sock:/var/run/docker.sock",
		"-v", r.scriptsHostPath + ":/opt/deployment:ro",
		"--network", "host",
		img,
		// CRLF tolerance: scripts authored on Windows have \r line endings
		// which break bash. Stage to a writable dir, strip CRLF, then exec.
		"bash", "-c", `
set -e
mkdir -p /tmp/dep
cp -r /opt/deployment/scripts /tmp/dep/
[ -f /opt/deployment/config.env ] && cp /opt/deployment/config.env /tmp/dep/ || true
[ -f /opt/deployment/install.env ] && cp /opt/deployment/install.env /tmp/dep/ || true
find /tmp/dep -type f \( -name '*.sh' -o -name '*.env' \) -exec sed -i 's/\r$//' {} +
cd /tmp/dep
NAME="$1"; shift
exec bash "scripts/$NAME" "$@"
`,
		"--", scriptName,
	}
	full = append(full, argv...)

	cmd := exec.CommandContext(ctx, r.dockerBin, full...)
	cmd.Env = append(os.Environ(), "TERM=dumb")
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
		line := stripAnsi(scanner.Text())
		if _, werr := fmt.Fprintf(w, "data: %s\n\n", line); werr != nil {
			_ = cmd.Process.Kill()
			break
		}
		if f, ok := w.(interface{ Flush() }); ok {
			f.Flush()
		}
	}
	return cmd.Wait()
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

func stripAnsi(s string) string { return ansi.ReplaceAllString(strings.ReplaceAll(s, "\r", ""), "") }
