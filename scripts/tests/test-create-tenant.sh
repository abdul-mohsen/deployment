#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-create-tenant.sh — unit tests for create-tenant.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "=== syntax ==="
bash -n scripts/create-tenant.sh
pass "syntax create-tenant.sh"

echo
echo "=== fresh provisioning never silently adopts tenant state ==="
grep -q 'tenant_database_exists "\$TENANT_DB_NAME"' scripts/create-tenant.sh ||
    fail "create-tenant does not check for an existing tenant database"
grep -q 'tenant_registry_entry_exists "\$TENANT_NAME" "\$TENANT_DB_NAME"' scripts/create-tenant.sh ||
    fail "create-tenant does not check for an existing registry row"
grep -q 'Fresh provisioning refuses to adopt existing state' scripts/create-tenant.sh ||
    fail "create-tenant does not fail closed on existing state"
if grep -q -- '--adopt-existing\|ADOPT_EXISTING' scripts/create-tenant.sh; then
    fail "create-tenant exposes an adoption bypass"
fi
pass "fresh provisioning is no-adoption by default"

echo
echo "=== startup health and daemon ordering ==="
grep -q "echo '/healthz' > /home/dokku/\${BACKEND_APP}/CHECKS" scripts/create-tenant.sh ||
    fail "backend startup CHECKS path is not /healthz"
grep -q 'wait_for_runtime_health "\$BACKEND_APP" "/healthz"' scripts/create-tenant.sh ||
    fail "create-tenant does not block on backend startup health"
grep -q 'init-tenant-db.sh' scripts/create-tenant.sh ||
    fail "create-tenant does not run tenant initialization"
grep -q 'reload-zatca-daemon.sh' scripts/create-tenant.sh ||
    fail "create-tenant does not refresh daemon discovery"
pass "backend health, tenant initialization, and daemon refresh are ordered"

echo
echo "=== image deployments require verified BuildIdentity provenance ==="
lib_source_line="$(grep -nF 'source "$SCRIPT_DIR/lib.sh"' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
provenance_source_line="$(grep -nF 'source "$SCRIPT_DIR/tenant-provenance.sh"' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
[ -n "$lib_source_line" ] && [ -n "$provenance_source_line" ] &&
    [ "$lib_source_line" -lt "$provenance_source_line" ] \
    || fail "create-tenant does not import tenant provenance after lib.sh"

for helper in \
    resolve_build_identity \
    wait_for_runtime_health \
    verify_runtime_identity \
    record_verified_image_identity; do
    grep -q "$helper" scripts/create-tenant.sh \
        || fail "create-tenant image path does not use $helper"
done

for identity_field in \
    APP_VERSION \
    APP_COMMIT \
    APP_IMAGE_CHANNEL \
    APP_IMAGE_REF \
    APP_IMAGE_DIGEST \
    APP_IMAGE_RESOLVED_REF \
    APP_WORKFLOW_RUN_ID \
    APP_BUILT_AT; do
    grep -q "$identity_field" scripts/create-tenant.sh \
        || fail "create-tenant does not configure $identity_field"
done

backend_resolve_line="$(grep -n 'resolve_build_identity "\$BACKEND_IMAGE"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
backend_swap_line="$(grep -n 'dokku_git_from_image "\$BACKEND_APP" "\$BACKEND_IMAGE"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
backend_health_line="$(grep -n 'wait_for_runtime_health "\$BACKEND_APP" "/healthz"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
backend_verify_line="$(grep -n 'verify_runtime_identity "\$BACKEND_APP"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
[ -n "$backend_resolve_line" ] && [ -n "$backend_swap_line" ] &&
    [ -n "$backend_health_line" ] && [ -n "$backend_verify_line" ] &&
    [ "$backend_resolve_line" -lt "$backend_swap_line" ] &&
    [ "$backend_swap_line" -lt "$backend_health_line" ] &&
    [ "$backend_health_line" -lt "$backend_verify_line" ] \
    || fail "backend image deployment does not verify provenance after health"

frontend_resolve_line="$(grep -n 'resolve_build_identity "\$FRONTEND_IMAGE"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
frontend_swap_line="$(grep -n 'dokku_git_from_image "\$FRONTEND_APP" "\$FRONTEND_IMAGE"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
frontend_health_line="$(grep -n 'wait_for_runtime_health "\$FRONTEND_APP" "/"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
frontend_verify_line="$(grep -n 'verify_runtime_identity "\$FRONTEND_APP"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
[ -n "$frontend_resolve_line" ] && [ -n "$frontend_swap_line" ] &&
    [ -n "$frontend_health_line" ] && [ -n "$frontend_verify_line" ] &&
    [ "$frontend_resolve_line" -lt "$frontend_swap_line" ] &&
    [ "$frontend_swap_line" -lt "$frontend_health_line" ] &&
    [ "$frontend_health_line" -lt "$frontend_verify_line" ] \
    || fail "frontend image deployment does not verify provenance after health"

grep -q 'refusing to finish provisioning' scripts/create-tenant.sh \
    || fail "unverified image provenance can still report successful provisioning"
pass "image deployments import helpers, set identity, and fail closed on provenance"

echo
echo "=== --update verifies backup before Goose and fails closed ==="
order_tmpdir="$REPO_DIR/.test-create-tenant-order.$$"
rm -rf "$order_tmpdir"
mkdir -p "$order_tmpdir"
trap 'rm -rf "$order_tmpdir"' EXIT

cat > "$order_tmpdir/init-tenant-db.sh" <<'EOF'
#!/usr/bin/env bash
printf 'goose\n' >> "$EVENT_LOG"
EOF
chmod +x "$order_tmpdir/init-tenant-db.sh"

export EVENT_LOG="$order_tmpdir/events.log"
export BACKUP_RC=0
BACKUP_OUTPUT=$'backup-id\tbackup.sql.gz\tbackup.meta.json'
log() { :; }
warn() { :; }
error() { :; }
create_verified_tenant_db_backup() {
    printf 'backup\n' >> "$EVENT_LOG"
    if [ "$BACKUP_RC" -ne 0 ]; then
        return "$BACKUP_RC"
    fi
    printf '%s\n' "$BACKUP_OUTPUT"
}
ensure_tenant_image_available() { :; }
resolve_build_identity() { return 0; }
SCRIPT_DIR="$order_tmpdir"
TENANT_NAME="acme"
CONFIG_FILE="$order_tmpdir/config.env"
FORCE_UPDATE=true
EXISTING_TENANT_DATABASE=true
BACKEND_IMAGE="example/backend:test"
DB_PROVISIONED=false
UPDATE_BACKUP_ID=""
UPDATE_BACKUP_ARTIFACT=""

eval "$(sed -n '/^require_update_backup() {/,/^}/p' scripts/create-tenant.sh)"
eval "$(sed -n '/^initialize_tenant_schema() {/,/^}/p' scripts/create-tenant.sh)"

: > "$EVENT_LOG"
require_update_backup || fail "verified update backup unexpectedly failed"
initialize_tenant_schema || fail "schema initialization unexpectedly failed"
[ "$(sed -n '1p' "$EVENT_LOG")" = "backup" ] ||
    fail "verified backup did not run before Goose migration"
[ "$(sed -n '2p' "$EVENT_LOG")" = "goose" ] ||
    fail "Goose migration did not run after verified backup"
[ "$UPDATE_BACKUP_ID" = "backup-id" ] ||
    fail "verified backup identity was not retained"
pass "verified backup runs before Goose migration"

: > "$EVENT_LOG"
BACKUP_RC=1
if require_update_backup >/dev/null 2>&1; then
    fail "backup failure unexpectedly allowed update"
fi
if grep -q '^goose$' "$EVENT_LOG"; then
    fail "Goose migration ran after backup failure"
fi
pass "backup failure blocks Goose migration"

: > "$EVENT_LOG"
BACKUP_RC=0
BACKUP_OUTPUT=$'\t\t'
if require_update_backup >/dev/null 2>&1; then
    fail "incomplete backup identity unexpectedly allowed update"
fi
if grep -q '^goose$' "$EVENT_LOG"; then
    fail "Goose migration ran after incomplete backup identity"
fi
pass "incomplete backup verification blocks update"

echo
echo "=== Goose failure records verified backup audit without rollback ==="
AUDIT_ARGS="$order_tmpdir/migration-failure-audit.args"
tenant_record_failure() { :; }
ensure_tenant_provenance_schema() { :; }
tenant_record_audit() { printf '%s\n' "$@" > "$AUDIT_ARGS"; }
BUILD_IMAGE_REF="example/backend:test"
BUILD_DIGEST="sha256:abc"
BUILD_CHANNEL="stable"
BUILD_VERSION="1.2.3"
BUILD_COMMIT="abcdef"
BUILD_COMMIT_SHORT="abcdef"
BUILD_WORKFLOW_RUN_ID="123"
BUILD_WORKFLOW_RUN_URL="https://example.test/run/123"
BUILD_BUILT_AT="2026-11-10T00:00:00Z"
UPDATE_BACKUP_ID="backup-id"
UPDATE_BACKUP_ARTIFACT="backup.sql.gz"
cat > "$order_tmpdir/init-tenant-db.sh" <<'EOF'
#!/usr/bin/env bash
printf 'goose-failure\n' >> "$EVENT_LOG"
exit 1
EOF
chmod +x "$order_tmpdir/init-tenant-db.sh"
eval "$(sed -n '/^record_migration_failure() {/,/^}/p' scripts/create-tenant.sh)"
eval "$(sed -n '/^initialize_tenant_schema() {/,/^}/p' scripts/create-tenant.sh)"
: > "$EVENT_LOG"
if initialize_tenant_schema >/dev/null 2>&1; then
    fail "Goose failure unexpectedly allowed schema initialization"
fi
grep -q '^goose-failure$' "$EVENT_LOG" ||
    fail "Goose failure test did not execute the migration helper"
grep -qx 'failed' "$AUDIT_ARGS" ||
    fail "Goose failure audit did not record failed status"
grep -qx 'backup-id' "$AUDIT_ARGS" ||
    fail "Goose failure audit did not retain the verified backup ID"
grep -qx 'backup.sql.gz' "$AUDIT_ARGS" ||
    fail "Goose failure audit did not retain the verified backup artifact"
pass "Goose failure records backup-linked audit and remains fail-closed"

cat > "$order_tmpdir/init-tenant-db.sh" <<'EOF'
#!/usr/bin/env bash
printf 'goose\n' >> "$EVENT_LOG"
EOF
chmod +x "$order_tmpdir/init-tenant-db.sh"

echo
echo "=== verified backup identity is attached to deployment audit ==="
AUDIT_ARGS="$order_tmpdir/audit.args"
tenant_record_identity() { :; }
tenant_record_audit() { printf '%s\n' "$@" > "$AUDIT_ARGS"; }
BUILD_IMAGE_REF="example/backend:test"
BUILD_DIGEST="sha256:abc"
BUILD_CHANNEL="stable"
BUILD_VERSION="1.2.3"
BUILD_COMMIT="abcdef"
BUILD_COMMIT_SHORT="abcdef"
BUILD_WORKFLOW_RUN_ID="123"
BUILD_WORKFLOW_RUN_URL="https://example.test/run/123"
BUILD_BUILT_AT="2026-11-10T00:00:00Z"
eval "$(sed -n '/^record_verified_image_identity() {/,/^}/p' scripts/create-tenant.sh)"
record_verified_image_identity backend "$BACKEND_IMAGE" ||
    fail "verified image identity unexpectedly failed"
grep -qx 'backup-id' "$AUDIT_ARGS" ||
    fail "deployment audit did not receive the verified backup ID"
grep -qx 'backup.sql.gz' "$AUDIT_ARGS" ||
    fail "deployment audit did not receive the verified backup artifact"
pass "verified backup identity is attached to deployment audit"

echo
echo "=== partial provisioning without a tenant database stays recoverable ==="
: > "$EVENT_LOG"
BACKUP_RC=1
EXISTING_TENANT_DATABASE=false
UPDATE_BACKUP_ID="stale-backup-id"
UPDATE_BACKUP_ARTIFACT="stale-backup.sql.gz"
if ! require_update_backup; then
    fail "missing tenant database incorrectly required a backup"
fi
[ -z "$UPDATE_BACKUP_ID" ] && [ -z "$UPDATE_BACKUP_ARTIFACT" ] ||
    fail "missing tenant database retained stale backup identity"
initialize_tenant_schema || fail "partial provisioning recovery unexpectedly failed"
if grep -q '^backup$' "$EVENT_LOG"; then
    fail "partial provisioning without a database unexpectedly took a backup"
fi
grep -q '^goose$' "$EVENT_LOG" ||
    fail "partial provisioning recovery did not initialize the tenant schema"
pass "partial provisioning without a tenant database skips the backup gate"

echo
echo "=== update without backend migration skips the backup gate ==="
: > "$EVENT_LOG"
EXISTING_TENANT_DATABASE=true
BACKEND_IMAGE=""
if ! require_update_backup; then
    fail "update without a backend migration incorrectly required a backup"
fi
if [ -s "$EVENT_LOG" ]; then
    fail "update without a backend migration unexpectedly took a backup"
fi
pass "update without a backend migration skips the backup gate"
BACKEND_IMAGE="example/backend:test"

backup_gate_line="$(grep -n 'if ! require_update_backup; then' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
state_check_line="$(grep -n 'tenant_database_exists "\$TENANT_DB_NAME"' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
first_mutation_line="$(grep -n 'create_dokku_app "\$BACKEND_APP"' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
schema_call_line="$(grep -n 'if ! initialize_tenant_schema; then' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
[ -n "$backup_gate_line" ] && [ -n "$state_check_line" ] &&
    [ -n "$first_mutation_line" ] && [ -n "$schema_call_line" ] &&
    [ "$state_check_line" -lt "$backup_gate_line" ] &&
    [ "$backup_gate_line" -lt "$first_mutation_line" ] &&
    [ "$backup_gate_line" -lt "$schema_call_line" ] ||
    fail "--update backup gate does not follow DB detection and precede provisioning"
pass "--update backup gate follows DB detection and precedes tenant mutation and Goose"

echo
echo "=== deployment-owned overrides fail before side effects ==="
redaction_tmpdir="$REPO_DIR/.test-create-tenant-override.$$"
mkdir -p "$redaction_tmpdir"
trap 'rm -rf "$order_tmpdir" "$redaction_tmpdir"' EXIT
cat > "$redaction_tmpdir/config.env" <<'EOF'
BASE_DOMAIN=example.test
PUBLIC_PROTOCOL=https
EOF
if output="$(
    bash scripts/create-tenant.sh redaction-test \
        --dry-run --no-database --config "$redaction_tmpdir/config.env" \
        --env DB_PASSWORD=tenant-password-marker 2>&1
)"; then
    fail "create-tenant accepted a deployment-managed DB credential override"
fi
printf '%s\n' "$output" | grep -Fq 'Refusing invalid or reserved --env override.' ||
    fail "DB override rejection was not reported"
if printf '%s\n' "$output" | grep -Fq 'tenant-password-marker'; then
    fail "DB credential marker leaked in rejection output"
fi
pass "DB credential override is rejected before provisioning"

echo
echo "=== MySQL password SQL literal escaping ==="
eval "$(awk '/^mysql_password_sql_literal\(\)/,/^\}$/' scripts/create-tenant.sh)"
quote_input="quote'\"value"
escaped="$(mysql_password_sql_literal "$quote_input")"
[[ "$escaped" == \'*\' ]] ||
    fail "mysql_password_sql_literal did not quote the SQL literal"
[ "$escaped" != "'$quote_input'" ] ||
    fail "mysql_password_sql_literal did not escape embedded quotes"
pass "MySQL password SQL literal escaping"

echo
echo "All create-tenant tests passed."
