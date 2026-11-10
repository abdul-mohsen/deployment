#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "=== missing DSN is an explicit skip, not rehearsal evidence ==="
missing_dsn_output="$(env -u MYSQL_REHEARSAL_DSN \
    bash scripts/tests/test-deployment-state-migration-mysql.sh 2>&1)"
grep -Fq \
    'SKIP: MYSQL_REHEARSAL_DSN is unavailable; this check is skipped' \
    <<<"$missing_dsn_output" ||
    fail "missing MYSQL_REHEARSAL_DSN was not reported as skipped"
if grep -Fq 'REAL MYSQL PR215 REHEARSAL PASSED' <<<"$missing_dsn_output"; then
    fail "missing MYSQL_REHEARSAL_DSN produced rehearsal evidence"
fi
pass "missing MYSQL_REHEARSAL_DSN is not reported as a passing rehearsal"

echo "=== pre-existing candidates are skipped and never mutated or dropped ==="
source scripts/lib.sh
source scripts/tests/test-deployment-state-migration-mysql.sh

REHEARSAL_NAME_NONCE=collision
MYSQL_REHEARSAL_MAX_NAME_ATTEMPTS=4
MYSQL_MASTER_DB=
DEPLOY_STATE_DB=
REHEARSAL_MASTER_DB_CREATED=false
REHEARSAL_STATE_DB_CREATED=false
REHEARSAL_RESERVED_DATABASES=()
REHEARSAL_OWNED_DATABASES=()
CREATED_DATABASES=()
DROPPED_DATABASES=()

run_mysql() {
    local args="$*"
    if [[ "$args" == *"information_schema.schemata"* ]]; then
        if [[ "$args" == *"schema_name='pr215_legacy_collision_0'"* ]]; then
            printf '1\n'
        else
            printf '0\n'
        fi
        return 0
    fi
    if [[ "$args" == *"CREATE DATABASE"* ]]; then
        if [[ "$args" == *"\`pr215_legacy_collision_0\`"* ]]; then
            fail "pre-existing database candidate was mutated"
        fi
        if [[ "$args" == *"\`pr215_legacy_collision_1\`"* ]]; then
            CREATED_DATABASES+=("pr215_legacy_collision_1")
        elif [[ "$args" == *"\`pr215_state_collision_0\`"* ]]; then
            CREATED_DATABASES+=("pr215_state_collision_0")
        else
            fail "unexpected database candidate was created: $args"
        fi
        return 0
    fi
    if [[ "$args" == *"DROP DATABASE"* ]]; then
        if [[ "$args" == *"\`pr215_legacy_collision_1\`"* ]]; then
            DROPPED_DATABASES+=("pr215_legacy_collision_1")
        elif [[ "$args" == *"\`pr215_state_collision_0\`"* ]]; then
            DROPPED_DATABASES+=("pr215_state_collision_0")
        elif [[ "$args" == *"\`pr215_legacy_collision_0\`"* ]]; then
            fail "cleanup dropped a pre-existing database"
        fi
    fi
}

create_rehearsal_database \
    legacy "legacy registry" MYSQL_MASTER_DB REHEARSAL_MASTER_DB_CREATED
create_rehearsal_database \
    state "deployment state" DEPLOY_STATE_DB REHEARSAL_STATE_DB_CREATED
cleanup_owned_databases

[ "$MYSQL_MASTER_DB" = pr215_legacy_collision_1 ] ||
    fail "pre-existing legacy candidate was reused instead of replaced"
[ "$DEPLOY_STATE_DB" = pr215_state_collision_0 ] ||
    fail "state database did not receive a unique candidate"
[ "$REHEARSAL_MASTER_DB_CREATED" = true ] ||
    fail "new legacy registry database was not marked as owned"
[ "$REHEARSAL_STATE_DB_CREATED" = true ] ||
    fail "new deployment-state database was not marked as owned"
[ "${#CREATED_DATABASES[@]}" -eq 2 ] ||
    fail "rehearsal did not create exactly two new databases"
[ "${#DROPPED_DATABASES[@]}" -eq 2 ] ||
    fail "cleanup did not drop exactly two owned databases"
pass "pre-existing candidates survive while only newly created databases are removed"

echo "=== existence-check failures fail closed before CREATE DATABASE ==="
REHEARSAL_NAME_NONCE=unavailable
REHEARSAL_RESERVED_DATABASES=()
REHEARSAL_OWNED_DATABASES=()
MYSQL_MASTER_DB=
REHEARSAL_MASTER_DB_CREATED=false
CREATE_ATTEMPTED=false
run_mysql() {
    local args="$*"
    if [[ "$args" == *"information_schema.schemata"* ]]; then
        return 1
    fi
    if [[ "$args" == *"CREATE DATABASE"* ]]; then
        CREATE_ATTEMPTED=true
    fi
    return 0
}
if create_rehearsal_database \
    legacy "legacy registry" MYSQL_MASTER_DB REHEARSAL_MASTER_DB_CREATED; then
    fail "rehearsal continued after the existence check failed"
fi
[ "$CREATE_ATTEMPTED" = false ] ||
    fail "rehearsal attempted CREATE DATABASE without an existence result"
pass "existence-check failures prevent unsafe database creation"

echo "=== workflow skips the rehearsal when its secret is unavailable ==="
workflow=.github/workflows/tests.yml
grep -Fq 'id: mysql-rehearsal' "$workflow" ||
    fail "workflow lacks a MySQL rehearsal availability check"
grep -Fq "available=false" "$workflow" ||
    fail "workflow does not report an unavailable MySQL rehearsal"
grep -Fq "if: steps.mysql-rehearsal.outputs.available == 'true'" "$workflow" ||
    fail "workflow does not skip the rehearsal when its DSN is unavailable"
pass "workflow distinguishes unavailable MySQL rehearsal from proof"

echo "ALL MYSQL REHEARSAL CONTRACT TESTS PASSED"
