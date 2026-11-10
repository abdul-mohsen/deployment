#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-create-tenant.sh — unit tests for create-tenant.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== syntax ==="
bash -n scripts/create-tenant.sh && pass "syntax create-tenant.sh"

echo ""
echo "=== ensure_storage_mount is idempotent ==="
# Extract the ensure_storage_mount function and test it with a stubbed dokku.
if grep -q "ensure_storage_mount" scripts/create-tenant.sh; then
    pass "ensure_storage_mount helper exists"
else
    fail "ensure_storage_mount helper missing — storage:mount would fail on re-run"
fi

if ! grep -qE '^dokku storage:mount.*STORAGE_ROOT.*\$BACKEND_APP' scripts/create-tenant.sh; then
    pass "storage:mount is NOT called unconditionally"
else
    fail "unconditional dokku storage:mount call still present"
fi

# Function-level tests with local stubs
tmpdir="$REPO_DIR/.test-create-tenant.$$"
trap 'rm -rf "$tmpdir"' EXIT
rm -rf "$tmpdir"
mkdir -p "$tmpdir"

cat > "$tmpdir/dokku" <<'EOF'
#!/usr/bin/env bash
# stub: fake `storage:list` returns one pre-existing mount, `storage:mount` records calls
case "$1" in
    storage:list) echo "/host/uploads:/app/uploads" ;;
    storage:mount)
        echo "MOUNTED: $3" >> "$STUB_LOG"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmpdir/dokku"
export PATH="$tmpdir:$PATH"
export STUB_LOG="$tmpdir/mounts.log"
touch "$STUB_LOG"

# extract just the ensure_storage_mount function (plus info() stub) and exercise it
info() { echo "[i] $*"; }
eval "$(awk '/^ensure_storage_mount\(\)/,/^\}$/' scripts/create-tenant.sh)"

ensure_storage_mount myapp "/host/uploads:/app/uploads"
ensure_storage_mount myapp "/host/data:/app/data"

# First should have been a no-op (existed), second should have mounted
mounted=$(cat "$STUB_LOG")
if echo "$mounted" | grep -qF "/host/data:/app/data" && ! echo "$mounted" | grep -qF "/host/uploads:/app/uploads"; then
    pass "ensure_storage_mount mounts new paths, skips existing"
else
    echo "MOUNTED log: $mounted"
    fail "ensure_storage_mount behaviour is wrong"
fi

echo ""
echo "=== dokku container attached to tenant network ==="
if grep -q "docker network connect \"\$TENANT_NETWORK\" \"\$DOKKU_CONTAINER\"" scripts/create-tenant.sh; then
    pass "dokku container is attached to the tenant network"
else
    fail "dokku container is NOT attached to tenant network — dokku's nginx will 502 when proxying <app>.web hostnames"
fi

echo ""
echo "=== --update takes a verified backup before schema initialization ==="
cat > "$tmpdir/backup-tenant.sh" <<'EOF'
#!/usr/bin/env bash
printf 'backup\n' >> "$EVENT_LOG"
printf '%s\n' "$*" > "$BACKUP_ARGS"
exit "${BACKUP_RC:-0}"
EOF
cat > "$tmpdir/init-tenant-db.sh" <<'EOF'
#!/usr/bin/env bash
printf 'init\n' >> "$EVENT_LOG"
EOF
chmod +x "$tmpdir/backup-tenant.sh" "$tmpdir/init-tenant-db.sh"

export EVENT_LOG="$tmpdir/events.log"
export BACKUP_ARGS="$tmpdir/backup.args"
export BACKUP_RC=0
: > "$EVENT_LOG"

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
error() { echo "[x] $*" >&2; }
SCRIPT_DIR="$tmpdir"
TENANT_NAME="acme"
CONFIG_FILE="$tmpdir/config.env"
FORCE_UPDATE=true
BACKEND_IMAGE="example/backend:test"
MYSQL_APP_HOST="host.docker.internal"
MYSQL_PORT=3306
TENANT_DB_USER="usr_acme"
TENANT_DB_PASS="password"
DB_PROVISIONED=false

eval "$(
    awk '
        /^require_update_backup\(\) \{/ { capture=1 }
        /^initialize_tenant_schema\(\) \{/ { capture=1 }
        capture { print }
        capture && /^}$/ { capture=0 }
    ' scripts/create-tenant.sh
)"

require_update_backup || fail "verified update backup unexpectedly failed"
initialize_tenant_schema || fail "schema initialization unexpectedly failed"
first_event=$(sed -n '1p' "$EVENT_LOG")
second_event=$(sed -n '2p' "$EVENT_LOG")
[ "$first_event" = "backup" ] || fail "backup did not run before schema initialization"
[ "$second_event" = "init" ] || fail "schema initialization did not run after backup"
grep -q -- '--require-verified' "$BACKUP_ARGS" || fail "update backup did not require verification"
grep -q -- '--no-prune' "$BACKUP_ARGS" || fail "update backup unexpectedly pruned backups"
pass "verified backup runs before schema initialization"

echo ""
echo "=== failed --update backup blocks schema initialization ==="
: > "$EVENT_LOG"
export BACKUP_RC=1
if require_update_backup >/dev/null 2>&1; then
    fail "backup unexpectedly succeeded"
fi
if grep -q '^init$' "$EVENT_LOG"; then
    fail "schema initialization ran after backup failure"
fi
pass "backup failure blocks schema initialization"

echo ""
echo "=== fresh provisioning does not require an update backup ==="
: > "$EVENT_LOG"
export BACKUP_RC=0
FORCE_UPDATE=false
require_update_backup || fail "fresh provisioning unexpectedly required an update backup"
initialize_tenant_schema || fail "fresh schema initialization unexpectedly failed"
grep -q '^init$' "$EVENT_LOG" || fail "fresh provisioning did not initialize schema"
if grep -q '^backup$' "$EVENT_LOG"; then
    fail "fresh provisioning unexpectedly took update backup"
fi
pass "fresh provisioning skips update backup"

backup_gate_line=$(grep -n 'if ! require_update_backup; then' scripts/create-tenant.sh | cut -d: -f1)
schema_call_line=$(grep -n 'if ! initialize_tenant_schema; then' scripts/create-tenant.sh | cut -d: -f1)
[ -n "$backup_gate_line" ] || fail "update backup gate call is missing"
[ -n "$schema_call_line" ] || fail "schema initialization call is missing"
[ "$backup_gate_line" -lt "$schema_call_line" ] || fail "update backup gate appears after schema initialization"
pass "create-tenant invokes update backup gate before schema initialization"

echo ""
echo "=== all create-tenant.sh tests passed ==="
