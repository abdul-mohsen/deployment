package scripts

import (
	"slices"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/buildinfo"
)

func TestDockerArgsMountPersistentStorage(t *testing.T) {
	t.Setenv("DEPLOYMENT_SCRIPTS_REVISION", "0123456789abcdef")
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")
	r.SetBackupDir("/opt/tenant-backups")
	r.SetStorageRoot("/opt/tenant-data")

	args := r.dockerArgs("/var/run/docker.sock:/var/run/docker.sock")
	if !slices.Contains(args, "-e") ||
		!slices.Contains(args, "STORAGE_ROOT=/opt/tenant-data") {
		t.Fatalf("runner args do not pass STORAGE_ROOT: %v", args)
	}
	if !slices.Contains(args, "/opt/tenant-data:/opt/tenant-data") {
		t.Fatalf("runner args do not mount persistent storage: %v", args)
	}
	if !slices.Contains(args, "DEPLOYMENT_SCRIPTS_REVISION=0123456789abcdef") {
		t.Fatalf("runner args do not pass deployment script revision: %v", args)
	}
}

func TestDockerArgsOmitPersistentStorageWhenUnset(t *testing.T) {
	r := NewRunner("docker", "runner:latest", "/opt/deployment", "")

	args := r.dockerArgs("/var/run/docker.sock:/var/run/docker.sock")
	if slices.Contains(args, "STORAGE_ROOT=/opt/tenant-data") {
		t.Fatalf("unset storage root unexpectedly added to args: %v", args)
	}
}

func TestValidateRuntimeRevisionAllowsNonProduction(t *testing.T) {
	t.Setenv("DASHBOARD_ENV", "dev")
	t.Setenv("DEPLOYMENT_SCRIPTS_REVISION", "")
	t.Setenv("APP_IMAGE_COMMIT", "")
	t.Setenv("APP_COMMIT", "")
	oldCommit := buildinfo.Commit
	t.Cleanup(func() { buildinfo.Commit = oldCommit })
	buildinfo.Commit = "unknown"

	if err := validateRuntimeRevision(); err != nil {
		t.Fatalf("validateRuntimeRevision() = %v in dev, want nil", err)
	}
}

func TestValidateRuntimeRevisionRequiresMatchingProductionIdentity(t *testing.T) {
	oldCommit := buildinfo.Commit
	t.Cleanup(func() { buildinfo.Commit = oldCommit })
	t.Setenv("DASHBOARD_ENV", "prod")
	t.Setenv("DEPLOYMENT_SCRIPTS_REVISION", "0123456789abcdef")
	t.Setenv("APP_IMAGE_COMMIT", "")
	t.Setenv("APP_COMMIT", "")
	buildinfo.Commit = "0123456789abcdef"

	if err := validateRuntimeRevision(); err != nil {
		t.Fatalf("validateRuntimeRevision() = %v, want nil", err)
	}

	t.Setenv("DEPLOYMENT_SCRIPTS_REVISION", "fedcba9876543210")
	if err := validateRuntimeRevision(); err == nil {
		t.Fatal("validateRuntimeRevision() = nil for mismatched revisions")
	}

	t.Setenv("DEPLOYMENT_SCRIPTS_REVISION", "")
	if err := validateRuntimeRevision(); err == nil {
		t.Fatal("validateRuntimeRevision() = nil without script revision")
	}

}
