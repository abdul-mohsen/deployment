package web

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logging"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/go-chi/chi/v5"
)

var (
	deploymentFieldPattern     = regexp.MustCompile(`(^|[[:space:]])(severity|script|operation_id|tenant)=([^[:space:]]+)`)
	safeDeploymentFieldPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]+$`)
)

func activityKey(kind, name string) string {
	return "activity:" + kind + ":" + name
}

func (s *server) recordLog(key, line string) {
	logger := s.logger
	if logger == nil {
		logger = slog.Default()
	}
	if s.logs == nil {
		logger.Warn("activity log store unavailable", "activity_key", key)
		return
	}
	if err := s.logs.Append(key, line); err != nil {
		logger.Error("activity log persist failed", "activity_key", key, logging.ErrorAttr(err))
	}
}

func (s *server) recordActivity(key, line string) {
	s.recordLog(key, line)
}

func (s *server) recordActivities(keys []string, line string) {
	for _, key := range keys {
		s.recordActivity(key, line)
	}
	s.emitDeploymentEvent(line)
}

func (s *server) recordActivityBlock(key, output string) {
	output = strings.TrimRight(output, "\r\n")
	if output == "" {
		return
	}

	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSuffix(line, "\r")
		s.recordActivity(key, line)
		s.emitDeploymentEvent(line)
	}
}

// emitDeploymentEvent turns only the reviewed shell logfmt envelope into a
// searchable control-plane event. Arbitrary runner output stays in the
// bounded activity buffer and is never copied to structured logs.
func (s *server) emitDeploymentEvent(line string) {
	matches := deploymentFieldPattern.FindAllStringSubmatch(line, -1)
	if len(matches) == 0 {
		return
	}
	fields := make(map[string]string, len(matches))
	for _, match := range matches {
		fields[match[2]] = match[3]
	}
	script := safeDeploymentField(fields["script"])
	operationID := safeDeploymentField(fields["operation_id"])
	if script == "" || operationID == "" {
		return
	}
	tenant := fields["tenant"]
	if tenant != "" && !validAppName(tenant) {
		tenant = ""
	}
	severity := strings.ToLower(strings.TrimSpace(fields["severity"]))
	level := slog.LevelInfo
	outcome := "success"
	if severity == "error" || severity == "fatal" {
		level = slog.LevelError
		outcome = "failure"
	} else if severity == "warn" || severity == "warning" {
		level = slog.LevelWarn
	}
	logger := s.logger
	if logger == nil {
		logger = slog.Default()
	}
	attrs := []slog.Attr{
		slog.String("event_type", "deployment.operation"),
		slog.String("component", "deployment"),
		slog.String("service_name", "ifritah-dashboard"),
		slog.String("operation", script),
		slog.String("operation_id", operationID),
		slog.String("deployment_stage", deploymentStage(script)),
		slog.String("outcome", outcome),
	}
	if tenant != "" {
		attrs = append(attrs, slog.String("tenant_id", tenant))
	}
	logger.LogAttrs(context.Background(), level, "deployment.operation", attrs...)
}

func safeDeploymentField(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 128 {
		return ""
	}
	if !safeDeploymentFieldPattern.MatchString(value) {
		return ""
	}
	return value
}

func deploymentStage(script string) string {
	script = strings.TrimSuffix(strings.ToLower(script), ".sh")
	switch {
	case strings.Contains(script, "backup"):
		return "backup"
	case strings.Contains(script, "rollback"):
		return "rollback"
	case strings.Contains(script, "migrat"), strings.Contains(script, "init-tenant-db"):
		return "migration"
	case strings.Contains(script, "update"), strings.Contains(script, "deploy"), strings.Contains(script, "restart"):
		return "image_swap"
	default:
		return script
	}
}

func scriptActivityKeys(sc *scripts.Script, form url.Values) []string {
	keys := []string{activityKey("script", sc.Slug())}
	tenant := strings.TrimSpace(form.Get("_pos_name"))
	if tenant == "" {
		tenant = strings.TrimSpace(form.Get("tenant"))
	}
	if validAppName(tenant) {
		keys = append(keys, activityKey("tenant", tenant))
	}
	return keys
}

func (s *server) writeActivity(w http.ResponseWriter, key string) {
	entries := make([]logbuf.Entry, 0)
	if s.logs != nil {
		entries = s.logs.Snapshot(key)
		if entries == nil {
			entries = make([]logbuf.Entry, 0)
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{"entries": entries})
}

func (s *server) handleTenantActivity(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	s.writeActivity(w, activityKey("tenant", name))
}

func (s *server) handleAppActivity(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if !validAppName(name) {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	s.writeActivity(w, activityKey("app", name))
}

func (s *server) handleScriptActivity(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	sc := scripts.Find(name)
	if sc == nil {
		http.NotFound(w, r)
		return
	}
	s.writeActivity(w, activityKey("script", sc.Slug()))
}
