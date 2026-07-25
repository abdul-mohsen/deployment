package web

import (
	"strings"
	"testing"
)

func TestValidPlan(t *testing.T) {
	for _, plan := range []string{"solo", "growth", "business", "enterprise"} {
		if !validPlan(plan) {
			t.Errorf("validPlan(%q) = false", plan)
		}
	}
	for _, plan := range []string{"", "free", "Growth", "enterprise; DROP TABLE tenant_plan"} {
		if validPlan(plan) {
			t.Errorf("validPlan(%q) = true", plan)
		}
	}
}

func TestTenantNameFromApp(t *testing.T) {
	tests := map[string]string{
		"acme-backend":  "acme",
		"acme-frontend": "acme",
		"acme":          "acme",
	}
	for app, want := range tests {
		if got := tenantNameFromApp(app); got != want {
			t.Errorf("tenantNameFromApp(%q) = %q, want %q", app, got, want)
		}
	}
}

func TestUpsertTenantPlanSQLUsesPlaceholders(t *testing.T) {
	if strings.Count(upsertTenantPlanSQL, "?") != 5 {
		t.Fatalf("upsert query should use five placeholders: %q", upsertTenantPlanSQL)
	}
	if !strings.Contains(upsertTenantPlanSQL, "ON DUPLICATE KEY UPDATE") {
		t.Fatalf("upsert query is missing duplicate-key handling: %q", upsertTenantPlanSQL)
	}
}
