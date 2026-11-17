#!/usr/bin/env bash
# Deterministic contract tests for the tenant company seed and target checks.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TEST_DIR="$REPO_DIR/.test-company-seed-verification.$$"
BIN="$TEST_DIR/bin"
mkdir -p "$BIN" "$TEST_DIR/logs"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$BIN/mysql" <<'STUB'
#!/usr/bin/env bash
args="$*"
input="$(cat || true)"
printf 'ARGS=%s\n' "$args" >> "${STUB_MYSQL_LOG:?}"

if [[ "$args $input" == *"SELECT IFNULL(tenant_key, '') FROM tenant"* ]]; then
    printf '%s\n' "${STUB_REGISTRY_KEY:-anime-tenant-key}"
    exit 0
fi

if [[ "$args $input" == *"SELECT tenant_key FROM company ORDER BY id LIMIT 1"* ]]; then
    count_file="${STUB_ROW_READ_COUNT:?}"
    count=0
    [ ! -f "$count_file" ] || count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    case "${STUB_COMPANY_ROW_MODE:-valid}" in
        missing) ;;
        readback-fail)
            if [ "$count" -gt 1 ]; then
                echo "simulated company read-back failure" >&2
                exit 1
            fi
            ;;
        wrong-after-seed)
            if [ "$count" -gt 1 ] && [ -f "${STUB_SEED_WRITTEN:?}" ]; then
                printf '%s\n' "different-tenant-key"
            fi
            ;;
        existing-mismatch) printf '%s\n' "different-tenant-key" ;;
        valid)
            if [ "$count" -gt 1 ] && [ -f "${STUB_SEED_WRITTEN:?}" ]; then
                printf '%s\n' "${STUB_REGISTRY_KEY:-anime-tenant-key}"
            fi
            ;;
        *) echo "unknown company row fixture" >&2; exit 2 ;;
    esac
    exit 0
fi

if [[ "$input" == *"INSERT INTO company"* ]]; then
    printf 'COMPANY_SEED\n' >> "${STUB_MYSQL_LOG:?}"
    if [ "${STUB_SEED_FAIL:-0}" = "1" ]; then
        echo "simulated company seed write failure" >&2
        exit 1
    fi
    : > "${STUB_SEED_WRITTEN:?}"
fi

exit 0
STUB

cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for index in "${!args[@]}"; do
    if [ "${args[$index]}" = "mysql:8.0" ]; then
        mysql_args=("${args[@]:$((index + 2))}")
        exec "$(command -v mysql)" "${mysql_args[@]}"
    fi
done

case "$*" in
    "ps --format "*)
        printf '%s\n' dokku
        ;;
    *"exec dokku hostname")
        exit 0
        ;;
    *"exec -i dokku dokku config:get"*)
        cat >/dev/null || true
        key="${@: -1}"
        case "$key" in
            HOST) printf '%s\n' "${STUB_BACKEND_HOST:-host.docker.internal:3306}" ;;
            DBNAME) printf '%s\n' "${STUB_BACKEND_DBNAME:-tenant_anime}" ;;
            DB_HOST) printf '%s\n' "${STUB_BACKEND_DB_HOST:-host.docker.internal}" ;;
            DB_PORT) printf '%s\n' "${STUB_BACKEND_DB_PORT:-3306}" ;;
            DB_NAME) printf '%s\n' "${STUB_BACKEND_DB_NAME:-tenant_anime}" ;;
            DBUSER|DB_USER) printf '%s\n' "usr_anime" ;;
            PASSWORD|DB_PASSWORD) printf '%s\n' "tenant-password-marker" ;;
            *) exit 0 ;;
        esac
        ;;
    *"--entrypoint /app/migrate"*)
        printf 'GOOSE\n' >> "${STUB_DOCKER_LOG:?}"
        ;;
    *)
        printf 'DOCKER %s\n' "$*" >> "${STUB_DOCKER_LOG:?}"
        ;;
esac
exit 0
STUB

chmod +x "$BIN/"*

CONFIG="$TEST_DIR/config.env"
cat > "$CONFIG" <<EOF
BASE_DOMAIN=example.test
DOKKU_PORT=8080
MYSQL_ROOT_PASSWORD=admin-password-marker
MYSQL_HOST=host.docker.internal
MYSQL_PORT=3306
MYSQL_MASTER_DB=zatca_master
DB_HOST=127.0.0.1
DB_PORT=3306
LOG_DIR=$TEST_DIR/logs
EOF

reset_logs() {
    : > "$TEST_DIR/mysql.log"
    : > "$TEST_DIR/docker.log"
    rm -f "$TEST_DIR/company-row-reads"
    rm -f "$TEST_DIR/company-seed-written"
}

run_init() {
    local mode="${1:---seed-only}"
    shift || true
    reset_logs
    env \
        MYSQL_CLIENT_MODE=host \
        LOG_DIR="$TEST_DIR/logs" \
        STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
        STUB_DOCKER_LOG="$TEST_DIR/docker.log" \
        STUB_ROW_READ_COUNT="$TEST_DIR/company-row-reads" \
        STUB_SEED_WRITTEN="$TEST_DIR/company-seed-written" \
        MYSQL_CLIENT_MODE="${STUB_MYSQL_CLIENT_MODE:-host}" \
        STUB_SEED_FAIL="${STUB_SEED_FAIL:-0}" \
        STUB_COMPANY_ROW_MODE="${STUB_COMPANY_ROW_MODE:-valid}" \
        STUB_BACKEND_HOST="${STUB_BACKEND_HOST:-host.docker.internal:3306}" \
        STUB_BACKEND_DBNAME="${STUB_BACKEND_DBNAME:-tenant_anime}" \
        STUB_BACKEND_DB_HOST="${STUB_BACKEND_DB_HOST:-host.docker.internal}" \
        STUB_BACKEND_DB_PORT="${STUB_BACKEND_DB_PORT:-3306}" \
        STUB_BACKEND_DB_NAME="${STUB_BACKEND_DB_NAME:-tenant_anime}" \
        PATH="$BIN:$PATH" \
        bash scripts/init-tenant-db.sh anime "$mode" --config "$CONFIG" "$@" \
        >"$TEST_DIR/output" 2>&1
}

assert_no_secret_output() {
    if grep -Fq 'admin-password-marker' "$TEST_DIR/output" ||
        grep -Fq 'tenant-password-marker' "$TEST_DIR/output"; then
        fail "database credential leaked in initializer output"
    fi
}

assert_no_destructive_recovery() {
    if grep -Eiq 'DROP[[:space:]]+DATABASE|RESTORE[[:space:]]+DATABASE' "$TEST_DIR/mysql.log"; then
        fail "initializer attempted destructive database recovery"
    fi
}

echo "=== matching database aliases seed and read back the backend row ==="
if ! STUB_COMPANY_ROW_MODE=valid run_init --seed-only; then
    cat "$TEST_DIR/output"
    fail "matching seed and target should succeed"
fi
grep -q 'Company seed verified' "$TEST_DIR/output" ||
    fail "successful seed did not report row verification"
grep -q 'Tenant DB initialization complete' "$TEST_DIR/output" ||
    fail "successful row verification did not complete initialization"
grep -Fq -- '--connect-timeout=5' "$TEST_DIR/mysql.log" ||
    fail "initializer MySQL clients did not set a five-second connection timeout"
grep -q 'COMPANY_SEED' "$TEST_DIR/mysql.log" ||
    fail "company seed SQL was not run"
assert_no_secret_output
pass "seeded company row and tenant identity are verified"

echo
echo "=== dry-run does not report initialization as verified ==="
if ! run_init --seed-only --dry-run; then
    cat "$TEST_DIR/output"
    fail "seed-only dry-run failed"
fi
grep -q 'Dry run complete: tenant database changes and seed verification were not performed' "$TEST_DIR/output" ||
    fail "dry-run did not distinguish an unverified plan"
! grep -q 'Tenant DB initialization complete' "$TEST_DIR/output" ||
    fail "dry-run reported tenant initialization complete without verification"
[ ! -s "$TEST_DIR/mysql.log" ] ||
    fail "dry-run performed a database operation"
pass "dry-run is clearly not a successful initialization"

echo
echo "=== Docker MySQL helper also bounds initializer connections ==="
if ! STUB_MYSQL_CLIENT_MODE=docker STUB_COMPANY_ROW_MODE=valid run_init --seed-only; then
    cat "$TEST_DIR/output"
    fail "Docker MySQL helper could not verify the company seed"
fi
grep -Fq -- '--connect-timeout=5' "$TEST_DIR/mysql.log" ||
    fail "Docker MySQL helper did not set a five-second connection timeout"
grep -q 'Company seed verified' "$TEST_DIR/output" ||
    fail "Docker MySQL helper did not read back the company seed"
assert_no_secret_output
pass "Docker MySQL helper uses a bounded connection and verifies the row"

echo
echo "=== schema-only initialization verifies before returning ==="
if ! STUB_COMPANY_ROW_MODE=valid run_init --schema-only --backend-image example/api:dev; then
    cat "$TEST_DIR/output"
    fail "schema-only initialization with a verified company row failed"
fi
grep -q 'GOOSE' "$TEST_DIR/docker.log" ||
    fail "schema-only initialization did not run backend migrations"
grep -q 'Company seed verified' "$TEST_DIR/output" ||
    fail "schema-only initialization did not verify the company row"
grep -q 'Tenant DB initialization complete' "$TEST_DIR/output" ||
    fail "schema-only initialization did not finish after successful verification"
assert_no_secret_output
pass "schema-only path verifies the row after migrations"

echo
echo "=== failed company seed stops initialization ==="
if STUB_SEED_FAIL=1 run_init --seed-only; then
    fail "company seed SQL failure was accepted"
fi
grep -qi 'company/store seed failed' "$TEST_DIR/output" ||
    { cat "$TEST_DIR/output"; fail "seed write failure was not actionable"; }
! grep -q 'Tenant DB initialization complete' "$TEST_DIR/output" ||
    fail "initializer reported completion after seed failure"
assert_no_secret_output
assert_no_destructive_recovery
pass "seed write failure is fail-closed"

echo
echo "=== successful seed command with missing row fails read-back ==="
if STUB_COMPANY_ROW_MODE=missing run_init --seed-only; then
    fail "missing company row was accepted"
fi
grep -qi 'company row or tenant_key is missing' "$TEST_DIR/output" ||
    fail "missing company row was not reported"
! grep -q 'Tenant DB initialization complete' "$TEST_DIR/output" ||
    fail "initializer reported completion without a company row"
assert_no_secret_output
assert_no_destructive_recovery
pass "missing row after seed is fail-closed"

echo
echo "=== company read-back query failure stops initialization ==="
if STUB_COMPANY_ROW_MODE=readback-fail run_init --seed-only; then
    fail "company read-back query failure was accepted"
fi
grep -qi 'could not read back the company seed' "$TEST_DIR/output" ||
    fail "company read-back query failure was not reported"
! grep -q 'Tenant DB initialization complete' "$TEST_DIR/output" ||
    fail "initializer reported completion after read-back query failure"
assert_no_secret_output
assert_no_destructive_recovery
pass "company read-back query failure is fail-closed"

echo
echo "=== schema-only missing row blocks completion after migration ==="
if STUB_COMPANY_ROW_MODE=missing run_init --schema-only --backend-image example/api:dev; then
    fail "schema-only initialization accepted a missing company row"
fi
grep -qi 'company row or tenant_key is missing' "$TEST_DIR/output" ||
    fail "schema-only missing row was not reported"
! grep -q 'Tenant DB initialization complete' "$TEST_DIR/output" ||
    fail "schema-only initializer reported completion without a company row"
grep -q 'GOOSE' "$TEST_DIR/docker.log" ||
    fail "schema-only missing-row regression did not reach the migration step"
assert_no_secret_output
assert_no_destructive_recovery
pass "schema-only missing row stops before backend deployment"

echo
echo "=== read-back tenant key mismatch fails initialization ==="
if STUB_COMPANY_ROW_MODE=wrong-after-seed run_init --seed-only; then
    fail "read-back tenant-key mismatch was accepted"
fi
grep -qi 'tenant_key.*does not match' "$TEST_DIR/output" ||
    fail "tenant-key mismatch was not reported"
! grep -q 'Tenant DB initialization complete' "$TEST_DIR/output" ||
    fail "initializer reported completion with the wrong tenant key"
assert_no_secret_output
assert_no_destructive_recovery
pass "mismatched tenant identity is fail-closed"

echo
echo "=== pre-existing tenant-key mismatch is not overwritten ==="
if STUB_COMPANY_ROW_MODE=existing-mismatch run_init --seed-only; then
    fail "pre-existing tenant-key mismatch was accepted"
fi
grep -qi 'existing company tenant_key.*different tenant' "$TEST_DIR/output" ||
    fail "pre-existing tenant mismatch was not reported"
! grep -q 'COMPANY_SEED' "$TEST_DIR/mysql.log" ||
    fail "pre-existing mismatched company row was modified"
assert_no_destructive_recovery
pass "existing tenant identity is preserved"

echo
echo "=== database-name mismatch fails before database writes ==="
if STUB_BACKEND_DBNAME=tenant_other run_init --schema-only --backend-image example/api:dev; then
    fail "backend database-name mismatch was accepted"
fi
grep -qi 'tenant db target mismatch' "$TEST_DIR/output" ||
    fail "database-name mismatch was not reported"
[ ! -s "$TEST_DIR/mysql.log" ] ||
    fail "target mismatch attempted SQL before failing"
! grep -q 'GOOSE' "$TEST_DIR/docker.log" ||
    fail "target mismatch ran Goose before failing"
assert_no_secret_output
assert_no_destructive_recovery
pass "database-name mismatch fails before mutation"

echo
echo "=== backend host mismatch fails before database writes ==="
if STUB_BACKEND_HOST=other-db.example.test:3306 \
    run_init --schema-only --backend-image example/api:dev; then
    fail "backend host mismatch was accepted"
fi
grep -qi 'tenant db target mismatch' "$TEST_DIR/output" ||
    fail "backend host mismatch was not reported"
[ ! -s "$TEST_DIR/mysql.log" ] ||
    fail "host mismatch attempted SQL before failing"
! grep -q 'GOOSE' "$TEST_DIR/docker.log" ||
    fail "host mismatch ran Goose before failing"
assert_no_secret_output
assert_no_destructive_recovery
pass "backend host mismatch fails before mutation"

echo
echo "=== unverifiable backend host fails before database writes ==="
if STUB_BACKEND_HOST=invalid-host run_init --schema-only --backend-image example/api:dev; then
    fail "backend host without a port was accepted"
fi
grep -qi 'Backend HOST must be configured as host:port' "$TEST_DIR/output" ||
    fail "unverifiable backend host was not reported"
[ ! -s "$TEST_DIR/mysql.log" ] ||
    fail "unverifiable backend host attempted SQL before failing"
! grep -q 'GOOSE' "$TEST_DIR/docker.log" ||
    fail "unverifiable backend host ran Goose before failing"
pass "unverifiable backend target fails before mutation"

echo
echo "=== backend loopback is not confused with the host database ==="
if STUB_BACKEND_HOST=127.0.0.1:3306 run_init --schema-only --backend-image example/api:dev; then
    fail "backend container loopback was treated as the host MySQL endpoint"
fi
grep -qi 'initializer DB_HOST does not resolve to backend HOST' "$TEST_DIR/output" ||
    fail "loopback-versus-host-gateway mismatch was not reported"
[ ! -s "$TEST_DIR/mysql.log" ] ||
    fail "loopback mismatch attempted SQL before failing"
! grep -q 'GOOSE' "$TEST_DIR/docker.log" ||
    fail "loopback mismatch ran Goose before failing"
pass "container loopback cannot masquerade as the host database"

echo
echo "=== create-tenant gates backend image swap on initializer success ==="
init_line="$(grep -nF 'bash "$SCRIPT_DIR/init-tenant-db.sh" "$TENANT_NAME" \' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
deploy_line="$(grep -nF 'dokku_git_from_image "$BACKEND_APP" "$BUILD_RESOLVED_REF"' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
[ -n "$init_line" ] && [ -n "$deploy_line" ] && [ "$init_line" -lt "$deploy_line" ] ||
    fail "backend image swap is not ordered after the schema initializer"
grep -q '^set -euo pipefail$' scripts/create-tenant.sh ||
    fail "create-tenant does not propagate an initializer failure"
sed -n "${init_line},$((deploy_line - 1))p" scripts/create-tenant.sh |
    grep -Fq -- '--schema-only' ||
    fail "backend deployment initializer does not use schema-only verification"
pass "backend deployment is gated by initializer status"

echo
echo "ALL COMPANY SEED VERIFICATION TESTS PASSED"
