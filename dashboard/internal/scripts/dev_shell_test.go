package scripts

import (
	"strings"
	"testing"
)

// TestDevShellHasRawArgs guards against silently flipping RawArgs off on
// dev-shell.sh — without it the Go validateArgs allowlist blocks any docker
// command with {}%"' in it (Go templates, JSON payloads).
func TestDevShellHasRawArgs(t *testing.T) {
	sc := Find("dev-shell.sh")
	if sc == nil {
		t.Fatal("dev-shell.sh not in catalog")
	}
	if !sc.RawArgs {
		t.Errorf("dev-shell.sh must have RawArgs=true so its docker payloads with {}%%\"' are not rejected")
	}
}

// TestValidateArgsRejectsJSONPayload confirms the default (RawArgs=false)
// still blocks {}%"' as intended for all other scripts.
func TestValidateArgsRejectsJSONPayload(t *testing.T) {
	err := validateArgs([]string{`{"username":"admin"}`})
	if err == nil {
		t.Error("validateArgs should reject JSON-like input")
	}
	if err != nil && !strings.Contains(err.Error(), "disallowed") {
		t.Errorf("wrong error, got %v", err)
	}
}

// TestValidateArgsAcceptsPlainArg checks the allowlist doesn't over-reject
// normal arguments used by scripts like create-tenant.sh.
func TestValidateArgsAcceptsPlainArg(t *testing.T) {
	for _, a := range []string{
		"acme",
		"--backend-image",
		"ssdawweq/ifritah-api:dev",
		"ADMIN_PASSWORD=PadPass123",
		"/opt/deployment/config.env",
	} {
		if err := validateArgs([]string{a}); err != nil {
			t.Errorf("validateArgs(%q) unexpectedly failed: %v", a, err)
		}
	}
}
