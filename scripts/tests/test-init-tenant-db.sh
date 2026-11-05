#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-init-tenant-db.sh — unit tests for init-tenant-db.sh
# =============================================================================
# Tests the pure-function behavior of init-tenant-db.sh's URL construction and
# argument handling. Does NOT hit MySQL / docker / the network — asserts what
# the script WOULD do using --dry-run and stub environment.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== syntax ==="
bash -n scripts/init-tenant-db.sh && pass "syntax init-tenant-db.sh"

echo ""
echo "=== http_post_register uses BASEURL prefix ==="
# Source the script in a way that lets us call functions without executing main.
# We can't source directly (has side effects), so grep the source line.
if grep -qE 'local\s+basepath="\$\{BASEURL:-/api/v2\}"' scripts/init-tenant-db.sh; then
    pass "http_post_register uses \${BASEURL:-/api/v2}"
else
    fail "http_post_register does not use BASEURL prefix — will POST to wrong path"
fi

if grep -qE 'url="http://\$\{BACKEND_APP\}\.web:\$\{backend_port\}' scripts/init-tenant-db.sh; then
    pass "register targets backend directly (bypasses frontend CSRF proxy)"
else
    fail "register still goes through Dokku edge — frontend proxy will return 403 CSRF"
fi

if grep -qE 'docker run --rm --network "\$network"' scripts/init-tenant-db.sh; then
    pass "register uses docker run --network to reach backend"
else
    fail "register does not use docker network to reach backend"
fi

echo ""
echo "=== install.env is sourced (so MYSQL_ADMIN_PASSWORD is available) ==="
if grep -qE 'INSTALL_ENV_FILE=.*install\.env' scripts/init-tenant-db.sh; then
    pass "install.env is sourced after config.env"
else
    # Not a hard fail — pending PR #114
    echo "SKIP: install.env sourcing not yet merged (PR #114)"
fi

echo ""
echo "=== dry-run --seed-only prints correct URL ==="
# Set up minimum env for the script to run --dry-run without touching anything
export BASE_DOMAIN=test.example.com
export MYSQL_ADMIN_PASSWORD=stub
export DOKKU_PORT=8080
export BASEURL=/api/v2
# Use a temp config file since --dry-run still requires --config or config.env
tmpcfg=$(mktemp)
trap 'rm -f "$tmpcfg"' EXIT
cat > "$tmpcfg" <<EOF
BASE_DOMAIN=$BASE_DOMAIN
MYSQL_ADMIN_PASSWORD=$MYSQL_ADMIN_PASSWORD
DOKKU_PORT=$DOKKU_PORT
BASEURL=$BASEURL
EOF

output=$(bash scripts/init-tenant-db.sh acme --seed-only --dry-run \
    --config "$tmpcfg" \
    --env ADMIN_USER=admin \
    --env ADMIN_PASSWORD=stubpass12345 2>&1 || true)

if echo "$output" | grep -qF "Would POST /api/v2/register"; then
    pass "dry-run seed prints '/api/v2/register'"
else
    echo "--- output ---"
    echo "$output"
    echo "--- end ---"
    fail "dry-run seed did not use /api/v2/register"
fi

echo ""
echo "=== existing-tenant schema replay does not require admin credentials ==="
if grep -qF 'goose_run "$image" up' scripts/init-tenant-db.sh &&
    grep -qF '"$(tenant_db_user)" "$(tenant_db_password)"' scripts/init-tenant-db.sh &&
    ! grep -qF 'run_migration_mysql' scripts/init-tenant-db.sh; then
    pass "schema replay is goose (/app/migrate up) as the tenant account"
else
    fail "schema replay must be goose (/app/migrate up) as the tenant account"
fi

if echo "$output" | grep -qF "Would POST /api/register "; then
    fail "dry-run seed still prints legacy '/api/register' (missing /v2)"
else
    pass "no legacy '/api/register' path present"
fi

echo ""
echo "=== dev-diag prints register URL ==="
if grep -q '\[dev-diag\] http_post_register url=' scripts/init-tenant-db.sh; then
    pass "http_post_register logs the URL in dev mode"
else
    fail "http_post_register does not log URL when DASHBOARD_ENV=dev"
fi

if grep -q '\[dev-diag\] register attempt=' scripts/init-tenant-db.sh; then
    pass "register retry loop logs attempts in dev mode"
else
    fail "register retry loop does not log attempts when DASHBOARD_ENV=dev"
fi

echo ""
echo "=== dry-run --schema-only plans goose from the backend image ==="
output=$(bash scripts/init-tenant-db.sh acme --schema-only --dry-run \
    --config "$tmpcfg" \
    --backend-image example/api:v1 2>&1 || true)

if echo "$output" | grep -qF "/app/migrate up from example/api:v1"; then
    pass "dry-run schema prints the goose command"
else
    echo "--- output ---"
    echo "$output"
    echo "--- end ---"
    fail "dry-run schema did not plan goose migrations"
fi

echo ""
echo "=== existing-data schema checks remain after goose and before completion ==="
goose_line="$(grep -n 'goose_run "\$image" up' scripts/init-tenant-db.sh | head -1 | cut -d: -f1)"
tables_line="$(grep -n '^tenant_missing_required_tables()' scripts/init-tenant-db.sh | head -1 | cut -d: -f1)"
validate_line="$(grep -n '^    validate_tenant_schema$' scripts/init-tenant-db.sh | head -1 | cut -d: -f1)"
key_line="$(grep -n '^    ensure_company_tenant_key$' scripts/init-tenant-db.sh | head -1 | cut -d: -f1)"
[ -n "$goose_line" ] && [ -n "$tables_line" ] && [ -n "$validate_line" ] && [ -n "$key_line" ] \
    || fail "existing-data migration checks are missing"
[ "$goose_line" -lt "$validate_line" ] && [ "$validate_line" -lt "$key_line" ] \
    || fail "required-table/key checks are not ordered after goose"
for table in company branches store user; do
    grep -q "SELECT '${table}'" scripts/init-tenant-db.sh \
        || fail "required existing-data table is not checked: $table"
done
grep -q 'tenant_registry_key "\$TENANT_DB_NAME"' scripts/init-tenant-db.sh \
    || fail "existing-data path does not read the registry tenant_key"
grep -q 'UPDATE company SET tenant_key =.*WHERE id = 1' scripts/init-tenant-db.sh \
    || fail "existing-data path does not update company row 1 with a WHERE guard"
pass "existing-data required tables and registry tenant_key remain after goose"

echo ""
echo "=== status mode remains read-only ==="
status_line="$(grep -n 'if \$STATUS_ONLY; then' scripts/init-tenant-db.sh | head -1 | cut -d: -f1)"
status_exit_line="$(grep -n '^    exit \$?' scripts/init-tenant-db.sh | head -1 | cut -d: -f1)"
apply_line="$(grep -n '^if ! \$SEED_ONLY; then' scripts/init-tenant-db.sh | head -1 | cut -d: -f1)"
[ -n "$status_line" ] && [ -n "$status_exit_line" ] && [ -n "$apply_line" ] \
    || fail "status-only control flow is missing"
[ "$status_line" -lt "$status_exit_line" ] && [ "$status_exit_line" -lt "$apply_line" ] \
    || fail "status mode can fall through into schema or seed work"
pass "status mode exits before schema or seed work"

echo ""
echo "=== all tests passed ==="
