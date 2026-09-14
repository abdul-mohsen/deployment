package web

import (
	"testing"
	"time"
)

func TestParseMigrationJSON(t *testing.T) {
	statuses := parseMigrationJSON(`{"tenant":"acme","image":"repo/api:dev","schema_status":"up_to_date","pending_migrations":[],"failed_migrations":[]}`)
	if len(statuses) != 1 {
		t.Fatalf("statuses=%d, want 1", len(statuses))
	}
	if statuses[0].Tenant != "acme" || statuses[0].SchemaStatus != "up_to_date" {
		t.Fatalf("unexpected status: %+v", statuses[0])
	}
}

func TestParseMigrationText(t *testing.T) {
	status := parseMigrationText(`tenant=hockun
image=repo/api:dev
failed_migration=0005_purchase_bill_product_item_fields.sql status=failed
schema_status=failed
[x] Could not read migration ledger`)
	if status.Tenant != "hockun" {
		t.Fatalf("tenant=%q", status.Tenant)
	}
	if status.SchemaStatus != "failed" {
		t.Fatalf("schema status=%q", status.SchemaStatus)
	}
	if len(status.FailedMigrations) != 1 || status.FailedMigrations[0] != "0005_purchase_bill_product_item_fields.sql" {
		t.Fatalf("failed migrations=%v", status.FailedMigrations)
	}
	if status.Error != "Could not read migration ledger" {
		t.Fatalf("error=%q", status.Error)
	}
}

func TestMigrationStatusIntervalMinimum(t *testing.T) {
	t.Setenv("MIGRATION_STATUS_INTERVAL", "1s")
	if got := migrationStatusInterval(); got != defaultMigrationStatusInterval {
		t.Fatalf("interval=%s, want default %s", got, defaultMigrationStatusInterval)
	}

	t.Setenv("MIGRATION_STATUS_INTERVAL", "45s")
	if got := migrationStatusInterval(); got != 45*time.Second {
		t.Fatalf("interval=%s, want 45s", got)
	}
}
