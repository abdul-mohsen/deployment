package web

import (
	"bufio"
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

const defaultMigrationStatusInterval = 5 * time.Minute

type MigrationStatus struct {
	Tenant            string    `json:"tenant"`
	Image             string    `json:"image"`
	SchemaStatus      string    `json:"schema_status"`
	PendingMigrations []string  `json:"pending_migrations"`
	FailedMigrations  []string  `json:"failed_migrations"`
	Error             string    `json:"error,omitempty"`
	CheckedAt         time.Time `json:"checked_at"`
}

type migrationMonitor struct {
	runner   *scripts.Runner
	interval time.Duration

	mu        sync.RWMutex
	statuses  map[string]MigrationStatus
	lastError string
	trigger   chan struct{}
	runMu     sync.Mutex
}

func newMigrationMonitor(runner *scripts.Runner) *migrationMonitor {
	return &migrationMonitor{
		runner:   runner,
		interval: migrationStatusInterval(),
		statuses: make(map[string]MigrationStatus),
		trigger:  make(chan struct{}, 1),
	}
}

func migrationStatusInterval() time.Duration {
	raw := strings.TrimSpace(getenv("MIGRATION_STATUS_INTERVAL"))
	if raw == "" {
		return defaultMigrationStatusInterval
	}
	interval, err := time.ParseDuration(raw)
	if err != nil || interval < 30*time.Second {
		return defaultMigrationStatusInterval
	}
	return interval
}

func (m *migrationMonitor) Start(ctx context.Context) {
	go func() {
		m.runAll(ctx)
		ticker := time.NewTicker(m.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				m.runAll(ctx)
			case <-m.trigger:
				m.runAll(ctx)
			case <-ctx.Done():
				return
			}
		}
	}()
}

func (m *migrationMonitor) RefreshSoon() {
	select {
	case m.trigger <- struct{}{}:
	default:
	}
}

func (m *migrationMonitor) Status(tenant string) (MigrationStatus, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	status, ok := m.statuses[tenant]
	status.PendingMigrations = append([]string(nil), status.PendingMigrations...)
	status.FailedMigrations = append([]string(nil), status.FailedMigrations...)
	return status, ok
}

func (m *migrationMonitor) runAll(ctx context.Context) {
	m.runMu.Lock()
	defer m.runMu.Unlock()

	runCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	output, err := m.runner.RunCapture(runCtx, "migration-status.sh", []string{"--json"})
	records := parseMigrationJSON(output)
	now := time.Now()
	statuses := make(map[string]MigrationStatus, len(records))
	for _, status := range records {
		status.CheckedAt = now
		statuses[status.Tenant] = status
	}

	m.mu.Lock()
	m.statuses = statuses
	m.lastError = ""
	if err != nil && len(records) == 0 {
		m.lastError = err.Error()
	}
	m.mu.Unlock()
}

func (m *migrationMonitor) CheckTenant(ctx context.Context, tenant, image string) MigrationStatus {
	m.runMu.Lock()
	defer m.runMu.Unlock()

	args := []string{tenant, "--status"}
	if strings.TrimSpace(image) != "" {
		args = append(args, "--backend-image", image)
	}
	runCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	output, err := m.runner.RunCapture(runCtx, "init-tenant-db.sh", args)
	status := parseMigrationText(output)
	status.Tenant = tenant
	if status.Image == "" {
		status.Image = image
	}
	status.CheckedAt = time.Now()
	if status.SchemaStatus == "" {
		status.SchemaStatus = "unknown"
	}
	if err != nil && status.Error == "" {
		status.Error = err.Error()
	}
	m.mu.Lock()
	m.statuses[tenant] = status
	m.lastError = ""
	m.mu.Unlock()
	return status
}

func parseMigrationJSON(output string) []MigrationStatus {
	var statuses []MigrationStatus
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		var status MigrationStatus
		if json.Unmarshal([]byte(scanner.Text()), &status) == nil && status.Tenant != "" {
			statuses = append(statuses, status)
		}
	}
	return statuses
}

func parseMigrationText(output string) MigrationStatus {
	var status MigrationStatus
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		switch {
		case strings.HasPrefix(line, "tenant="):
			status.Tenant = strings.TrimPrefix(line, "tenant=")
		case strings.HasPrefix(line, "image="):
			status.Image = strings.TrimPrefix(line, "image=")
		case strings.HasPrefix(line, "schema_status="):
			status.SchemaStatus = strings.TrimPrefix(line, "schema_status=")
		case strings.HasPrefix(line, "pending_migration="):
			status.PendingMigrations = append(status.PendingMigrations,
				strings.TrimPrefix(line, "pending_migration="))
		case strings.HasPrefix(line, "failed_migration="):
			value := strings.TrimPrefix(line, "failed_migration=")
			if space := strings.IndexByte(value, ' '); space >= 0 {
				value = value[:space]
			}
			status.FailedMigrations = append(status.FailedMigrations, value)
		case strings.HasPrefix(line, "[x] "):
			status.Error = strings.TrimPrefix(line, "[x] ")
		}
	}
	return status
}
