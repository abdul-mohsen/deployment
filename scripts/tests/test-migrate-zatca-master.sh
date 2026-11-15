#!/usr/bin/env bash
# Focused contract tests for the ZATCA master registry migration.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TEST_DIR="$REPO_DIR/.test-migrate-zatca-master.$$"
BIN="$TEST_DIR/bin"
STATE="$TEST_DIR/mysql-state"
EVENTS="$TEST_DIR/events.log"
MYSQL_LOG="$TEST_DIR/mysql.log"
GOOSE_LOG="$TEST_DIR/goose.log"
CURL_LOG="$TEST_DIR/curl.log"
mkdir -p "$BIN"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$BIN/flock" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_FLOCK_FAIL:-0}" = "1" ] && exit 1
exit 0
EOF

cat > "$BIN/mysql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
stdin="$(cat || true)"
query="${args}"$'\n'"${stdin}"
printf 'ARGS=%s\nSQL=%s\n' "$args" "$stdin" >> "${STUB_MYSQL_LOG:?}"
source "${STUB_MYSQL_STATE:?}"

if [[ "$query" == *"CURRENT_USER()"* ]]; then
    [ "${STUB_PREFLIGHT_FAIL:-0}" = "1" ] && exit 1
    printf '1\troot@localhost\troot@localhost\t\n'
    exit 0
fi

case "$query" in
    *"information_schema.schemata"*)
        printf '%s\n' "$DB_EXISTS"
        exit 0
        ;;
    *"information_schema.tables"*"table_name='tenant'"*)
        printf '%s\n' "$TENANT_TABLE"
        exit 0
        ;;
    *"information_schema.columns"*"column_name IN ('id','name','db_name','zatca_env','alert_email','enabled','created_at')"*)
        printf '%s\n' "$BASELINE_COLUMNS"
        exit 0
        ;;
    *"SELECT CONCAT(is_nullable, CHAR(9)"*)
        printf '%s\t%s\n' "$TENANT_KEY_NULLABLE" "$TENANT_KEY_DEFAULT"
        exit 0
        ;;
    *"information_schema.columns"*"tenant_key"*)
        printf '%s\n' "$TENANT_KEY_COLUMN"
        exit 0
        ;;
    *"information_schema.statistics"*"index_name='db_name'"*)
        if [[ "$query" == *"non_unique=0"* ]]; then
            printf '%s\n' "$DB_NAME_INDEX_VALID"
        else
            printf '%s\n' "$DB_NAME_INDEX_ROWS"
        fi
        exit 0
        ;;
    *"information_schema.statistics"*"uq_tenant_key"*)
        if [[ "$query" == *"non_unique=0"* ]]; then
            printf '%s\n' "$UNIQUE_INDEX_VALID"
        else
            printf '%s\n' "$UNIQUE_INDEX_ROWS"
        fi
        exit 0
        ;;
    *"information_schema.triggers"*"tenant_key_default"*)
        if [ "$DEFAULT_TRIGGER" = "1" ]; then
            if [ "$DEFAULT_TRIGGER_VALID" = "1" ]; then
                printf "BEFORE\tINSERT\tbeginifnew.tenant_key=''thensetnew.tenant_key=new.db_name;endif;end\n"
            else
                printf 'AFTER\tUPDATE\tbad-trigger\n'
            fi
        fi
        exit 0
        ;;
    *"information_schema.triggers"*"tenant_key_immutable"*)
        if [ "$IMMUTABLE_TRIGGER" = "1" ]; then
            if [ "$IMMUTABLE_TRIGGER_VALID" = "1" ]; then
                printf "BEFORE\tUPDATE\tbeginifnew.tenant_key<>old.tenant_keythensignalstate'45000'setmessage_text='tenant_keyisimmutable';endif;end\n"
            else
                printf 'AFTER\tINSERT\tbad-trigger\n'
            fi
        fi
        exit 0
        ;;
    *"CHAR_LENGTH(db_name)>64"*)
        printf '%s\n' "$TOO_LONG_DB_NAME"
        exit 0
        ;;
    *"SELECT COUNT(*) FROM tenant WHERE tenant_key IS NULL OR tenant_key=''"*)
        printf '%s\n' "$MISSING_KEYS"
        exit 0
        ;;
    *"candidate_key"*)
        printf '%s\n' "$DUPLICATE_KEYS"
        exit 0
        ;;
    *"FROM tenant"*)
        printf '0\n'
        exit 0
        ;;
esac

if [[ "$query" == *"UPDATE tenant SET tenant_key=db_name"* ]]; then
    if [[ "$query" == *"WHERE tenant_key IS NULL OR tenant_key=''"* ]]; then
        MISSING_KEYS=0
    else
        NONEMPTY_KEY=overwritten
        MISSING_KEYS=0
    fi
    printf 'BACKFILL\n' >> "$STUB_EVENTS"
fi
if [[ "$query" == *"CREATE DATABASE"* ]]; then
    DB_EXISTS=1
    printf 'DATABASE_CREATE\n' >> "${STUB_EVENTS:?}"
fi
if [[ "$query" == *"CREATE TABLE IF NOT EXISTS"* && "$query" == *"tenant"* ]]; then
    TENANT_TABLE=1
    BASELINE_COLUMNS=7
    DB_NAME_INDEX_ROWS=1
    DB_NAME_INDEX_VALID=1
    printf 'SCHEMA_DDL\n' >> "$STUB_EVENTS"
fi
if [[ "$query" == *"ADD COLUMN tenant_key"* ]]; then
    TENANT_KEY_COLUMN=1
    TENANT_KEY_NULLABLE=YES
    TENANT_KEY_DEFAULT='<NULL>'
    printf 'SCHEMA_DDL\n' >> "$STUB_EVENTS"
fi
if [[ "$query" == *"MODIFY COLUMN tenant_key"* ]]; then
    TENANT_KEY_NULLABLE=NO
    TENANT_KEY_DEFAULT=''
    printf 'SCHEMA_DDL\n' >> "$STUB_EVENTS"
fi
if [[ "$query" == *"ADD UNIQUE KEY uq_tenant_key"* ||
    "$query" == *"CREATE UNIQUE INDEX uq_tenant_key"* ]]; then
    UNIQUE_INDEX_ROWS=1
    UNIQUE_INDEX_VALID=1
    printf 'SCHEMA_DDL\n' >> "$STUB_EVENTS"
fi
if [[ "$query" == *"CREATE TRIGGER tenant_key_default"* ]]; then
    DEFAULT_TRIGGER=1
    DEFAULT_TRIGGER_VALID=1
    printf 'SCHEMA_DDL\n' >> "$STUB_EVENTS"
fi
if [[ "$query" == *"CREATE TRIGGER tenant_key_immutable"* ]]; then
    IMMUTABLE_TRIGGER=1
    IMMUTABLE_TRIGGER_VALID=1
    printf 'SCHEMA_DDL\n' >> "$STUB_EVENTS"
fi

cat > "$STUB_MYSQL_STATE" <<STATE_EOF
DB_EXISTS=$DB_EXISTS
TENANT_TABLE=$TENANT_TABLE
BASELINE_COLUMNS=$BASELINE_COLUMNS
DB_NAME_INDEX_ROWS=$DB_NAME_INDEX_ROWS
DB_NAME_INDEX_VALID=$DB_NAME_INDEX_VALID
TENANT_KEY_COLUMN=$TENANT_KEY_COLUMN
TENANT_KEY_NULLABLE=$TENANT_KEY_NULLABLE
TENANT_KEY_DEFAULT=$(printf '%q' "$TENANT_KEY_DEFAULT")
UNIQUE_INDEX_ROWS=$UNIQUE_INDEX_ROWS
UNIQUE_INDEX_VALID=$UNIQUE_INDEX_VALID
DEFAULT_TRIGGER=$DEFAULT_TRIGGER
DEFAULT_TRIGGER_VALID=$DEFAULT_TRIGGER_VALID
IMMUTABLE_TRIGGER=$IMMUTABLE_TRIGGER
IMMUTABLE_TRIGGER_VALID=$IMMUTABLE_TRIGGER_VALID
MISSING_KEYS=$MISSING_KEYS
DUPLICATE_KEYS=$DUPLICATE_KEYS
TOO_LONG_DB_NAME=$TOO_LONG_DB_NAME
NONEMPTY_KEY=$(printf '%q' "$NONEMPTY_KEY")
STATE_EOF
EOF

cat > "$BIN/mysqldump" <<'EOF'
#!/usr/bin/env bash
printf 'BACKUP\n' >> "${STUB_EVENTS:?}"
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

cat > "$BIN/goose" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GOOSE_LOG:?}"
exit 90
EOF

cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CURL_LOG:?}"
exit 91
EOF

chmod +x "$BIN"/*

cat > "$TEST_DIR/config.env" <<EOF
MYSQL_CLIENT_MODE=host
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_ROOT_USER=root
MYSQL_ROOT_PASSWORD=test-only-password
MYSQL_MASTER_DB=zatca_master
BACKUP_DIR=$TEST_DIR/backups
LOG_DIR=$TEST_DIR/logs
DEPLOY_STATE_DIR=$TEST_DIR/state
ZATCA_MASTER_MIGRATION_LOCK_FILE=$TEST_DIR/master.lock
EOF

reset_state() {
    cat > "$STATE" <<'EOF'
DB_EXISTS=0
TENANT_TABLE=0
BASELINE_COLUMNS=0
DB_NAME_INDEX_ROWS=0
DB_NAME_INDEX_VALID=0
TENANT_KEY_COLUMN=0
TENANT_KEY_NULLABLE=YES
TENANT_KEY_DEFAULT='<NULL>'
UNIQUE_INDEX_ROWS=0
UNIQUE_INDEX_VALID=0
DEFAULT_TRIGGER=0
DEFAULT_TRIGGER_VALID=0
IMMUTABLE_TRIGGER=0
IMMUTABLE_TRIGGER_VALID=0
MISSING_KEYS=0
DUPLICATE_KEYS=0
TOO_LONG_DB_NAME=0
NONEMPTY_KEY=''
EOF
    : > "$EVENTS"
    : > "$MYSQL_LOG"
    : > "$GOOSE_LOG"
    : > "$CURL_LOG"
    rm -rf "$TEST_DIR/backups" "$TEST_DIR/logs"
}

run_migration() {
    STUB_MYSQL_STATE="$STATE" \
    STUB_MYSQL_LOG="$MYSQL_LOG" \
    STUB_EVENTS="$EVENTS" \
    STUB_GOOSE_LOG="$GOOSE_LOG" \
    STUB_CURL_LOG="$CURL_LOG" \
    PATH="$BIN:$PATH" \
        bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
        >"$TEST_DIR/output" 2>&1
}

echo "=== syntax and deployctl command wiring ==="
bash -n scripts/migrate-zatca-master.sh
bash -n scripts/tests/test-migrate-zatca-master.sh
plan="$(bash scripts/deployctl.sh --plan db migrate-master --config "$TEST_DIR/config.env")"
[ "$plan" = "bash scripts/migrate-zatca-master.sh --config $TEST_DIR/config.env" ] ||
    fail "deployctl does not map db migrate-master to the orchestration script"
pass "syntax and deployctl command wiring"

echo
echo "=== failed MySQL preflight stops before backup ==="
reset_state
if STUB_PREFLIGHT_FAIL=1 run_migration; then
    fail "failed MySQL preflight was accepted"
fi
grep -q 'Deployment MySQL preflight failed' "$TEST_DIR/output" ||
    fail "preflight failure was not reported"
[ ! -e "$TEST_DIR/backups" ] ||
    fail "preflight failure created a backup"
pass "failed MySQL preflight stops before backup"

echo
echo "=== lock failure stops before schema changes ==="
reset_state
if STUB_FLOCK_FAIL=1 run_migration; then
    fail "lock contention was accepted"
fi
grep -q 'already running' "$TEST_DIR/output" ||
    fail "lock failure was not reported"
! grep -q '^SCHEMA_DDL$' "$EVENTS" ||
    fail "lock failure allowed schema changes"
pass "lock failure stops before schema changes"

echo
echo "=== fresh database is initialized directly after a verified backup ==="
reset_state
if ! run_migration; then
    cat "$TEST_DIR/output"
    fail "fresh registry migration failed"
fi
ls "$TEST_DIR/backups"/*.sql.gz >/dev/null 2>&1 ||
    fail "fresh registry migration did not create a backup"
grep -q 'CREATE DATABASE IF NOT EXISTS' "$MYSQL_LOG" ||
    fail "fresh migration did not create the master database"
grep -q 'CREATE TABLE IF NOT EXISTS' "$MYSQL_LOG" ||
    fail "fresh migration did not create the baseline tenant table"
grep -q 'tenant_key' "$MYSQL_LOG" ||
    fail "fresh migration did not create the tenant identity schema"
grep -q 'ADD UNIQUE KEY uq_tenant_key (tenant_key)' "$MYSQL_LOG" ||
    fail "fresh migration did not create the unique tenant_key index"
grep -q 'CREATE TRIGGER tenant_key_default' "$MYSQL_LOG" ||
    fail "fresh migration did not create the tenant_key default trigger"
grep -q 'SET NEW.tenant_key = NEW.db_name' "$MYSQL_LOG" ||
    fail "default trigger does not use db_name for an empty tenant_key"
grep -q 'CREATE TRIGGER tenant_key_immutable' "$MYSQL_LOG" ||
    fail "fresh migration did not create the tenant_key immutable trigger"
grep -q "SIGNAL SQLSTATE '45000'" "$MYSQL_LOG" ||
    fail "immutable trigger does not reject tenant_key changes"
[ ! -s "$GOOSE_LOG" ] || fail "migration invoked Goose"
[ ! -s "$CURL_LOG" ] || fail "migration downloaded a Goose or migration artifact"
backup_line="$(grep -n '^BACKUP$' "$EVENTS" | head -1 | cut -d: -f1)"
ddl_line="$(grep -n '^SCHEMA_DDL$' "$EVENTS" | head -1 | cut -d: -f1)"
[ -n "$backup_line" ] && [ -n "$ddl_line" ] && [ "$backup_line" -lt "$ddl_line" ] ||
    fail "schema DDL did not follow the verified backup"
pass "fresh database, backup ordering, and direct schema setup"

echo
echo "=== complete registry rerun performs no schema DDL ==="
reset_state
cat > "$STATE" <<'EOF'
DB_EXISTS=1
TENANT_TABLE=1
BASELINE_COLUMNS=7
DB_NAME_INDEX_ROWS=1
DB_NAME_INDEX_VALID=1
TENANT_KEY_COLUMN=1
TENANT_KEY_NULLABLE=NO
TENANT_KEY_DEFAULT=''
UNIQUE_INDEX_ROWS=1
UNIQUE_INDEX_VALID=1
DEFAULT_TRIGGER=1
DEFAULT_TRIGGER_VALID=1
IMMUTABLE_TRIGGER=1
IMMUTABLE_TRIGGER_VALID=1
MISSING_KEYS=0
DUPLICATE_KEYS=0
TOO_LONG_DB_NAME=0
NONEMPTY_KEY=stable-existing-key
EOF
if ! run_migration; then
    cat "$TEST_DIR/output"
    fail "complete registry rerun failed"
fi
! grep -q '^SCHEMA_DDL$' "$EVENTS" ||
    fail "complete registry rerun attempted schema DDL"
pass "complete registry rerun is idempotent"

echo
echo "=== partial registry backfills only missing tenant keys ==="
reset_state
cat > "$STATE" <<'EOF'
DB_EXISTS=1
TENANT_TABLE=1
BASELINE_COLUMNS=7
DB_NAME_INDEX_ROWS=1
DB_NAME_INDEX_VALID=1
TENANT_KEY_COLUMN=1
TENANT_KEY_NULLABLE=YES
TENANT_KEY_DEFAULT='<NULL>'
UNIQUE_INDEX_ROWS=0
UNIQUE_INDEX_VALID=0
DEFAULT_TRIGGER=0
DEFAULT_TRIGGER_VALID=0
IMMUTABLE_TRIGGER=0
IMMUTABLE_TRIGGER_VALID=0
MISSING_KEYS=2
DUPLICATE_KEYS=0
TOO_LONG_DB_NAME=0
NONEMPTY_KEY=stable-existing-key
EOF
if ! run_migration; then
    cat "$TEST_DIR/output"
    fail "compatible partial registry failed"
fi
grep -q "UPDATE tenant SET tenant_key=db_name WHERE tenant_key IS NULL OR tenant_key=''" "$MYSQL_LOG" ||
    fail "partial registry did not limit backfill to missing keys"
source "$STATE"
[ "$NONEMPTY_KEY" = "stable-existing-key" ] ||
    fail "partial registry overwrote a non-empty tenant key"
grep -q '^BACKFILL$' "$EVENTS" ||
    fail "partial registry did not backfill missing keys"
pass "partial registry backfills missing keys and preserves existing values"

echo
echo "=== duplicate tenant identity values fail before backfill ==="
reset_state
cat > "$STATE" <<'EOF'
DB_EXISTS=1
TENANT_TABLE=1
BASELINE_COLUMNS=7
DB_NAME_INDEX_ROWS=1
DB_NAME_INDEX_VALID=1
TENANT_KEY_COLUMN=1
TENANT_KEY_NULLABLE=YES
TENANT_KEY_DEFAULT='<NULL>'
UNIQUE_INDEX_ROWS=0
UNIQUE_INDEX_VALID=0
DEFAULT_TRIGGER=0
DEFAULT_TRIGGER_VALID=0
IMMUTABLE_TRIGGER=0
IMMUTABLE_TRIGGER_VALID=0
MISSING_KEYS=1
DUPLICATE_KEYS=1
TOO_LONG_DB_NAME=0
NONEMPTY_KEY=stable-existing-key
EOF
if run_migration; then
    fail "duplicate tenant identity values were accepted"
fi
grep -q 'would not be unique' "$TEST_DIR/output" ||
    fail "duplicate tenant identity failure was not explicit"
! grep -q '^BACKFILL$' "$EVENTS" ||
    fail "duplicate values were changed before the conflict was reported"
! grep -q 'Verified ZATCA master registry' "$TEST_DIR/output" ||
    fail "duplicate tenant identity values passed readiness verification"
pass "duplicate tenant identity values fail closed"

echo
echo "=== conflicting triggers and indexes fail closed ==="
reset_state
cat > "$STATE" <<'EOF'
DB_EXISTS=1
TENANT_TABLE=1
BASELINE_COLUMNS=7
DB_NAME_INDEX_ROWS=1
DB_NAME_INDEX_VALID=1
TENANT_KEY_COLUMN=1
TENANT_KEY_NULLABLE=NO
TENANT_KEY_DEFAULT=''
UNIQUE_INDEX_ROWS=0
UNIQUE_INDEX_VALID=0
DEFAULT_TRIGGER=1
DEFAULT_TRIGGER_VALID=0
IMMUTABLE_TRIGGER=0
IMMUTABLE_TRIGGER_VALID=0
MISSING_KEYS=0
DUPLICATE_KEYS=0
TOO_LONG_DB_NAME=0
NONEMPTY_KEY=stable-existing-key
EOF
if run_migration; then
    fail "incompatible tenant_key trigger was accepted"
fi
grep -q "trigger 'tenant_key_default' conflicts" "$TEST_DIR/output" ||
    fail "incompatible trigger failure was not explicit"
! grep -q 'Verified ZATCA master registry' "$TEST_DIR/output" ||
    fail "incompatible trigger passed readiness verification"

reset_state
cat > "$STATE" <<'EOF'
DB_EXISTS=1
TENANT_TABLE=1
BASELINE_COLUMNS=7
DB_NAME_INDEX_ROWS=1
DB_NAME_INDEX_VALID=1
TENANT_KEY_COLUMN=1
TENANT_KEY_NULLABLE=NO
TENANT_KEY_DEFAULT=''
UNIQUE_INDEX_ROWS=1
UNIQUE_INDEX_VALID=0
DEFAULT_TRIGGER=1
DEFAULT_TRIGGER_VALID=1
IMMUTABLE_TRIGGER=0
IMMUTABLE_TRIGGER_VALID=0
MISSING_KEYS=0
DUPLICATE_KEYS=0
TOO_LONG_DB_NAME=0
NONEMPTY_KEY=stable-existing-key
EOF
if run_migration; then
    fail "incompatible tenant_key index was accepted"
fi
grep -q "index 'uq_tenant_key' conflicts" "$TEST_DIR/output" ||
    fail "incompatible index failure was not explicit"
! grep -q 'Verified ZATCA master registry' "$TEST_DIR/output" ||
    fail "incompatible index passed readiness verification"
pass "incompatible tenant_key triggers and indexes fail closed"

echo
echo "ALL ZATCA MASTER MIGRATION TESTS PASSED"
