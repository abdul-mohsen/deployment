package web

import (
	"context"
	"database/sql"
)

const upsertTenantPlanSQL = "INSERT INTO tenant_plan (tenant_name, plan, notes) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE plan=?, notes=?"

type tenantPlan struct {
	Plan        string
	Notes       string
	TrialEndsAt string
}

func (s *server) tenantPlan(ctx context.Context, tenant string) (tenantPlan, error) {
	plan := tenantPlan{Plan: "solo"}
	if s.masterDB == nil {
		return plan, nil
	}

	var planValue, notes, trialEndsAt sql.NullString
	err := s.masterDB.QueryRowContext(ctx,
		"SELECT plan, notes, trial_ends_at FROM tenant_plan WHERE tenant_name=?",
		tenant,
	).Scan(&planValue, &notes, &trialEndsAt)
	if err == sql.ErrNoRows {
		return plan, nil
	}
	if err != nil {
		return plan, err
	}
	if planValue.Valid && validPlan(planValue.String) {
		plan.Plan = planValue.String
	}
	if notes.Valid {
		plan.Notes = notes.String
	}
	if trialEndsAt.Valid {
		plan.TrialEndsAt = trialEndsAt.String
	}
	return plan, nil
}

func validPlan(plan string) bool {
	switch plan {
	case "solo", "growth", "business", "enterprise":
		return true
	default:
		return false
	}
}

func planBadgeClass(plan string) string {
	switch plan {
	case "solo":
		return "ring-cyan-500/30 text-cyan-300 bg-cyan-500/10"
	case "growth":
		return "ring-emerald-500/30 text-emerald-300 bg-emerald-500/10"
	case "business":
		return "ring-violet-500/30 text-violet-300 bg-violet-500/10"
	case "enterprise":
		return "ring-amber-500/30 text-amber-300 bg-amber-500/10"
	default:
		return "ring-zinc-700 text-zinc-300 bg-zinc-800/60"
	}
}

func tenantNameFromApp(app string) string {
	if len(app) > len("-backend") && app[len(app)-len("-backend"):] == "-backend" {
		return app[:len(app)-len("-backend")]
	}
	if len(app) > len("-frontend") && app[len(app)-len("-frontend"):] == "-frontend" {
		return app[:len(app)-len("-frontend")]
	}
	return app
}
