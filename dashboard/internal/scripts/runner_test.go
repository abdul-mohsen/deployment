package scripts

import (
	"slices"
	"testing"
)

func TestRunnerMountsPersistentTenantDirectories(t *testing.T) {
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")
	r.SetBackupDir("/opt/tenant-backups")
	r.SetStorageRoot("/opt/tenant-data")

	args := r.volumeArgs()
	for _, want := range []string{
		"-v", "/opt/tenant-backups:/opt/tenant-backups",
		"-e", "BACKUP_DIR=/opt/tenant-backups",
		"-v", "/opt/tenant-data:/opt/tenant-data",
		"-e", "STORAGE_ROOT=/opt/tenant-data",
	} {
		if !slices.Contains(args, want) {
			t.Errorf("runner volume args missing %q: %v", want, args)
		}
	}
}

func TestRunnerMountsExternalZatcaArtifactReadOnly(t *testing.T) {
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")
	r.SetMigrationArtifact("/home/ssda/zatca_integration/migrations/zatca_master")

	args := r.volumeArgs()
	if !slices.Contains(args, "/home/ssda/zatca_integration/migrations/zatca_master:/home/ssda/zatca_integration/migrations/zatca_master:ro") {
		t.Fatalf("runner volume args missing read-only ZATCA artifact mount: %v", args)
	}
}

func TestRunnerDoesNotDuplicateArtifactInsideDeploymentMount(t *testing.T) {
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")
	r.SetMigrationArtifact("/opt/deployment/zatca/migrations/zatca_master")

	args := r.volumeArgs()
	if slices.Contains(args, "/opt/deployment/zatca/migrations/zatca_master:/opt/deployment/zatca/migrations/zatca_master:ro") {
		t.Fatalf("runner duplicated an artifact mount already covered by deployment mount: %v", args)
	}
}
