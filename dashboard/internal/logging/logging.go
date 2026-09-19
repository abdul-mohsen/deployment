// Package logging provides the dashboard's small structured logging contract.
package logging

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"reflect"
	"strings"

	"github.com/abdul-mohsen/deployment/dashboard/internal/buildinfo"
)

const (
	DefaultLevel  = "info"
	DefaultFormat = "json"
)

// Options configures a dashboard logger.
type Options struct {
	Level       string
	Format      string
	Service     string
	Environment string
	Build       buildinfo.Info
	Writer      io.Writer
}

// New creates a logger with stable, non-secret service and build fields.
//
// JSON is the default because dashboard logs are intended for Docker's log
// driver and an optional collector. Text remains available for local
// development and operator troubleshooting.
func New(options Options) *slog.Logger {
	writer := options.Writer
	if writer == nil {
		writer = os.Stderr
	}

	level := parseLevel(options.Level)
	handlerOptions := &slog.HandlerOptions{
		Level:       level,
		ReplaceAttr: replaceAttr,
	}

	var handler slog.Handler
	if strings.EqualFold(strings.TrimSpace(options.Format), "text") {
		handler = slog.NewTextHandler(writer, handlerOptions)
	} else {
		handler = slog.NewJSONHandler(writer, handlerOptions)
	}

	attrs := []any{
		"service", safeIdentifier(options.Service, "dokku-dashboard"),
		"environment", safeIdentifier(options.Environment, "unknown"),
		"build_version", safeIdentifier(options.Build.Version, "unknown"),
		"build_commit", safeIdentifier(options.Build.Commit, "unknown"),
	}
	if revision := safeIdentifier(options.Build.ScriptsRevision, ""); revision != "" {
		attrs = append(attrs, "scripts_revision", revision)
	}
	return slog.New(handler).With(attrs...)
}

// ParseLevel validates a configured slog level.
func ParseLevel(value string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", DefaultLevel:
		return slog.LevelInfo, nil
	case "debug":
		return slog.LevelDebug, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return slog.LevelInfo, &invalidLevelError{value: value}
	}
}

// ErrorAttr returns a bounded error attribute without serializing the error
// message, which may contain credentials, request data, or tenant output.
func ErrorAttr(err error) slog.Attr {
	return slog.String("error_type", ErrorType(err))
}

// ErrorCodeAttr returns a bounded, stable code for an operational failure.
func ErrorCodeAttr(code string) slog.Attr {
	return slog.String("error_code", safeIdentifier(code, "unknown"))
}

// ErrorType returns a stable concrete error type or a bounded context
// cancellation category. Error messages are intentionally never returned.
func ErrorType(err error) string {
	if err == nil {
		return "none"
	}
	if errors.Is(err, context.Canceled) {
		return "context_canceled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "context_deadline_exceeded"
	}
	if typ := reflect.TypeOf(err); typ != nil {
		return typ.String()
	}
	return "unknown"
}

type invalidLevelError struct {
	value string
}

func (e *invalidLevelError) Error() string {
	return "unsupported log level: " + e.value
}

func parseLevel(value string) slog.Level {
	level, err := ParseLevel(value)
	if err != nil {
		return slog.LevelInfo
	}
	return level
}

func safeIdentifier(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 128 {
		return fallback
	}
	for _, r := range value {
		if (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			strings.ContainsRune("._-", r) {
			continue
		}
		return fallback
	}
	return value
}

func replaceAttr(_ []string, attr slog.Attr) slog.Attr {
	if sensitiveKey(attr.Key) {
		return slog.String(attr.Key, "[REDACTED]")
	}
	return attr
}

func sensitiveKey(key string) bool {
	key = strings.ToLower(strings.TrimSpace(key))
	key = strings.NewReplacer("-", "_", ".", "_").Replace(key)
	for _, part := range []string{
		"authorization",
		"cookie",
		"credential",
		"password",
		"secret",
		"session",
		"token",
	} {
		if strings.Contains(key, part) {
			return true
		}
	}
	return false
}
