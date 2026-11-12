#!/usr/bin/env bash
# Focused contract tests for the ZATCA master migration orchestration.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TEST_DIR="$REPO_DIR/.test-migrate-zatca-master.$$"
BIN="$TEST_DIR/bin"
ARTIFACT="$TEST_DIR/zatca-migrations"
mkdir -p "$BIN" "$ARTIFACT"
trap 'rm -rf "$TEST_DIR"' EXIT

touch "$ARTIFACT/00001_baseline.sql" "$ARTIFACT/00002_tenant_key.sql"

cat > "$BIN/flock" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_FLOCK_FAIL:-0}" = "1" ] && exit 1
exit 0
EOF

cat > "$BIN/goose" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GOOSE_LOG"
[ "${STUB_GOOSE_FAIL:-0}" = "1" ] && exit 1
exit 0
EOF

cat > "$BIN/mysql" <<'EOF'
#!/usr/bin/env bash
query="$*"
stdin="$(cat || true)"
printf 'ARGS=%s\nSQL=%s\n' "$query" "$stdin" >> "$STUB_MYSQL_LOG"
case "$query" in
    *"information_schema.schemata"*) printf '%s\n' "${STUB_DB_EXISTS:-1}" ;;
    *"information_schema.columns"*) printf '%s\n' "${STUB_TENANT_KEY_COLUMN:-1}" ;;
    *"trigger_name='tenant_key_default'"*) printf '%s\n' "${STUB_DEFAULT_TRIGGER:-1}" ;;
    *"trigger_name='tenant_key_immutable'"*) printf '%s\n' "${STUB_IMMUTABLE_TRIGGER:-1}" ;;
    *"information_schema.statistics"*) printf '%s\n' "${STUB_UNIQUE_KEY:-1}" ;;
    *"FROM goose_db_version"*) printf '%s\n' "${STUB_GOOSE_ROWS:-1}" ;;
    *"table_name='goose_db_version'"*) printf '%s\n' "${STUB_GOOSE_TABLES:-0}" ;;
    *"table_name='tenant'"*) printf '%s\n' "${STUB_TENANT_TABLES:-1}" ;;
    *"table_type='BASE TABLE'"*) printf '%s\n' "${STUB_BASE_TABLES:-1}" ;;
esac
EOF

cat > "$BIN/mysqldump" <<'EOF'
#!/usr/bin/env bash
printf 'stub master backup\n'
EOF

cat > "$BIN/gzip" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-t" ]; then
    [ -s "${2:-}" ]
else
    cat
fi
EOF

chmod +x "$BIN"/*

cat > "$TEST_DIR/config.env" <<EOF
MYSQL_CLIENT_MODE=host
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_ROOT_USER=root
MYSQL_ROOT_PASSWORD=root-password
MYSQL_MASTER_DB=zatca_master
BACKUP_DIR=$TEST_DIR/backups
LOG_DIR=$TEST_DIR/logs
ZATCA_MASTER_MIGRATION_ARTIFACT=$ARTIFACT
ZATCA_MASTER_GOOSE_BIN=goose
ZATCA_MASTER_MIGRATION_LOCK_FILE=$TEST_DIR/master.lock
EOF

run_migration() {
    : > "$TEST_DIR/goose.log"
    : > "$TEST_DIR/mysql.log"
    rm -rf "$TEST_DIR/backups" "$TEST_DIR/logs"
    mkdir -p "$TEST_DIR/backups" "$TEST_DIR/logs"
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" \
    STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    PATH="$BIN:$PATH" \
        bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
        >"$TEST_DIR/output" 2>&1
}

echo "=== syntax and command wiring ==="
bash -n scripts/migrate-zatca-master.sh
bash -n scripts/tests/test-migrate-zatca-master.sh
plan="$(bash scripts/deployctl.sh --plan db migrate-master --config "$TEST_DIR/config.env")"
[ "$plan" = "bash scripts/migrate-zatca-master.sh --config $TEST_DIR/config.env" ] ||
    fail "deployctl does not map db migrate-master to the orchestration script"
pass "syntax and deployctl command wiring"

echo
echo "=== fresh database backs up before Goose ==="
if ! STUB_DB_EXISTS=0 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    PATH="$BIN:$PATH" bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
    >"$TEST_DIR/output" 2>&1; then
    cat "$TEST_DIR/output"
    fail "fresh migration failed"
fi
ls "$TEST_DIR/backups"/*.sql.gz >/dev/null 2>&1 || fail "fresh migration did not create a backup"
grep -q ' mysql .* up$' "$TEST_DIR/goose.log" || fail "fresh migration did not run Goose up"
pass "fresh database backup and Goose ordering"

echo
echo "=== legacy database refuses silent adoption ==="
: > "$TEST_DIR/goose.log"
if STUB_DB_EXISTS=1 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    PATH="$BIN:$PATH" bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
    >"$TEST_DIR/output" 2>&1; then
    fail "legacy registry was silently adopted"
fi
grep -q 'refusing silent adoption' "$TEST_DIR/output" ||
    fail "legacy refusal did not explain the safe default"
[ ! -s "$TEST_DIR/goose.log" ] || fail "legacy refusal invoked Goose"
pass "legacy database is fail-closed by default"

echo
echo "=== explicitly authorized legacy baseline ==="
: > "$TEST_DIR/goose.log"
if ! STUB_DB_EXISTS=1 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    PATH="$BIN:$PATH" bash scripts/migrate-zatca-master.sh \
    --config "$TEST_DIR/config.env" --legacy-policy baseline \
    >"$TEST_DIR/output" 2>&1; then
    cat "$TEST_DIR/output"
    fail "explicit legacy baseline failed"
fi
grep -q ' version$' "$TEST_DIR/goose.log" || fail "legacy policy did not initialize Goose ledger"
grep -q ' up$' "$TEST_DIR/goose.log" || fail "legacy policy did not run Goose up"
grep -q 'INSERT INTO goose_db_version' "$TEST_DIR/mysql.log" ||
    fail "legacy policy did not record the explicit baseline"
pass "legacy adoption requires explicit baseline policy"

echo
echo "=== verification and lock failures are fail-closed ==="
if STUB_DB_EXISTS=0 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_IMMUTABLE_TRIGGER=0 STUB_GOOSE_LOG="$TEST_DIR/goose.log" \
    STUB_MYSQL_LOG="$TEST_DIR/mysql.log" PATH="$BIN:$PATH" \
    bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
    >"$TEST_DIR/output" 2>&1; then
    fail "incomplete trigger verification was accepted"
fi
grep -q 'verification failed' "$TEST_DIR/output" ||
    fail "verification failure was not reported"
if STUB_DB_EXISTS=0 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_FLOCK_FAIL=1 STUB_GOOSE_LOG="$TEST_DIR/goose.log" \
    STUB_MYSQL_LOG="$TEST_DIR/mysql.log" PATH="$BIN:$PATH" \
    bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
    >"$TEST_DIR/output" 2>&1; then
    fail "lock contention was accepted"
fi
grep -q 'already running' "$TEST_DIR/output" || fail "lock failure was not reported"
pass "verification and lock failures are fail-closed"

echo
echo "=== no ZATCA DDL is duplicated in deployment ==="
if grep -Eq 'CREATE TABLE[^;]*tenant|ALTER TABLE[^;]*tenant' scripts/migrate-zatca-master.sh; then
    fail "deployment migration script duplicates ZATCA tenant DDL"
fi
create_line="$(grep -n 'migrate-zatca-master.sh' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
apps_line="$(grep -n 'Check if apps already exist' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
[ -n "$create_line" ] && [ -n "$apps_line" ] && [ "$create_line" -lt "$apps_line" ] ||
    fail "tenant creation does not run master migration before app checks"
pass "ZATCA DDL remains external and migration precedes tenant provisioning"

echo
echo "ALL ZATCA MASTER MIGRATION TESTS PASSED"
