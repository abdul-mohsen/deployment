package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

const (
	masterMigrationScript  = "migrate-zatca-master.sh"
	masterMigrationTimeout = 30 * time.Minute
)

var migrationSecretAssignment = regexp.MustCompile(`(?i)(?:MYSQL_PASSWORD|MYSQL_ROOT_PASSWORD|MYSQL_ADMIN_PASSWORD|MIGRATION_DB_PASSWORD|ZATCA_ENCRYPT_KEY|ZATCA_MONITOR_PASSWORD|DB_PASS|PASSWORD|MYSQL_PWD|Authorization)\s*=\s*[^\s]+`)

type masterMigrationState string

const (
	masterMigrationReady   masterMigrationState = "ready"
	masterMigrationRunning masterMigrationState = "running"
	masterMigrationSuccess masterMigrationState = "success"
	masterMigrationFailure masterMigrationState = "failure"
)

type MasterMigrationStatus struct {
	State      masterMigrationState `json:"state"`
	Message    string               `json:"message"`
	Error      string               `json:"error,omitempty"`
	StartedAt  time.Time            `json:"started_at,omitempty"`
	FinishedAt time.Time            `json:"finished_at,omitempty"`
}

func (s MasterMigrationStatus) clone() MasterMigrationStatus {
	return s
}

type masterMigrationJob struct {
	mu     sync.RWMutex
	status MasterMigrationStatus
	run    func(context.Context) error
}

type migrationScriptRunner interface {
	RunWithCallback(context.Context, io.Writer, string, []string, func(string)) error
}

func newMasterMigrationJob(runner *scripts.Runner) *masterMigrationJob {
	return newMasterMigrationJobWithScriptRunner(runner)
}

func newMasterMigrationJobWithScriptRunner(runner migrationScriptRunner) *masterMigrationJob {
	run := func(ctx context.Context) error {
		if runner == nil {
			return fmt.Errorf("script runner is not configured")
		}
		return runner.RunWithCallback(ctx, io.Discard, masterMigrationScript, nil, nil)
	}
	return newMasterMigrationJobWithRunner(run)
}

func newMasterMigrationJobWithRunner(run func(context.Context) error) *masterMigrationJob {
	return &masterMigrationJob{
		status: MasterMigrationStatus{
			State:   masterMigrationReady,
			Message: "Ready to run the ZATCA master migration.",
		},
		run: run,
	}
}

func (j *masterMigrationJob) Status() MasterMigrationStatus {
	if j == nil {
		return MasterMigrationStatus{
			State:   masterMigrationFailure,
			Message: "ZATCA master migration is unavailable.",
			Error:   "migration job is not configured",
		}
	}
	j.mu.RLock()
	defer j.mu.RUnlock()
	return j.status.clone()
}

func (j *masterMigrationJob) Start() (MasterMigrationStatus, bool) {
	if j == nil {
		return MasterMigrationStatus{
			State:   masterMigrationFailure,
			Message: "ZATCA master migration is unavailable.",
			Error:   "migration job is not configured",
		}, false
	}

	j.mu.Lock()
	if j.status.State == masterMigrationRunning {
		status := j.status.clone()
		j.mu.Unlock()
		return status, false
	}
	now := time.Now().UTC()
	j.status = MasterMigrationStatus{
		State:     masterMigrationRunning,
		Message:   "ZATCA master migration is running. Do not start another migration.",
		StartedAt: now,
	}
	status := j.status.clone()
	run := j.run
	j.mu.Unlock()

	go j.execute(run)
	return status, true
}

func (j *masterMigrationJob) execute(run func(context.Context) error) {
	ctx, cancel := context.WithTimeout(context.Background(), masterMigrationTimeout)
	defer cancel()

	var err error
	if run == nil {
		err = fmt.Errorf("migration job is not configured")
	} else {
		err = run(ctx)
	}

	now := time.Now().UTC()
	j.mu.Lock()
	defer j.mu.Unlock()
	j.status.FinishedAt = now
	if err != nil {
		j.status.State = masterMigrationFailure
		j.status.Message = "ZATCA master migration failed. Resolve the reported error before retrying."
		j.status.Error = safeMigrationError(err)
		return
	}
	j.status.State = masterMigrationSuccess
	j.status.Message = "ZATCA master migration completed successfully."
	j.status.Error = ""
}

func safeMigrationError(err error) string {
	if err == nil {
		return ""
	}
	message := strings.TrimSpace(err.Error())
	if message == "" {
		return "migration job returned an unknown error"
	}
	message = migrationSecretAssignment.ReplaceAllString(message, "[redacted]")
	if len(message) > 500 {
		message = message[:500] + "..."
	}
	return message
}

func writeMasterMigrationStatus(w io.Writer, status MasterMigrationStatus) error {
	return json.NewEncoder(w).Encode(status)
}
