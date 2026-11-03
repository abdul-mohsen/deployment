#!/usr/bin/env bash
# Static contract for backend updates and the goose migration status. Runtime
# behaviour needs Docker and Dokku and is not part of this suite.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "=== backend update order: verified backup, goose, image swap ==="
UPDATE=scripts/update-tenant.sh
backup_line="$(grep -n 'create_verified_tenant_db_backup "\$TENANT_NAME"' "$UPDATE" | head -1 | cut -d: -f1)"
schema_line="$(grep -n 'init-tenant-db.sh" "\$TENANT_NAME" \\' "$UPDATE" | head -1 | cut -d: -f1)"
deploy_line="$(grep -n 'deploy_component backend "\$BACKEND_IMAGE"' "$UPDATE" | head -1 | cut -d: -f1)"
[ -n "$backup_line" ] && [ -n "$schema_line" ] && [ -n "$deploy_line" ] \
    || fail "update-tenant.sh is missing the backup, goose or deploy step"
[ "$backup_line" -lt "$schema_line" ] || fail "goose runs before the verified backup"
[ "$schema_line" -lt "$deploy_line" ] || fail "image swap runs before goose"
pass "update order is verified backup, goose (init-tenant-db --schema-only), image swap"

echo
echo "=== a failed goose run exits before the image swap ==="
sed -n "${schema_line},$((deploy_line - 1))p" "$UPDATE" | grep -q 'exit 1' \
    || fail "failed goose run does not stop the update"
pass "failed goose run stops before the image swap"

echo
echo "=== deploy-all runs goose before the swap; rollback runs none ==="
grep -q 'init-tenant-db.sh" "\$tenant" --schema-only' scripts/deploy-all.sh \
    || fail "deploy-all does not run goose before the image swap"
! grep -q -- '--schema-only' scripts/rollback-tenant.sh \
    || fail "rollback-tenant runs goose; schema changes are forward-only"
grep -q -- '--confirm-schema-compatible' scripts/rollback-tenant.sh \
    || fail "rollback-tenant does not require --confirm-schema-compatible"
pass "deploy-all runs goose; rollback-tenant runs no goose and requires --confirm-schema-compatible"

echo
echo "=== goose status contract ==="
grep -q -- '--status' scripts/init-tenant-db.sh || fail "migration status command is missing"
grep -q 'schema_status=' scripts/init-tenant-db.sh \
    || fail "migration status does not report schema_status"
grep -q 'pending_migration=' scripts/init-tenant-db.sh \
    || fail "migration status does not list pending goose files"
grep -q 'goose_run "\$image" status' scripts/init-tenant-db.sh \
    || fail "migration status is not read from goose"
grep -q 'migration-status.sh' scripts/deployctl.sh \
    || fail "migration-status deployctl command is missing"
pass "goose migration status contract is present"

echo
echo "ALL TENANT MIGRATION DEPLOY TESTS PASSED"
