#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-lib.sh — unit tests for lib.sh helpers.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== syntax ==="
bash -n scripts/lib.sh && pass "syntax lib.sh"

echo ""
echo "=== dokku_host_port ==="
# Test the helper with a stub `docker` so we don't need docker installed.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Case 1: docker returns "0.0.0.0:8085" -> helper should print 8085.
cat > "$tmpdir/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "port" ] && [ "$2" = "dokku" ] && [ "$3" = "80/tcp" ]; then
    echo "0.0.0.0:8085"
    echo "[::]:8085"
    exit 0
fi
exit 1
EOF
chmod +x "$tmpdir/docker"

PATH="$tmpdir:$PATH"
# shellcheck disable=SC1091
source scripts/lib.sh
got="$(dokku_host_port)"
[ "$got" = "8085" ] && pass "returns 8085 when docker reports 0.0.0.0:8085" || fail "expected 8085 got '$got'"

# Case 2: docker unavailable -> fall back to $DOKKU_PORT
cat > "$tmpdir/docker" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
DOKKU_PORT=7777 got="$(dokku_host_port)"
[ "$got" = "7777" ] && pass "falls back to \$DOKKU_PORT when docker fails" || fail "expected 7777 got '$got'"

# Case 3: no docker, no DOKKU_PORT -> fall back to 8080 hardcoded
unset DOKKU_PORT
got="$(dokku_host_port)"
[ "$got" = "8080" ] && pass "falls back to 8080 when nothing else is set" || fail "expected 8080 got '$got'"

echo ""
echo "=== goose_run passes only the names cmd/migrate reads ==="
docker() { printf '%s\n' "$@" > "$tmpdir/goose-args"; }
goose_run example/api:v1 up host.docker.internal 3306 tenant_acme usr_acme pw123
goose_args="$(cat "$tmpdir/goose-args")"
for want in "HOST=host.docker.internal:3306" "DBNAME=tenant_acme" "DBUSER=usr_acme" "PASSWORD=pw123" "/app/migrate" "up"; do
    if printf '%s\n' "$goose_args" | grep -qxF -- "$want"; then
        pass "goose gets $want"
    else
        fail "goose must pass $want"
    fi
done
if printf '%s\n' "$goose_args" | grep -q '^DATABASE_URL=\|^DB_'; then
    fail "goose must not pass DATABASE_URL or DB_* settings"
else
    pass "goose passes no DATABASE_URL or DB_* settings"
fi

echo ""
echo "=== goose_run exact command contract and allow-list ==="
cat > "$tmpdir/expected-goose-up" <<'EOF'
run
--rm
--add-host=host.docker.internal:host-gateway
-e
HOST=host.docker.internal:3306
-e
DBNAME=tenant_acme
-e
DBUSER=usr_acme
-e
PASSWORD=pw123
--entrypoint
/app/migrate
example/api:v1
up
EOF
goose_run example/api:v1 up host.docker.internal 3306 tenant_acme usr_acme pw123
cmp -s "$tmpdir/expected-goose-up" "$tmpdir/goose-args" \
    && pass "goose up uses the exact /app/migrate argv contract" \
    || fail "goose up argv or environment contract changed"

cat > "$tmpdir/expected-goose-status" <<'EOF'
run
--rm
--add-host=host.docker.internal:host-gateway
-e
HOST=host.docker.internal:3306
-e
DBNAME=tenant_acme
-e
DBUSER=usr_acme
-e
PASSWORD=pw123
--entrypoint
/app/migrate
example/api:v1
status
EOF
goose_run example/api:v1 status host.docker.internal 3306 tenant_acme usr_acme pw123
cmp -s "$tmpdir/expected-goose-status" "$tmpdir/goose-args" \
    && pass "goose status uses the exact read-only /app/migrate argv contract" \
    || fail "goose status argv or environment contract changed"

: > "$tmpdir/goose-args"
if goose_run example/api:v1 migrate host.docker.internal 3306 tenant_acme usr_acme pw123 2>/dev/null; then
    fail "unsupported goose command was accepted"
fi
[ ! -s "$tmpdir/goose-args" ] \
    && pass "unsupported goose commands are rejected before Docker" \
    || fail "unsupported goose command reached Docker"
unset -f docker

echo ""
echo "=== require_registry_tenant_key refuses an unmigrated zatca_master ==="
MYSQL_MASTER_DB=zatca_master
run_mysql() {
    case "$*" in
        *"information_schema.columns"*) echo "${STUB_COLUMNS:-1}" ;;
        *"information_schema.triggers"*) echo "${STUB_TRIGGERS:-1}" ;;
    esac
}
if STUB_COLUMNS=1 STUB_TRIGGERS=1 require_registry_tenant_key 2>/dev/null; then
    pass "migrated registry (tenant_key + tenant_key_default) is accepted"
else
    fail "migrated registry must be accepted"
fi
if STUB_COLUMNS=0 STUB_TRIGGERS=1 require_registry_tenant_key 2>/dev/null; then
    fail "registry without tenant_key must be refused"
else
    pass "registry without tenant_key is refused"
fi
if STUB_COLUMNS=1 STUB_TRIGGERS=0 require_registry_tenant_key 2>/dev/null; then
    fail "registry without tenant_key_default must be refused"
else
    pass "registry without tenant_key_default is refused"
fi
refusal="$(STUB_COLUMNS=0 require_registry_tenant_key 2>&1 || true)"
if printf '%s' "$refusal" | grep -q "Apply ZATCA's zatca_master migrations first"; then
    pass "refusal tells the operator to apply ZATCA's zatca_master migrations first"
else
    fail "refusal must name ZATCA's zatca_master migrations"
fi
unset -f run_mysql

echo "=== MySQL admin credential resolution ==="
unset MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD MYSQL_ROOT_USER MYSQL_ROOT_PASSWORD
[ "$(mysql_admin_user)" = "dokku_admin" ] \
    && pass "defaults to dokku_admin" \
    || fail "default admin user is incorrect"
MYSQL_ADMIN_USER=service_admin MYSQL_ADMIN_PASSWORD=service_password
[ "$(mysql_admin_user)" = "service_admin" ] && [ "$(mysql_admin_password)" = "service_password" ] \
    && mysql_admin_configured \
    && pass "uses canonical admin credentials" \
    || fail "canonical admin credentials were not resolved"
unset MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD
MYSQL_ROOT_USER=legacy_admin MYSQL_ROOT_PASSWORD=legacy_password
[ "$(mysql_admin_user)" = "legacy_admin" ] && [ "$(mysql_admin_password)" = "legacy_password" ] \
    && pass "uses legacy root-named credentials as a compatibility fallback" \
    || fail "legacy credential fallback is broken"
unset MYSQL_ROOT_USER MYSQL_ROOT_PASSWORD
MYSQL_ROOT_PASSWORD=legacy_password
[ "$(mysql_admin_user)" = "root" ] && [ "$(mysql_admin_password)" = "legacy_password" ] \
    && pass "preserves password-only legacy root configuration" \
    || fail "password-only legacy root fallback is broken"

echo ""
echo "=== all lib.sh tests passed ==="
