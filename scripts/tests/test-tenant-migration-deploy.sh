#!/usr/bin/env bash
# Verify backend updates migrate before Dokku image changes and stop on failure.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
LOG_FILE="$TMP_DIR/commands.log"
CONFIG_FILE="$TMP_DIR/config.env"
BACKUP_SCRIPT="$TMP_DIR/backup.sh"
MIGRATION_SCRIPT="$TMP_DIR/migrate.sh"
DOCKER_BIN="$TMP_DIR/docker"

cat > "$CONFIG_FILE" <<EOF
BASE_DOMAIN=test.example.com
DOKKU_CONTAINER=dokku-test
IMAGE_PULL_POLICY=always
BACKUP_BEFORE_MIGRATION=1
EOF

cat > "$BACKUP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf 'backup %s\n' "$*" >> "$TEST_LOG"
exit "${BACKUP_RESULT:-0}"
EOF

cat > "$MIGRATION_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf 'migration %s\n' "$*" >> "$TEST_LOG"
exit "${MIGRATION_RESULT:-0}"
EOF

cat > "$DOCKER_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$TEST_LOG"
case "${1:-}" in
    ps)
        echo dokku-test
        ;;
    *)
        ;;
esac
exit 0
EOF

chmod +x "$BACKUP_SCRIPT" "$MIGRATION_SCRIPT" "$DOCKER_BIN"
export TEST_LOG="$LOG_FILE"
export PATH="$TMP_DIR:$PATH"
export TENANT_BACKUP_SCRIPT="$BACKUP_SCRIPT"
export TENANT_MIGRATION_SCRIPT="$MIGRATION_SCRIPT"
export DOKKU_CONTAINER=dokku-test
export _DOKKU_ENSURED=1

echo "=== successful backend update migrates before image switch ==="
UPDATE_OUTPUT="$TMP_DIR/success.out"
bash scripts/update-tenant.sh acme \
    --backend-image ssdawweq/ifritah-api:dev \
    --config "$CONFIG_FILE" >"$UPDATE_OUTPUT" 2>&1 \
    || { cat "$UPDATE_OUTPUT"; fail "successful update returned non-zero"; }

grep -q '^backup ' "$LOG_FILE" || fail "verified backup was not requested"
grep -q '^migration .*--schema-only' "$LOG_FILE" || fail "schema migration was not requested"
grep -q 'config:set' "$LOG_FILE" || fail "Dokku image configuration was not called"
grep -q 'git:from-image' "$LOG_FILE" || fail "Dokku image deployment was not called"
backup_line="$(grep -n '^backup ' "$LOG_FILE" | head -1 | cut -d: -f1)"
migration_line="$(grep -n '^migration ' "$LOG_FILE" | head -1 | cut -d: -f1)"
deploy_line="$(grep -n 'git:from-image' "$LOG_FILE" | head -1 | cut -d: -f1)"
[ "$backup_line" -lt "$migration_line" ] || fail "migration started before backup"
[ "$migration_line" -lt "$deploy_line" ] || fail "image switched before migration"
pass "successful update order is backup, migration, image deployment"

echo
echo "=== failed migration blocks image switch ==="
: > "$LOG_FILE"
if MIGRATION_RESULT=1 bash scripts/update-tenant.sh acme \
    --backend-image ssdawweq/ifritah-api:next \
    --config "$CONFIG_FILE" >"$TMP_DIR/failure.out" 2>&1; then
    cat "$TMP_DIR/failure.out"
    fail "failed migration returned zero"
fi
grep -q 'Backend schema migration failed' "$TMP_DIR/failure.out" \
    || fail "failed migration message was not surfaced"
grep -q '^migration ' "$LOG_FILE" || fail "failed migration was not attempted"
! grep -q 'config:set' "$LOG_FILE" || fail "Dokku config changed after migration failure"
! grep -q 'git:from-image' "$LOG_FILE" || fail "image switched after migration failure"
pass "failed migration stops before image deployment"

echo
echo "=== verified backup can be reused by auto-pull path ==="
: > "$LOG_FILE"
PREDEPLOY_BACKUP_VERIFIED=1 bash scripts/update-tenant.sh acme \
    --backend-image ssdawweq/ifritah-api:dev \
    --config "$CONFIG_FILE" >"$TMP_DIR/reuse.out" 2>&1 \
    || { cat "$TMP_DIR/reuse.out"; fail "backup reuse update returned non-zero"; }
! grep -q '^backup ' "$LOG_FILE" || fail "verified backup was duplicated"
grep -q '^migration ' "$LOG_FILE" || fail "migration was skipped after backup reuse"
pass "auto-pull backup is reused"

echo
echo "=== migration status contract ==="
grep -q 'deployment_schema_migrations' scripts/init-tenant-db.sh \
    || fail "migration ledger table is missing"
grep -q 'failed_migration=' scripts/init-tenant-db.sh \
    || fail "migration status does not expose failed files"
grep -q -- '--status' scripts/init-tenant-db.sh \
    || fail "migration status command is missing"
grep -q 'Could not record failed migration' scripts/init-tenant-db.sh \
    || fail "failed ledger writes are not fail-closed"
grep -q 'migration-status.sh' scripts/deployctl.sh \
    || fail "migration-status deployctl command is missing"
pass "per-file migration status contract is present"

echo
echo "ALL TENANT MIGRATION DEPLOY TESTS PASSED"
