package dokku

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestProbeResultInternalHealthy(t *testing.T) {
	got := probeResult("http://dev-backend.web/healthz", "200\t", nil, "internal service")
	if got.Status != "healthy" || got.HTTPCode != "200" || got.Reason != "" {
		t.Fatalf("unexpected internal health: %+v", got)
	}
}

func TestProbeResultHTTP000HasActionableReason(t *testing.T) {
	got := probeResult("http://dev-backend.web/healthz", "000\tCould not resolve host", errors.New("exit status 6"), "internal service")
	if got.Status != "unavailable" || got.HTTPCode != "000" {
		t.Fatalf("unexpected unavailable probe: %+v", got)
	}
	if !strings.Contains(got.Reason, "Could not resolve host") {
		t.Fatalf("probe reason is not actionable: %q", got.Reason)
	}
	got = probeResult("http://dev-backend.web/healthz", "curl: (6) Could not resolve host\n000\tCould not resolve host", errors.New("exit status 6"), "internal service")
	if got.Status != "unavailable" || got.HTTPCode != "000" {
		t.Fatalf("prefixed curl output was not parsed: %+v", got)
	}
}

func TestExternalProbeHealthyRouting(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			t.Fatalf("path = %q, want /healthz", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	got := (New("docker", "dokku")).externalProbe(context.Background(), []string{server.URL}, "/healthz")
	if got.Status != "healthy" || got.HTTPCode != "200" {
		t.Fatalf("unexpected external probe: %+v", got)
	}
}

func TestExternalProbeUnavailableIncludesReason(t *testing.T) {
	got := (New("docker", "dokku")).externalProbe(context.Background(), []string{"http://127.0.0.1:1"}, "/")
	if got.Status != "unavailable" || got.HTTPCode != "000" {
		t.Fatalf("unexpected external probe: %+v", got)
	}
	if !strings.Contains(got.Reason, "external route unavailable") {
		t.Fatalf("external probe reason is not actionable: %q", got.Reason)
	}
}

func TestBuildIdentityMissingAndLocalImageAreNotVerified(t *testing.T) {
	missing := buildIdentity(map[string]string{}, "dokku/dev-backend:latest", "", "latest")
	if missing.Status != "missing" || !strings.Contains(missing.Reason, "channel") {
		t.Fatalf("unexpected missing identity: %+v", missing)
	}

	verified := buildIdentity(map[string]string{
		"APP_IMAGE_CHANNEL": "stable",
		"APP_IMAGE_VERSION": "v1.2.3",
		"APP_IMAGE_COMMIT":  "0123456789abcdef",
		"APP_IMAGE_REF":     "registry.example/api:v1.2.3",
		"APP_IMAGE_DIGEST":  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"APP_WORKFLOW_RUN":  "42",
		"APP_DEPLOYED_AT":   "2026-09-07T10:00:00Z",
	}, "registry.example/api:v1.2.3", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "v1.2.3")
	if verified.Status != "verified" || verified.ImageRef == "dokku/dev-backend:latest" {
		t.Fatalf("unexpected verified identity: %+v", verified)
	}
	mismatch := buildIdentity(map[string]string{
		"APP_IMAGE_CHANNEL": "stable", "APP_IMAGE_VERSION": "v1.2.3",
		"APP_IMAGE_COMMIT": "0123456789abcdef", "APP_IMAGE_REF": "registry.example/api:v1.2.3",
		"APP_IMAGE_DIGEST": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"APP_WORKFLOW_RUN": "42", "APP_DEPLOYED_AT": "2026-09-07T10:00:00Z",
	}, "registry.example/api:v1.2.3", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "v1.2.3")
	if mismatch.Status != "mismatch" {
		t.Fatalf("expected digest mismatch, got %+v", mismatch)
	}
}

func TestAppLivenessStates(t *testing.T) {
	if got := livenessForState("running"); got.Status != "healthy" {
		t.Fatalf("running liveness = %+v", got)
	}
	if got := livenessForState("stopped"); got.Status != "unhealthy" {
		t.Fatalf("stopped liveness = %+v", got)
	}
}
