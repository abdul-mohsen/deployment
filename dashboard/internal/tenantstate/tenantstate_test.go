package tenantstate_test

import (
	"os"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/tenantstate"
)

func TestDefaultAutoRedeploy(t *testing.T) {
	dir := t.TempDir()
	store := tenantstate.NewStore(dir)

	// A tenant with no state file should default to auto-redeploy enabled.
	if !store.IsAutoRedeployEnabled("new-tenant") {
		t.Error("expected auto-redeploy enabled by default, got disabled")
	}
}

func TestSetAndLoadAutoRedeploy(t *testing.T) {
	dir := t.TempDir()
	store := tenantstate.NewStore(dir)

	// Disable
	if err := store.SetAutoRedeploy("acme", false); err != nil {
		t.Fatalf("SetAutoRedeploy: %v", err)
	}
	if store.IsAutoRedeployEnabled("acme") {
		t.Error("expected auto-redeploy disabled after SetAutoRedeploy(false)")
	}

	// Re-enable
	if err := store.SetAutoRedeploy("acme", true); err != nil {
		t.Fatalf("SetAutoRedeploy: %v", err)
	}
	if !store.IsAutoRedeployEnabled("acme") {
		t.Error("expected auto-redeploy enabled after SetAutoRedeploy(true)")
	}
}

func TestBackupLabel(t *testing.T) {
	dir := t.TempDir()
	store := tenantstate.NewStore(dir)

	const label = "pre-release backup"
	if err := store.SetBackupLabel("demo", label); err != nil {
		t.Fatalf("SetBackupLabel: %v", err)
	}

	got, err := store.ConsumeBackupLabel("demo")
	if err != nil {
		t.Fatalf("ConsumeBackupLabel: %v", err)
	}
	if got != label {
		t.Errorf("got label %q, want %q", got, label)
	}

	// Second consume should return empty (label was cleared)
	got2, err := store.ConsumeBackupLabel("demo")
	if err != nil {
		t.Fatalf("second ConsumeBackupLabel: %v", err)
	}
	if got2 != "" {
		t.Errorf("expected empty label after consume, got %q", got2)
	}
}

func TestMissingDirIsCreated(t *testing.T) {
	dir := t.TempDir()
	sub := dir + "/nested/state"
	store := tenantstate.NewStore(sub)

	if err := store.SetAutoRedeploy("x", false); err != nil {
		t.Fatalf("SetAutoRedeploy with nested dir: %v", err)
	}
	if _, err := os.Stat(sub); err != nil {
		t.Errorf("expected nested dir to be created: %v", err)
	}
}

func TestAutoRedeployPreservesLabel(t *testing.T) {
	dir := t.TempDir()
	store := tenantstate.NewStore(dir)

	_ = store.SetBackupLabel("x", "my-label")
	_ = store.SetAutoRedeploy("x", false)

	// Label should survive the AutoRedeploy update
	got, _ := store.ConsumeBackupLabel("x")
	if got != "my-label" {
		t.Errorf("label lost after SetAutoRedeploy: got %q", got)
	}
}
