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
echo "=== require_registry_tenant_key verifies the tenant identity contract ==="
MYSQL_MASTER_DB=zatca_master
MYSQL_QUERY_LOG="$tmpdir/registry-readiness-queries"
VALID_DEFAULT_TRIGGER=$'BEFORE\tINSERT\tbeginifnew.tenant_key=\'\'thensetnew.tenant_key=new.db_name;endif;end'
VALID_IMMUTABLE_TRIGGER=$'BEFORE\tUPDATE\tbeginifnew.tenant_key<>old.tenant_keythensignalstate\'45000\'setmessage_text=\'tenant_keyisimmutable\';endif;end'
: > "$MYSQL_QUERY_LOG"
run_mysql() {
    local args="$*"
    printf '%s\n' "$args" >> "$MYSQL_QUERY_LOG"
    case "$*" in
        *"information_schema.columns"*) printf '%s\n' "${STUB_COLUMN_CONTRACT-1}" ;;
        *"information_schema.statistics"*) printf '%s\n' "${STUB_INDEX_CONTRACT-1}" ;;
        *"trigger_name='tenant_key_default'"*)
            printf '%s\n' "${STUB_DEFAULT_TRIGGER-$VALID_DEFAULT_TRIGGER}"
            ;;
        *"trigger_name='tenant_key_immutable'"*)
            printf '%s\n' "${STUB_IMMUTABLE_TRIGGER-$VALID_IMMUTABLE_TRIGGER}"
            ;;
        *".tenant WHERE tenant_key IS NULL"*) printf '%s\n' "${STUB_EMPTY_KEYS-0}" ;;
        *) fail "unexpected MySQL query in tenant identity readiness check: $args" ;;
    esac
}
if require_registry_tenant_key 2>/dev/null; then
    pass "complete tenant identity schema is accepted"
else
    fail "complete tenant identity schema must be accepted"
fi
if STUB_COLUMN_CONTRACT=0 require_registry_tenant_key 2>/dev/null; then
    fail "incompatible tenant_key column must be refused"
else
    pass "incompatible tenant_key column is refused"
fi
if STUB_INDEX_CONTRACT=0 require_registry_tenant_key 2>/dev/null; then
    fail "missing or incompatible unique index must be refused"
else
    pass "missing or incompatible unique index is refused"
fi
if STUB_DEFAULT_TRIGGER='' require_registry_tenant_key 2>/dev/null; then
    fail "missing defaulting trigger must be refused"
else
    pass "missing defaulting trigger is refused"
fi
if STUB_DEFAULT_TRIGGER=$'BEFORE\tINSERT\tbeginsetnew.tenant_key=new.db_name;end' \
    require_registry_tenant_key 2>/dev/null; then
    fail "incompatible defaulting trigger must be refused"
else
    pass "incompatible defaulting trigger is refused"
fi
if STUB_IMMUTABLE_TRIGGER='' require_registry_tenant_key 2>/dev/null; then
    fail "missing immutability trigger must be refused"
else
    pass "missing immutability trigger is refused"
fi
if STUB_IMMUTABLE_TRIGGER=$'BEFORE\tUPDATE\tbeginend' \
    require_registry_tenant_key 2>/dev/null; then
    fail "incompatible immutability trigger must be refused"
else
    pass "incompatible immutability trigger is refused"
fi
if STUB_EMPTY_KEYS=1 require_registry_tenant_key 2>/dev/null; then
    fail "registry with a missing tenant_key value must be refused"
else
    pass "registry with a missing tenant_key value is refused"
fi
refusal="$(STUB_COLUMN_CONTRACT=0 require_registry_tenant_key 2>&1 || true)"
if printf '%s' "$refusal" | grep -q 'scripts/migrate-zatca-master.sh'; then
    pass "refusal tells the operator to run the script-managed migration"
else
    fail "refusal must name the script-managed migration"
fi
if grep -Eiq '(^|[[:space:]])(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|REPLACE)[[:space:]]' \
    "$MYSQL_QUERY_LOG"; then
    fail "registry readiness check must not execute DDL or data changes"
else
    pass "registry readiness check performs read-only queries"
fi
unset -f run_mysql

echo ""
echo "=== all lib.sh tests passed ==="
