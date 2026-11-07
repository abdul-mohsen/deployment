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
echo "=== deployment-owned overrides fail before side effects ==="
redaction_tmpdir="$REPO_DIR/.test-create-tenant-override.$$"
mkdir -p "$redaction_tmpdir"
trap 'rm -rf "$redaction_tmpdir"' EXIT
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
