package web

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/url"
	"strings"

	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logging"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
	"github.com/go-chi/chi/v5"
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
}

func (s *server) recordActivityBlock(key, output string) {
	output = strings.TrimRight(output, "\r\n")
	if output == "" {
		return
	}
	for _, line := range strings.Split(output, "\n") {
		s.recordActivity(key, strings.TrimSuffix(line, "\r"))
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
