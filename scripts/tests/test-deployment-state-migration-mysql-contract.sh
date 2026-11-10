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

echo "=== cleanup drops only databases created by this run ==="
source scripts/lib.sh
source scripts/tests/test-deployment-state-migration-mysql.sh

MYSQL_MASTER_DB=owned_master
DEPLOY_STATE_DB=preexisting_state
REHEARSAL_MASTER_DB_CREATED=false
REHEARSAL_STATE_DB_CREATED=false
DROPPED_DATABASES=()

run_mysql() {
    local args="$*"
    if [[ "$args" == *"information_schema.schemata"* ]]; then
        if [[ "$args" == *"schema_name='preexisting_state'"* ]]; then
            printf '1\n'
        else
            printf '0\n'
        fi
        return 0
    fi
    if [[ "$args" == *"DROP DATABASE"* ]]; then
        if [[ "$args" == *"\`owned_master\`"* ]]; then
            DROPPED_DATABASES+=("owned_master")
        elif [[ "$args" == *"\`preexisting_state\`"* ]]; then
            DROPPED_DATABASES+=("preexisting_state")
        fi
    fi
}

create_rehearsal_database \
    "$DEPLOY_STATE_DB" "deployment state" REHEARSAL_STATE_DB_CREATED
create_rehearsal_database \
    "$MYSQL_MASTER_DB" "legacy registry" REHEARSAL_MASTER_DB_CREATED
cleanup_owned_databases

[ "$REHEARSAL_STATE_DB_CREATED" = false ] ||
    fail "pre-existing deployment-state database was marked as owned"
[ "$REHEARSAL_MASTER_DB_CREATED" = true ] ||
    fail "new legacy registry database was not marked as owned"
[ "${#DROPPED_DATABASES[@]}" -eq 1 ] ||
    fail "cleanup did not drop exactly one owned database"
[ "${DROPPED_DATABASES[0]}" = owned_master ] ||
    fail "cleanup dropped a pre-existing database"
pass "pre-existing databases survive cleanup while owned databases are removed"

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
