package web

import (
	"html/template"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/config"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

func setVersionTestEnv(t *testing.T) {
	t.Helper()
	t.Setenv("BACKEND_IMAGE", "ssdawweq/ifritah-api")
	t.Setenv("FRONTEND_IMAGE", "ssdawweq/ifritah-web")
	t.Setenv("APP_IMAGE_VERSIONS", "dev,2026.05.17")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "dev")
}

func TestBuildArgv_CreateTenant_FullFlow(t *testing.T) {
	setVersionTestEnv(t)
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
		"--backend-image ssdawweq/ifritah-api:dev",
		"--frontend-image ssdawweq/ifritah-web:dev",
		"--backend-port 8090",
		"--frontend-port 8000",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv missing %q\nfull: %s", want, joined)
		}
	}
}

func TestBuildArgv_CreateTenant_ManagerUserRequiresPassword(t *testing.T) {
	setVersionTestEnv(t)
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
	setVersionTestEnv(t)
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
	setVersionTestEnv(t)
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

func TestBuildArgv_UpdateTenant_VersionExpandsPair(t *testing.T) {
	setVersionTestEnv(t)
	sc := scripts.Find("update-tenant.sh")
	form := url.Values{
		"_pos_name":     {"fresh"},
		"image_version": {"2026.05.17"},
	}
	argv, err := buildArgv(sc, form)
	if err != nil {
		t.Fatalf("buildArgv: %v", err)
	}
	joined := strings.Join(argv, " ")
	for _, want := range []string{
		"fresh",
		"--backend-image ssdawweq/ifritah-api:2026.05.17",
		"--frontend-image ssdawweq/ifritah-web:2026.05.17",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv missing %q\nfull: %s", want, joined)
		}
	}
}

func TestBuildArgv_DeployAll_FrontendVersionExpandsPosImage(t *testing.T) {
	setVersionTestEnv(t)
	sc := scripts.Find("deploy-all.sh")
	form := url.Values{
		"image_version": {"2026.05.17"},
		"type":          {"frontend"},
		"tenant":        {"fresh"},
	}
	argv, err := buildArgv(sc, form)
	if err != nil {
		t.Fatalf("buildArgv: %v", err)
	}
	joined := strings.Join(argv, " ")
	for _, want := range []string{
		"ssdawweq/ifritah-web:2026.05.17",
		"--type frontend",
		"--tenant fresh",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv missing %q\nfull: %s", want, joined)
		}
	}
}

func TestDashboardTemplatesParse(t *testing.T) {
	funcs := template.FuncMap{
		"join":     strings.Join,
		"now":      func() string { return time.Now().Format("2006-01-02 15:04:05") },
		"stateClr": stateClass,
		"httpClr":  httpClass,
	}
	for _, name := range []string{"index.html", "app.html", "tenant.html", "scripts.html", "script.html", "password.html"} {
		if _, err := template.New("").Funcs(funcs).ParseFS(tplFS,
			"templates/_layout.html",
			"templates/palette.html",
			"templates/"+name,
		); err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
	}
}

func TestFilterAppNamesScopesTenantPrefix(t *testing.T) {
	server := &server{cfg: config.Config{TenantPrefix: "dev-"}}
	got := server.filterAppNames([]string{
		"dev-acme-backend",
		"prod-acme-backend",
		"dev-acme-frontend",
		"worker",
	})
	want := []string{"dev-acme-backend", "dev-acme-frontend"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("filterAppNames() = %#v, want %#v", got, want)
	}
}
