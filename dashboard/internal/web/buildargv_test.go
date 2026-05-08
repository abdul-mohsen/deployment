package web

import (
	"net/url"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

func TestBuildArgv_CreateTenant_FullFlow(t *testing.T) {
	sc := scripts.Find("create-tenant.sh")
	if sc == nil {
		t.Fatal("create-tenant.sh not in catalog")
	}
	form := url.Values{
		"_pos_name":        {"acme"},
		"admin_user":       {"admin"},
		"admin_password":   {"S3cret!"},
		"manager_user":     {"manager"},
		"manager_password": {"M4nager!"},
		"company_name":     {"ACME"},
		// backend_port / frontend_port omitted on purpose: defaults must kick in via Default
	}
	argv, err := buildArgv(sc, form)
	if err != nil {
		t.Fatalf("buildArgv: %v", err)
	}
	joined := strings.Join(argv, " ")
	for _, want := range []string{
		"acme",
		"--env ADMIN_USER=admin",
		"--env ADMIN_PASSWORD=S3cret!",
		"--env MANAGER_USER=manager",
		"--env MANAGER_PASSWORD=M4nager!",
		"--env COMPANY_NAME=ACME",
		"--backend-port 8090",
		"--frontend-port 8000",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv missing %q\nfull: %s", want, joined)
		}
	}
}

func TestBuildArgv_CreateTenant_ManagerUserRequiresPassword(t *testing.T) {
	sc := scripts.Find("create-tenant.sh")
	form := url.Values{
		"_pos_name":      {"acme"},
		"admin_user":     {"admin"},
		"admin_password": {"x"},
		"manager_user":   {"manager"}, // no password -> should fail
		"company_name":   {"ACME"},
	}
	if _, err := buildArgv(sc, form); err == nil {
		t.Fatal("expected error when manager_user is set without manager_password")
	}
}

func TestBuildArgv_CreateTenant_ManagerOptional(t *testing.T) {
	sc := scripts.Find("create-tenant.sh")
	form := url.Values{
		"_pos_name":      {"acme"},
		"admin_user":     {"admin"},
		"admin_password": {"x"},
		"company_name":   {"ACME"},
	}
	argv, err := buildArgv(sc, form)
	if err != nil {
		t.Fatalf("buildArgv: %v", err)
	}
	joined := strings.Join(argv, " ")
	if strings.Contains(joined, "MANAGER_") {
		t.Errorf("manager fields leaked into argv: %s", joined)
	}
}

func TestDisplayArgv_MasksSecrets(t *testing.T) {
	sc := scripts.Find("create-tenant.sh")
	argv := []string{
		"acme",
		"--env", "ADMIN_USER=admin",
		"--env", "ADMIN_PASSWORD=topsecret",
		"--env", "MANAGER_PASSWORD=hunter2",
		"--env", "COMPANY_NAME=ACME",
		"--backend-port", "8090",
	}
	out := displayArgv(sc, argv)
	joined := strings.Join(out, " ")
	if strings.Contains(joined, "topsecret") || strings.Contains(joined, "hunter2") {
		t.Fatalf("secret leaked: %s", joined)
	}
	if !strings.Contains(joined, "ADMIN_PASSWORD=***") || !strings.Contains(joined, "MANAGER_PASSWORD=***") {
		t.Fatalf("expected masked password values: %s", joined)
	}
	if !strings.Contains(joined, "ADMIN_USER=admin") || !strings.Contains(joined, "COMPANY_NAME=ACME") {
		t.Fatalf("non-secret env values were unexpectedly altered: %s", joined)
	}
}
