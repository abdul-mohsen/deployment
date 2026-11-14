#!/usr/bin/env bash
# Focused contract tests for the ZATCA master migration orchestration.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TEST_DIR="$REPO_DIR/.test-migrate-zatca-master.$$"
BIN="$TEST_DIR/bin"
GOOSE_CACHE="$TEST_DIR/goose-cache"
GOOSE_FIXTURE="$TEST_DIR/goose-fixture"
SOURCE_ROOT="$TEST_DIR/zatca-source/zatca_integration-7ea7056c1092a1ff5986e5267e876510a0465ab7"
SOURCE_ARCHIVE="$TEST_DIR/zatca-source.tar.gz"
mkdir -p "$BIN" "$SOURCE_ROOT/migrations/zatca_master"
trap 'rm -rf "$TEST_DIR"' EXIT

touch "$SOURCE_ROOT/migrations/zatca_master/00001_baseline.sql" \
    "$SOURCE_ROOT/migrations/zatca_master/00002_tenant_key.sql"
tar -czf "$SOURCE_ARCHIVE" -C "$TEST_DIR/zatca-source" \
    zatca_integration-7ea7056c1092a1ff5986e5267e876510a0465ab7

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

cat > "$GOOSE_FIXTURE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GOOSE_LOG"
exit 0
EOF

cat > "$BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf '%s\n' Linux ;;
    -m) printf '%s\n' x86_64 ;;
    *) exit 1 ;;
esac
EOF

cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
output=""
previous=""
url=""
for arg in "$@"; do
    if [ "$previous" = "--output" ]; then
        output="$arg"
    fi
    url="$arg"
    previous="$arg"
done
[ -n "$output" ] || exit 1
[ "${STUB_CURL_FAIL:-0}" = "1" ] && exit 1
printf '%s\n' download >> "${STUB_CURL_LOG:?}"
if [[ "$url" == *.tar.gz ]]; then
    cp "${ZATCA_SOURCE_ARCHIVE:?}" "$output"
else
    cp "${GOOSE_FIXTURE:?}" "$output"
fi
EOF

cat > "$BIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_SHA256_MISMATCH:-0}" = "1" ]; then
    printf '%s  %s\n' 0000000000000000000000000000000000000000000000000000000000000000 "${1:?}"
else
    printf '%s  %s\n' cce6e6371670f0654adc0ece407b81a22e53ba51e24e17a80ff7a0e25cda8548 "${1:?}"
fi
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

cat > "$BIN/tar" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-xzf" ]; then
    destination=""
    previous=""
    for arg in "$@"; do
        if [ "$previous" = "-C" ]; then
            destination="$arg"
        fi
        previous="$arg"
    done
    [ -n "$destination" ] || exit 1
    mkdir -p "$destination/zatca_integration-7ea7056c1092a1ff5986e5267e876510a0465ab7/migrations/zatca_master"
    touch \
        "$destination/zatca_integration-7ea7056c1092a1ff5986e5267e876510a0465ab7/migrations/zatca_master/00001_baseline.sql" \
        "$destination/zatca_integration-7ea7056c1092a1ff5986e5267e876510a0465ab7/migrations/zatca_master/00002_tenant_key.sql"
    exit 0
fi
exec /usr/bin/tar "$@"
EOF

chmod +x "$BIN"/*
chmod +x "$GOOSE_FIXTURE"

cat > "$TEST_DIR/config.env" <<EOF
MYSQL_CLIENT_MODE=host
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_ROOT_USER=root
MYSQL_ROOT_PASSWORD=root-password
MYSQL_MASTER_DB=zatca_master
BACKUP_DIR=$TEST_DIR/backups
LOG_DIR=$TEST_DIR/logs
ZATCA_MASTER_GOOSE_BIN=goose
ZATCA_MASTER_MIGRATION_LOCK_FILE=$TEST_DIR/master.lock
ZATCA_MASTER_MIGRATION_CACHE_DIR=$TEST_DIR/zatca-cache
EOF
grep -v '^ZATCA_MASTER_GOOSE_BIN=' "$TEST_DIR/config.env" > "$TEST_DIR/auto-config.env"
printf 'ZATCA_MASTER_GOOSE_CACHE_DIR=%s\n' "$GOOSE_CACHE" >> "$TEST_DIR/auto-config.env"
ZATCA_SOURCE_ARCHIVE="$SOURCE_ARCHIVE"
STUB_CURL_LOG="$TEST_DIR/curl.log"
export ZATCA_SOURCE_ARCHIVE STUB_CURL_LOG

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
    cat "$TEST_DIR/curl.log" 2>/dev/null || true
    tar -tzf "$SOURCE_ARCHIVE" 2>/dev/null || true
    fail "fresh migration failed"
fi
ls "$TEST_DIR/backups"/*.sql.gz >/dev/null 2>&1 || fail "fresh migration did not create a backup"
grep -q ' mysql .* up$' "$TEST_DIR/goose.log" || fail "fresh migration did not run Goose up"
pass "fresh database backup and Goose ordering"

echo
echo "=== Goose uses host loopback in the host-network runner ==="
: > "$TEST_DIR/goose.log"
if ! STUB_DB_EXISTS=0 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    PATH="$BIN:$PATH" bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
    >"$TEST_DIR/output" 2>&1; then
    cat "$TEST_DIR/output"
    fail "host-network Goose migration failed"
fi
grep -q '127.0.0.1' "$TEST_DIR/goose.log" ||
    fail "host-network Goose did not use 127.0.0.1"
pass "host-network Goose uses host loopback"

echo
echo "=== legacy database auto-baselines by default ==="
: > "$TEST_DIR/goose.log"
if ! STUB_DB_EXISTS=1 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    PATH="$BIN:$PATH" bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
    >"$TEST_DIR/output" 2>&1; then
    cat "$TEST_DIR/output"
    fail "legacy registry was not auto-baselined"
fi
grep -q ' version$' "$TEST_DIR/goose.log" || fail "default policy did not initialize Goose ledger"
grep -q ' up$' "$TEST_DIR/goose.log" || fail "default policy did not run Goose up"
grep -q 'INSERT INTO goose_db_version' "$TEST_DIR/mysql.log" ||
    fail "default policy did not record the baseline"
pass "legacy database auto-baselines with the approved default"

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
echo "=== Goose on PATH is reused without downloading ==="
: > "$TEST_DIR/goose.log"
: > "$TEST_DIR/mysql.log"
: > "$TEST_DIR/curl.log"
if ! STUB_DB_EXISTS=0 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    STUB_CURL_LOG="$TEST_DIR/curl.log" GOOSE_FIXTURE="$GOOSE_FIXTURE" \
    PATH="$BIN:$PATH" bash scripts/migrate-zatca-master.sh \
    --config "$TEST_DIR/auto-config.env" >"$TEST_DIR/output" 2>&1; then
    cat "$TEST_DIR/output"
    fail "Goose PATH resolution failed"
fi
[ ! -s "$TEST_DIR/curl.log" ] || fail "PATH Goose triggered a download"
grep -q ' mysql .* up$' "$TEST_DIR/goose.log" ||
    fail "PATH Goose did not run the migration"
pass "Goose on PATH is reused"

echo
echo "=== unset Goose downloads and runs the verified release ==="
rm -f "$BIN/goose"
rm -rf "$GOOSE_CACHE" "$TEST_DIR/backups" "$TEST_DIR/logs"
mkdir -p "$TEST_DIR/backups" "$TEST_DIR/logs"
: > "$TEST_DIR/goose.log"
: > "$TEST_DIR/mysql.log"
: > "$TEST_DIR/curl.log"
if ! STUB_DB_EXISTS=0 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    STUB_CURL_LOG="$TEST_DIR/curl.log" GOOSE_FIXTURE="$GOOSE_FIXTURE" \
    PATH="$BIN:$PATH" bash scripts/migrate-zatca-master.sh \
    --config "$TEST_DIR/auto-config.env" >"$TEST_DIR/output" 2>&1; then
    cat "$TEST_DIR/output"
    fail "automatic Goose download failed"
fi
if [ ! -x "$GOOSE_CACHE/goose-v3.30.0-amd64" ]; then
    cat "$TEST_DIR/output"
    find "$GOOSE_CACHE" -maxdepth 1 -type f -print 2>/dev/null || true
    fail "automatic Goose download did not install the cached binary"
fi
grep -q ' mysql .* up$' "$TEST_DIR/goose.log" ||
    fail "automatically installed Goose did not run the migration"
[ "$(wc -l < "$TEST_DIR/curl.log" | tr -d ' ')" = "1" ] ||
    fail "automatic Goose download did not use the downloader exactly once"
pass "unset Goose downloads, verifies, caches, and runs the release"

echo
echo "=== verified Goose cache is reused without downloading ==="
: > "$TEST_DIR/goose.log"
: > "$TEST_DIR/mysql.log"
: > "$TEST_DIR/curl.log"
if ! STUB_DB_EXISTS=0 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    STUB_CURL_LOG="$TEST_DIR/curl.log" GOOSE_FIXTURE="$GOOSE_FIXTURE" \
    PATH="$BIN:$PATH" bash scripts/migrate-zatca-master.sh \
    --config "$TEST_DIR/auto-config.env" >"$TEST_DIR/output" 2>&1; then
    cat "$TEST_DIR/output"
    fail "cached Goose reuse failed"
fi
[ ! -s "$TEST_DIR/curl.log" ] || fail "cached Goose triggered a second download"
grep -q ' mysql .* up$' "$TEST_DIR/goose.log" ||
    fail "cached Goose did not run the migration"
pass "verified Goose cache is reused"

echo
echo "=== Goose checksum mismatches fail closed ==="
rm -rf "$GOOSE_CACHE"
: > "$TEST_DIR/curl.log"
if STUB_DB_EXISTS=0 STUB_TENANT_TABLES=1 STUB_GOOSE_TABLES=0 STUB_BASE_TABLES=1 \
    STUB_GOOSE_LOG="$TEST_DIR/goose.log" STUB_MYSQL_LOG="$TEST_DIR/mysql.log" \
    STUB_CURL_LOG="$TEST_DIR/curl.log" GOOSE_FIXTURE="$GOOSE_FIXTURE" \
    STUB_SHA256_MISMATCH=1 PATH="$BIN:$PATH" \
    bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/auto-config.env" \
    >"$TEST_DIR/output" 2>&1; then
    fail "checksum mismatch was accepted"
fi
grep -q 'checksum verification failed' "$TEST_DIR/output" ||
    fail "checksum failure was not reported"
[ ! -e "$GOOSE_CACHE/goose-v3.30.0-amd64" ] ||
    fail "checksum failure left an installed Goose binary"
pass "Goose checksum mismatches fail closed"

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
