package web

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/gorilla/sessions"
)

func waitForMasterMigrationState(t *testing.T, job *masterMigrationJob, want masterMigrationState) MasterMigrationStatus {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		status := job.Status()
		if status.State == want {
			return status
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("migration state = %q, want %q", job.Status().State, want)
	return MasterMigrationStatus{}
}

func TestMasterMigrationJobPreventsDuplicateRuns(t *testing.T) {
	release := make(chan struct{})
	job := newMasterMigrationJobWithRunner(func(context.Context) error {
		<-release
		return nil
	})

	if _, started := job.Start(); !started {
		t.Fatal("first migration start was rejected")
	}
	if status, started := job.Start(); started || status.State != masterMigrationRunning {
		t.Fatalf("duplicate migration start = (%+v, %v), want running and false", status, started)
	}

	close(release)
	waitForMasterMigrationState(t, job, masterMigrationSuccess)
}

type recordingMigrationRunner struct {
	script string
	argv   []string
}

func (r *recordingMigrationRunner) RunWithCallback(_ context.Context, _ io.Writer, script string, argv []string, _ func(string)) error {
	r.script = script
	r.argv = append([]string(nil), argv...)
	return nil
}

func TestMasterMigrationJobInvokesSafeOrchestrationScript(t *testing.T) {
	runner := &recordingMigrationRunner{}
	job := newMasterMigrationJobWithScriptRunner(runner)

	job.Start()
	waitForMasterMigrationState(t, job, masterMigrationSuccess)
	if runner.script != masterMigrationScript {
		t.Fatalf("migration script=%q, want %q", runner.script, masterMigrationScript)
	}
	if len(runner.argv) != 0 {
		t.Fatalf("migration argv=%v, want no user-controlled arguments", runner.argv)
	}
}

func TestMasterMigrationFailureIsActionableAndRedacted(t *testing.T) {
	secret := "super-secret-password"
	job := newMasterMigrationJobWithRunner(func(context.Context) error {
		return errors.New("goose failed: MYSQL_PASSWORD=" + secret + " migration ledger verification failed")
	})

	job.Start()
	status := waitForMasterMigrationState(t, job, masterMigrationFailure)
	if !strings.Contains(status.Message, "Resolve") {
		t.Fatalf("failure message is not actionable: %q", status.Message)
	}
	if strings.Contains(status.Error, secret) || strings.Contains(status.Error, "MYSQL_PASSWORD") {
		t.Fatalf("secret leaked in migration error: %q", status.Error)
	}
	if !strings.Contains(status.Error, "[redacted]") {
		t.Fatalf("redaction marker missing from migration error: %q", status.Error)
	}
}

func TestMasterMigrationEndpointsRequireAdmin(t *testing.T) {
	store := sessions.NewCookieStore([]byte("test-session-key-123456789012345678"))
	srv := &server{
		cfg:   configForMasterMigrationTest(),
		store: store,
	}
	next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})
	handler := srv.requireAdmin(next)

	unauthenticated := httptest.NewRequest(http.MethodGet, "/api/migrations/zatca-master", nil)
	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, unauthenticated)
	if unauthorized.Code != http.StatusForbidden {
		t.Fatalf("unauthenticated admin endpoint status=%d, want %d", unauthorized.Code, http.StatusForbidden)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/migrations/zatca-master", nil)
	session, err := store.Get(req, sessionName)
	if err != nil {
		t.Fatalf("get session: %v", err)
	}
	session.Values["user"] = "operator"
	sessionWriter := httptest.NewRecorder()
	if err := session.Save(req, sessionWriter); err != nil {
		t.Fatalf("save session: %v", err)
	}
	cookies := sessionWriter.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("saved session cookies=%d, want 1", len(cookies))
	}
	req.AddCookie(cookies[0])
	forbidden := httptest.NewRecorder()
	handler.ServeHTTP(forbidden, req)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("non-admin endpoint status=%d, want %d", forbidden.Code, http.StatusForbidden)
	}
}

func TestMasterMigrationRunEndpointReturnsRunningAndConflict(t *testing.T) {
	release := make(chan struct{})
	job := newMasterMigrationJobWithRunner(func(context.Context) error {
		<-release
		return nil
	})
	srv := &server{masterMigration: job}

	first := httptest.NewRecorder()
	srv.handleMasterMigrationRun(first, httptest.NewRequest(http.MethodPost, "/api/migrations/zatca-master/run", nil))
	if first.Code != http.StatusAccepted {
		t.Fatalf("first run status=%d, want %d", first.Code, http.StatusAccepted)
	}
	if !strings.Contains(first.Body.String(), `"state":"running"`) {
		t.Fatalf("first run did not return running state: %s", first.Body.String())
	}

	second := httptest.NewRecorder()
	srv.handleMasterMigrationRun(second, httptest.NewRequest(http.MethodPost, "/api/migrations/zatca-master/run", nil))
	if second.Code != http.StatusConflict {
		t.Fatalf("duplicate run status=%d, want %d", second.Code, http.StatusConflict)
	}

	close(release)
	waitForMasterMigrationState(t, job, masterMigrationSuccess)
}

func configForMasterMigrationTest() config.Config {
	return config.Config{AdminUser: "admin"}
}
