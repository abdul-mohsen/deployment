package logging

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/buildinfo"
)

func TestNewJSONLoggerIncludesSafeServiceAndBuildFields(t *testing.T) {
	var output bytes.Buffer
	logger := New(Options{
		Level:       "debug",
		Format:      "json",
		Service:     "dokku-dashboard",
		Environment: "prod",
		Build: buildinfo.Info{
			Version:         "v1.2.3",
			Commit:          "0123456",
			ScriptsRevision: "fedcba9",
		},
		Writer: &output,
	})

	logger.Debug("test event", "operation", "check")

	var record map[string]any
	if err := json.Unmarshal(output.Bytes(), &record); err != nil {
		t.Fatalf("logger output is not JSON: %v\n%s", err, output.String())
	}
	for key, want := range map[string]string{
		"service":          "dokku-dashboard",
		"environment":      "prod",
		"build_version":    "v1.2.3",
		"build_commit":     "0123456",
		"scripts_revision": "fedcba9",
	} {
		if got := record[key]; got != want {
			t.Fatalf("%s = %v, want %q", key, got, want)
		}
	}
	if record["level"] != "DEBUG" || record["msg"] != "test event" {
		t.Fatalf("record = %v", record)
	}
}

func TestLoggerRedactsSensitiveAttributes(t *testing.T) {
	var output bytes.Buffer
	logger := New(Options{Format: "json", Writer: &output})

	logger.Info("request", "authorization", "Bearer top-secret", "cookie", "session=top-secret", "password", "top-secret")

	text := output.String()
	for _, secret := range []string{"top-secret", "Bearer"} {
		if strings.Contains(text, secret) {
			t.Fatalf("sensitive value %q leaked in %s", secret, text)
		}
	}
	if got := strings.Count(text, "[REDACTED]"); got != 3 {
		t.Fatalf("redacted values = %d, want 3 in %s", got, text)
	}
}

func TestErrorAttrDoesNotEmitSensitiveErrorText(t *testing.T) {
	var output bytes.Buffer
	logger := New(Options{Format: "json", Writer: &output})
	err := errors.New("database password=top-secret")

	logger.Error("operation failed", ErrorCodeAttr("dashboard_config_invalid"), ErrorAttr(err))

	text := output.String()
	if strings.Contains(text, "database password=top-secret") || strings.Contains(text, "top-secret") {
		t.Fatalf("error text leaked in %s", text)
	}
	if !strings.Contains(text, `"error_type":"*errors.errorString"`) {
		t.Fatalf("stable error type missing in %s", text)
	}
	if strings.Contains(text, `"error":`) {
		t.Fatalf("raw error attribute emitted in %s", text)
	}
	if !strings.Contains(text, `"error_code":"dashboard_config_invalid"`) {
		t.Fatalf("stable error code missing in %s", text)
	}
}

func TestErrorTypeClassifiesContextFailures(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "canceled", err: fmt.Errorf("request secret: %w", context.Canceled), want: "context_canceled"},
		{name: "deadline", err: fmt.Errorf("request secret: %w", context.DeadlineExceeded), want: "context_deadline_exceeded"},
		{name: "nil", err: nil, want: "none"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := ErrorType(test.err); got != test.want {
				t.Fatalf("ErrorType(%v) = %q, want %q", test.err, got, test.want)
			}
		})
	}
}

func TestParseLevel(t *testing.T) {
	tests := []struct {
		input string
		want  slog.Level
		ok    bool
	}{
		{input: "", want: slog.LevelInfo, ok: true},
		{input: "debug", want: slog.LevelDebug, ok: true},
		{input: "warning", want: slog.LevelWarn, ok: true},
		{input: "error", want: slog.LevelError, ok: true},
		{input: "nope", want: slog.LevelInfo, ok: false},
	}
	for _, test := range tests {
		t.Run(test.input, func(t *testing.T) {
			got, err := ParseLevel(test.input)
			if (err == nil) != test.ok || got != test.want {
				t.Fatalf("ParseLevel(%q) = %v, %v; want %v, ok=%t", test.input, got, err, test.want, test.ok)
			}
		})
	}
}

func TestNewTextLoggerIsConfigurable(t *testing.T) {
	var output bytes.Buffer
	logger := New(Options{Level: "info", Format: "text", Writer: &output})
	logger.Debug("hidden")
	logger.Info("visible")

	if strings.Contains(output.String(), "hidden") || !strings.Contains(output.String(), "visible") {
		t.Fatalf("unexpected text logger output: %s", output.String())
	}
	if strings.HasPrefix(strings.TrimSpace(output.String()), "{") {
		t.Fatalf("text logger emitted JSON: %s", output.String())
	}
}
