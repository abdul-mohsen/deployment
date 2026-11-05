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
sed -n "${schema_line},$((deploy_line - 1))p" "$UPDATE" |
    grep -q -- '--backend-image "\$BACKEND_IMAGE"' \
    || fail "update migration does not use the target backend image"
pass "update order is verified backup, goose (init-tenant-db --schema-only), image swap"

echo
echo "=== a failed goose run exits before the image swap ==="
sed -n "${schema_line},$((deploy_line - 1))p" "$UPDATE" | grep -q 'exit 1' \
    || fail "failed goose run does not stop the update"
pass "failed goose run stops before the image swap"

echo
echo "=== create and fleet deployment preserve the same migration order ==="
CREATE=scripts/create-tenant.sh
create_backup_line="$(grep -n 'create_verified_tenant_db_backup "\$TENANT_NAME"' "$CREATE" | head -1 | cut -d: -f1)"
create_schema_line="$(grep -n 'init-tenant-db.sh" "\$TENANT_NAME" \\' "$CREATE" | head -1 | cut -d: -f1)"
create_deploy_line="$(grep -n 'deploy_verified_component backend "\$BACKEND_IMAGE"' "$CREATE" | head -1 | cut -d: -f1)"
[ -n "$create_backup_line" ] && [ -n "$create_schema_line" ] && [ -n "$create_deploy_line" ] \
    || fail "create-tenant is missing backup, goose, or backend swap"
[ "$create_backup_line" -lt "$create_schema_line" ] &&
    [ "$create_schema_line" -lt "$create_deploy_line" ] \
    || fail "create-tenant migration order is unsafe"
sed -n "${create_schema_line},$((create_deploy_line - 1))p" "$CREATE" |
    grep -q -- '--backend-image "$BACKEND_IMAGE"' \
    || fail "create-tenant migration does not use the target backend image"
pass "create-tenant preserves verified backup, goose, image swap order"

fleet_backup_line="$(grep -n 'create_verified_tenant_db_backup "\$tenant"' scripts/deploy-all.sh | head -1 | cut -d: -f1)"
fleet_schema_line="$(grep -n 'init-tenant-db.sh" "\$tenant" --schema-only' scripts/deploy-all.sh | head -1 | cut -d: -f1)"
fleet_deploy_line="$(grep -n 'dokku_git_from_image "\$app" "\$image"' scripts/deploy-all.sh | head -1 | cut -d: -f1)"
[ -n "$fleet_backup_line" ] && [ -n "$fleet_schema_line" ] && [ -n "$fleet_deploy_line" ] \
    || fail "deploy-all is missing backup, goose, or image swap"
[ "$fleet_backup_line" -lt "$fleet_schema_line" ] &&
    [ "$fleet_schema_line" -lt "$fleet_deploy_line" ] \
    || fail "deploy-all migration order is unsafe"
grep -q -- '--backend-image "\$image"' scripts/deploy-all.sh \
    || fail "deploy-all migration does not use the target backend image"
pass "deploy-all preserves verified backup, goose, image swap order"

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
grep -q -- '--entrypoint /app/migrate' scripts/lib.sh \
    || fail "goose helper does not use the backend migration entrypoint"
grep -q 'RUN CGO_ENABLED=0 GOOS=linux go build .* -o /app/migrate ./cmd/migrate' \
    templates/backend/Dockerfile \
    || fail "backend template does not build the exact migration command"
grep -q 'COPY --from=builder /app/migrate' templates/backend/Dockerfile \
    || fail "backend template does not ship /app/migrate"
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
