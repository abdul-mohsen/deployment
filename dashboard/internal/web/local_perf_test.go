package web

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

func TestLocalDokkuSnapshotTenTenants(t *testing.T) {
	if os.Getenv("DASHBOARD_LOCAL_DOKKU_PERF") != "1" {
		t.Skip("set DASHBOARD_LOCAL_DOKKU_PERF=1 to run against local Docker/Dokku")
	}

	client := dokku.New("docker", "dokku")
	dashboard := &server{dokku: client}

	started := time.Now()
	snapshot := dashboard.collectSnapshot(context.Background())
	duration := time.Since(started)

	tenants := map[string]bool{}
	for _, app := range snapshot.Apps {
		if strings.HasSuffix(app.Name, "-backend") || strings.HasSuffix(app.Name, "-frontend") {
			tenants[app.Tenant] = true
		}
	}

	t.Logf("apps=%d tenants=%d healthy=%t duration=%s", len(snapshot.Apps), len(tenants), snapshot.Healthy, duration)
	if len(tenants) < 10 {
		t.Fatalf("local Dokku reproduction has %d tenants, want at least 10", len(tenants))
	}
}
