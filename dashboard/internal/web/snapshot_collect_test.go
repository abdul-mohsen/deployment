package web

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

func TestCollectAppDetailsUsesBoundedParallelWorkers(t *testing.T) {
	appNames := []string{"a-backend", "a-frontend", "b-backend", "b-frontend", "c-backend", "c-frontend"}
	var active int32
	var maxActive int32

	apps := collectAppDetails(context.Background(), appNames, 3, func(_ context.Context, appName string) dokku.App {
		current := atomic.AddInt32(&active, 1)
		for {
			previous := atomic.LoadInt32(&maxActive)
			if current <= previous || atomic.CompareAndSwapInt32(&maxActive, previous, current) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
		atomic.AddInt32(&active, -1)
		return dokku.App{Name: appName}
	})

	if len(apps) != len(appNames) {
		t.Fatalf("collected %d apps, want %d", len(apps), len(appNames))
	}
	if maxActive < 2 {
		t.Fatalf("collector ran serially; max active workers = %d", maxActive)
	}
	if maxActive > 3 {
		t.Fatalf("collector exceeded worker limit; max active workers = %d", maxActive)
	}
}

func TestSnapshotWorkerLimit(t *testing.T) {
	t.Setenv("DASHBOARD_SNAPSHOT_WORKERS", "3")
	if got := snapshotWorkerLimit(20); got != 3 {
		t.Fatalf("snapshotWorkerLimit(20) = %d, want 3", got)
	}
	if got := snapshotWorkerLimit(2); got != 2 {
		t.Fatalf("snapshotWorkerLimit(2) = %d, want 2", got)
	}
}
