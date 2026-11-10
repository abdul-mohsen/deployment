#!/usr/bin/env bash
# Run the PR215 migration against disposable copies of a legacy registry and
# deployment-state database. Set MYSQL_REHEARSAL_DSN to a mysql:// DSN when a
# real MySQL server is available.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REHEARSAL_RESERVED_DATABASES=()
REHEARSAL_OWNED_DATABASES=()

pass() {
    echo "PASS: $*"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

skip() {
    echo "SKIP: $*"
}

rehearsal_database_name_nonce() {
    local nonce="${MYSQL_REHEARSAL_NONCE:-}"
    if [ -z "$nonce" ]; then
        nonce="${GITHUB_RUN_ID:-local}_${GITHUB_RUN_ATTEMPT:-1}_$$_$(date -u +%s%N)_${RANDOM:-0}"
    fi
    nonce="$(printf '%s' "$nonce" | tr -cd '[:alnum:]_')"
    [ -n "$nonce" ] || nonce="local"
    printf '%s' "${nonce:0:32}"
}

generate_rehearsal_database_name() {
    local kind="$1" attempt="$2" nonce
    nonce="${REHEARSAL_NAME_NONCE:-}"
    [ -n "$nonce" ] || nonce="$(rehearsal_database_name_nonce)"
    nonce="$(printf '%s' "$nonce" | tr -cd '[:alnum:]_')"
    [ -n "$nonce" ] || nonce="local"
    nonce="${nonce:0:32}"
    printf '%s_%s_%s_%s' "pr215" "$kind" "$nonce" "$attempt"
}

rehearsal_database_reserved() {
    local database="$1" reserved
    for reserved in "${REHEARSAL_RESERVED_DATABASES[@]-}"; do
        [ "$reserved" = "$database" ] && return 0
    done
    return 1
}

rehearsal_database_owned() {
    local database="$1" owned
    for owned in "${REHEARSAL_OWNED_DATABASES[@]-}"; do
        [ "$owned" = "$database" ] && return 0
    done
    return 1
}

record_rehearsal_database() {
    local database="$1" ownership_variable="$2"
    REHEARSAL_RESERVED_DATABASES+=("$database")
    REHEARSAL_OWNED_DATABASES+=("$database")
    printf -v "$ownership_variable" '%s' true
}

parse_dsn() {
    local raw="$1" authority credentials hostport

    case "$raw" in
        mysql://*)
            raw="${raw#mysql://}"
            raw="${raw%%\?*}"
            authority="${raw%%/*}"
            ;;
        *)
            fail "MYSQL_REHEARSAL_DSN must use mysql://user:password@host[:port]/database."
            ;;
    esac

    [[ "$authority" == *@* ]] ||
        fail "MYSQL_REHEARSAL_DSN must include user and password credentials."
    credentials="${authority%@*}"
    hostport="${authority#*@}"
    [ -n "$credentials" ] || fail "MYSQL_REHEARSAL_DSN has an empty user."
    [ -n "$hostport" ] || fail "MYSQL_REHEARSAL_DSN has an empty host."

    MYSQL_ADMIN_USER="${credentials%%:*}"
    MYSQL_ADMIN_PASSWORD="${credentials#*:}"
    [ "$MYSQL_ADMIN_USER" != "$credentials" ] ||
        fail "MYSQL_REHEARSAL_DSN must include a password after the user."
    [ -n "$MYSQL_ADMIN_USER" ] || fail "MYSQL_REHEARSAL_DSN has an empty user."
    [ -n "$MYSQL_ADMIN_PASSWORD" ] ||
        fail "MYSQL_REHEARSAL_DSN has an empty password."

    MYSQL_HOST="$hostport"
    MYSQL_PORT="${MYSQL_REHEARSAL_PORT:-3306}"
    if [[ "$hostport" == \[*\]:* ]]; then
        MYSQL_HOST="${hostport%%\]:*}]"
        MYSQL_HOST="${MYSQL_HOST#[}"
        MYSQL_PORT="${hostport##*\]:}"
    elif [[ "$hostport" == *:* ]]; then
        MYSQL_HOST="${hostport%:*}"
        MYSQL_PORT="${hostport##*:}"
    fi
    [[ "$MYSQL_PORT" =~ ^[0-9]+$ ]] ||
        fail "MYSQL_REHEARSAL_DSN has an invalid port."
}

database_exists() {
    local database="$1" count
    validate_database_identifier "$database" || return 1
    if ! count="$(run_mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${database}';")"; then
        return 2
    fi
    count="$(printf '%s\n' "$count" | awk 'NF { print $1; exit }')"
    case "$count" in
        0) return 1 ;;
        1) return 0 ;;
        *)
            printf 'Could not determine whether rehearsal database %q exists.\n' \
                "$database" >&2
            return 2
            ;;
    esac
}

create_rehearsal_database() {
    local kind="$1" description="$2" database_variable="$3"
    local ownership_variable="$4" max_attempts attempt database exists_rc create_rc

    max_attempts="${MYSQL_REHEARSAL_MAX_NAME_ATTEMPTS:-32}"
    [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || {
        printf 'MYSQL_REHEARSAL_MAX_NAME_ATTEMPTS must be a positive integer.\n' >&2
        return 1
    }

    attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        database="$(generate_rehearsal_database_name "$kind" "$attempt")" || return 1
        validate_database_identifier "$database" || return 1

        if rehearsal_database_reserved "$database"; then
            attempt=$((attempt + 1))
            continue
        fi

        if database_exists "$database"; then
            echo "Skipping pre-existing ${description} candidate '${database}'; generating another name."
            attempt=$((attempt + 1))
            continue
        else
            exists_rc=$?
            if [ "$exists_rc" -ne 1 ]; then
                printf 'Unable to verify that rehearsal database %q is absent.\n' \
                    "$database" >&2
                return 1
            fi
        fi

        if run_mysql -e \
            "CREATE DATABASE \`${database}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
            printf -v "$database_variable" '%s' "$database"
            record_rehearsal_database "$database" "$ownership_variable"
            echo "Created ${description} database '${database}'; cleanup owns it."
            return 0
        else
            create_rc=$?
        fi

        if database_exists "$database"; then
            echo "Rehearsal database candidate '${database}' appeared before creation; generating another name."
            attempt=$((attempt + 1))
            continue
        else
            exists_rc=$?
        fi
        if [ "$exists_rc" -eq 1 ]; then
            return "$create_rc"
        fi
        printf 'Unable to verify the failed rehearsal database creation for %q.\n' \
            "$database" >&2
        return "$create_rc"
    done

    printf 'Unable to allocate a unique %s rehearsal database after %s attempts.\n' \
        "$description" "$max_attempts" >&2
    return 1
}

cleanup_owned_databases() {
    if ! declare -F run_mysql >/dev/null 2>&1; then
        return 0
    fi

    local database
    for database in "${REHEARSAL_OWNED_DATABASES[@]-}"; do
        [ -n "$database" ] || continue
        run_mysql -e "DROP DATABASE IF EXISTS \`${database}\`;" >/dev/null 2>&1
    done

    # Keep the flags as a compatibility fallback for callers that initialize
    # ownership explicitly rather than through create_rehearsal_database.
    if [ "${REHEARSAL_STATE_DB_CREATED:-false}" = true ] &&
        ! rehearsal_database_owned "${DEPLOY_STATE_DB:-}"; then
        run_mysql -e "DROP DATABASE IF EXISTS \`${DEPLOY_STATE_DB}\`;" >/dev/null 2>&1
    fi
    if [ "${REHEARSAL_MASTER_DB_CREATED:-false}" = true ] &&
        ! rehearsal_database_owned "${MYSQL_MASTER_DB:-}"; then
        run_mysql -e "DROP DATABASE IF EXISTS \`${MYSQL_MASTER_DB}\`;" >/dev/null 2>&1
    fi
}

cleanup() {
    local rc=$?
    set +e
    cleanup_owned_databases
    exit "$rc"
}

main() {
    cd "$REPO_DIR"

    local dsn
    dsn="${MYSQL_REHEARSAL_DSN:-}"
    if [ -z "$dsn" ]; then
        skip \
            "MYSQL_REHEARSAL_DSN is unavailable; this check is skipped and provides no real MySQL rehearsal evidence."
        return 0
    fi

    command -v mysql >/dev/null 2>&1 ||
        fail "MYSQL_REHEARSAL_DSN is set, but the mysql client is unavailable."

    parse_dsn "$dsn"

    MYSQL_CLIENT_MODE=host
    REHEARSAL_MASTER_DB_CREATED=false
    REHEARSAL_STATE_DB_CREATED=false
    REHEARSAL_RESERVED_DATABASES=()
    REHEARSAL_OWNED_DATABASES=()
    REHEARSAL_NAME_NONCE="$(rehearsal_database_name_nonce)"
    MYSQL_MASTER_DB=""
    DEPLOY_STATE_DB=""
    source scripts/lib.sh
    export MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD MYSQL_HOST MYSQL_PORT
    export MYSQL_MASTER_DB DEPLOY_STATE_DB MYSQL_CLIENT_MODE

    trap cleanup EXIT

    run_mysql -N -B -e "SELECT 1;" >/dev/null 2>&1 ||
        fail "MYSQL_REHEARSAL_DSN is configured, but the MySQL server is unreachable."

    create_rehearsal_database \
        legacy "legacy registry" MYSQL_MASTER_DB REHEARSAL_MASTER_DB_CREATED
    create_rehearsal_database \
        state "deployment state" DEPLOY_STATE_DB REHEARSAL_STATE_DB_CREATED

    run_mysql <<SQL
CREATE TABLE \`${MYSQL_MASTER_DB}\`.tenant (
    name                       VARCHAR(100) NOT NULL PRIMARY KEY,
    db_name                    VARCHAR(128) NOT NULL DEFAULT '',
    backend_image              VARCHAR(255) NOT NULL DEFAULT '',
    frontend_image             VARCHAR(255) NOT NULL DEFAULT '',
    backend_image_ref          VARCHAR(512) NOT NULL DEFAULT '',
    backend_image_digest       VARCHAR(255) NOT NULL DEFAULT '',
    backend_channel            VARCHAR(64) NOT NULL DEFAULT '',
    backend_version            VARCHAR(128) NOT NULL DEFAULT '',
    backend_commit             VARCHAR(128) NOT NULL DEFAULT '',
    backend_commit_short       VARCHAR(32) NOT NULL DEFAULT '',
    backend_workflow_run       VARCHAR(128) NOT NULL DEFAULT '',
    backend_workflow_run_url   VARCHAR(512) NOT NULL DEFAULT '',
    backend_built_at           VARCHAR(64) NOT NULL DEFAULT '',
    backend_deployed_at        TIMESTAMP NULL DEFAULT NULL,
    backend_deployment_status  VARCHAR(32) NOT NULL DEFAULT 'unknown',
    backend_deployment_error   TEXT NULL,
    frontend_image_ref         VARCHAR(512) NOT NULL DEFAULT '',
    frontend_image_digest      VARCHAR(255) NOT NULL DEFAULT '',
    frontend_channel            VARCHAR(64) NOT NULL DEFAULT '',
    frontend_version            VARCHAR(128) NOT NULL DEFAULT '',
    frontend_commit             VARCHAR(128) NOT NULL DEFAULT '',
    frontend_commit_short      VARCHAR(32) NOT NULL DEFAULT '',
    frontend_workflow_run      VARCHAR(128) NOT NULL DEFAULT '',
    frontend_workflow_run_url  VARCHAR(512) NOT NULL DEFAULT '',
    frontend_built_at           VARCHAR(64) NOT NULL DEFAULT '',
    frontend_deployed_at        TIMESTAMP NULL DEFAULT NULL,
    frontend_deployment_status VARCHAR(32) NOT NULL DEFAULT 'unknown',
    frontend_deployment_error  TEXT NULL
) ENGINE=InnoDB;
INSERT INTO \`${MYSQL_MASTER_DB}\`.tenant (
    name, db_name, backend_image, frontend_image,
    backend_image_ref, backend_image_digest, backend_channel, backend_version,
    backend_commit, backend_commit_short, backend_workflow_run,
    backend_workflow_run_url, backend_built_at, backend_deployed_at,
    backend_deployment_status, backend_deployment_error,
    frontend_image_ref, frontend_image_digest, frontend_channel, frontend_version,
    frontend_commit, frontend_commit_short, frontend_workflow_run,
    frontend_workflow_run_url, frontend_built_at, frontend_deployed_at,
    frontend_deployment_status, frontend_deployment_error
) VALUES
    (
        'legacy-only', 'tenant_legacy_only', 'legacy/backend:v1',
        'legacy/frontend:v1', 'legacy/backend:v1@sha256:legacy-backend',
        'sha256:legacy-backend', 'release', 'v1.0.0', 'legacy-backend-commit',
        'legacy-b', '100', 'https://example.test/legacy/100',
        '2026-11-09T10:00:00Z', '2026-11-09 10:00:00', 'deployed', '',
        'legacy/frontend:v1@sha256:legacy-frontend', 'sha256:legacy-frontend',
        'release', 'v1.0.0', 'legacy-frontend-commit', 'legacy-f',
        '101', 'https://example.test/legacy/101', '2026-11-09T10:01:00Z',
        '2026-11-09 10:01:00', 'deployed', ''
    ),
    (
        'preserve-me', 'tenant_preserve_me', 'legacy/backend:old',
        'legacy/frontend:old', 'legacy/backend:old@sha256:old-backend',
        'sha256:old-backend', 'release', 'v0.9.0', 'old-backend-commit',
        'old-b', '90', 'https://example.test/legacy/90',
        '2026-11-08T10:00:00Z', '2026-11-08 10:00:00', 'deployed', '',
        'legacy/frontend:old@sha256:old-frontend', 'sha256:old-frontend',
        'release', 'v0.9.0', 'old-frontend-commit', 'old-f',
        '91', 'https://example.test/legacy/91', '2026-11-08T10:01:00Z',
        '2026-11-08 10:01:00', 'deployed', ''
    ),
    (
        'explicit-unpinned', 'tenant_explicit_unpinned', 'legacy/backend:old',
        'legacy/frontend:old', 'legacy/backend:old@sha256:old-backend',
        'sha256:old-backend', 'release', 'v0.9.0', 'old-backend-commit',
        'old-b', '90', 'https://example.test/legacy/90',
        '2026-11-08T10:00:00Z', '2026-11-08 10:00:00', 'deployed', '',
        'legacy/frontend:old@sha256:old-frontend', 'sha256:old-frontend',
        'release', 'v0.9.0', 'old-frontend-commit', 'old-f',
        '91', 'https://example.test/legacy/91', '2026-11-08T10:01:00Z',
        '2026-11-08 10:01:00', 'deployed', ''
    );
SQL

scalar() {
    run_mysql -N -B "$DEPLOY_STATE_DB" -e "$1" | awk 'NF { print; exit }'
}

assert_scalar() {
    local expected="$1" query="$2" description="$3" actual
    actual="$(scalar "$query")"
    [ "$actual" = "$expected" ] ||
        fail "$description (expected '$expected', got '$actual')"
}

echo "=== first run creates state tables before copying the legacy registry ==="
ensure_deployment_state_schema
assert_scalar 3 \
    "SELECT COUNT(*) FROM \`${DEPLOY_STATE_DB}\`.tenant_image;" \
    "first run did not copy every legacy pin"
assert_scalar 1 \
    "SELECT COUNT(*) FROM \`${DEPLOY_STATE_DB}\`.tenant_identity WHERE name='legacy-only';" \
    "first run did not copy legacy provenance"
pass "schema creation precedes the real legacy-state copy"

run_mysql <<SQL
UPDATE \`${DEPLOY_STATE_DB}\`.tenant_image
SET backend_image='current/backend:pinned', frontend_image='current/frontend:pinned'
WHERE name='preserve-me';
UPDATE \`${DEPLOY_STATE_DB}\`.tenant_image
SET backend_image='', frontend_image=''
WHERE name='explicit-unpinned';
UPDATE \`${DEPLOY_STATE_DB}\`.tenant_identity
SET backend_image_ref='current/backend:pinned@sha256:current',
    backend_image_digest='sha256:current',
    backend_deployment_status='deployed'
WHERE name='preserve-me';
SQL

echo "=== rerun preserves deployment-owned pins and identity ==="
ensure_deployment_state_schema
assert_scalar 'current/backend:pinned' \
    "SELECT backend_image FROM \`${DEPLOY_STATE_DB}\`.tenant_image WHERE name='preserve-me';" \
    "rerun replaced the current backend pin"
assert_scalar 'current/frontend:pinned' \
    "SELECT frontend_image FROM \`${DEPLOY_STATE_DB}\`.tenant_image WHERE name='preserve-me';" \
    "rerun replaced the current frontend pin"
assert_scalar '' \
    "SELECT backend_image FROM \`${DEPLOY_STATE_DB}\`.tenant_image WHERE name='explicit-unpinned';" \
    "rerun replaced an explicit backend unpin"
assert_scalar 'current/backend:pinned@sha256:current' \
    "SELECT backend_image_ref FROM \`${DEPLOY_STATE_DB}\`.tenant_identity WHERE name='preserve-me';" \
    "rerun replaced current provenance"
assert_scalar 'legacy/backend:v1' \
    "SELECT backend_image FROM \`${DEPLOY_STATE_DB}\`.tenant_image WHERE name='legacy-only';" \
    "rerun lost a legacy pin"
assert_scalar 3 \
    "SELECT COUNT(*) FROM \`${MYSQL_MASTER_DB}\`.tenant;" \
    "migration modified the legacy registry copy"
pass "existing pins, explicit unpins, provenance, and legacy rows survive"

echo "=== failed copy rolls back both state inserts ==="
run_mysql <<SQL
INSERT INTO \`${MYSQL_MASTER_DB}\`.tenant (
    name, db_name, backend_image, frontend_image
) VALUES ('rollback-only', 'tenant_rollback_only', 'rollback/backend:v1',
          'rollback/frontend:v1');
ALTER TABLE \`${DEPLOY_STATE_DB}\`.tenant_identity
    DROP COLUMN frontend_deployment_error;
SQL

if ensure_deployment_state_schema >/dev/null 2>&1; then
    fail "migration unexpectedly succeeded after the provenance schema was damaged"
fi
assert_scalar 0 \
    "SELECT COUNT(*) FROM \`${DEPLOY_STATE_DB}\`.tenant_image WHERE name='rollback-only';" \
    "failed migration left a partially inserted pin"
assert_scalar 'current/backend:pinned' \
    "SELECT backend_image FROM \`${DEPLOY_STATE_DB}\`.tenant_image WHERE name='preserve-me';" \
    "failed migration changed an existing pin"
assert_scalar '' \
    "SELECT backend_image FROM \`${DEPLOY_STATE_DB}\`.tenant_image WHERE name='explicit-unpinned';" \
    "failed migration changed an explicit unpin"
assert_scalar 4 \
    "SELECT COUNT(*) FROM \`${MYSQL_MASTER_DB}\`.tenant;" \
    "failed migration changed the legacy registry copy"
pass "failed migration leaves no partial state and preserves rollback inputs"

echo "REAL MYSQL PR215 REHEARSAL PASSED"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
