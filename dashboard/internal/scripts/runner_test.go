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

func TestRunnerAddsDockerHostGateway(t *testing.T) {
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")
	args := r.dockerArgs("/var/run/docker.sock:/var/run/docker.sock")
	if !slices.Contains(args, "--add-host") ||
		!slices.Contains(args, "host.docker.internal:host-gateway") {
		t.Fatalf("runner args missing host-gateway mapping: %v", args)
	}
}
