#!/usr/bin/env bash
# Run the PR215 migration against disposable copies of a legacy registry and
# deployment-state database. Set MYSQL_REHEARSAL_DSN to a mysql:// DSN when a
# real MySQL server is available.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() {
    echo "PASS: $*"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

skip() {
    echo "SKIP: $*"
    exit 0
}

DSN="${MYSQL_REHEARSAL_DSN:-}"
[ -n "$DSN" ] || skip \
    "MYSQL_REHEARSAL_DSN is unavailable; set mysql://user:password@host[:port]/database to run the real rehearsal."

command -v mysql >/dev/null 2>&1 ||
    fail "MYSQL_REHEARSAL_DSN is set, but the mysql client is unavailable."

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

parse_dsn "$DSN"

suffix="$(printf '%s' "${GITHUB_RUN_ID:-$$-$(date +%s)}" | tr -cd '[:alnum:]_')"
[ -n "$suffix" ] || suffix="local"
MYSQL_MASTER_DB="pr215_legacy_${suffix}"
DEPLOY_STATE_DB="pr215_state_${suffix}"
MYSQL_CLIENT_MODE=host
export MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD MYSQL_HOST MYSQL_PORT
export MYSQL_MASTER_DB DEPLOY_STATE_DB MYSQL_CLIENT_MODE

source scripts/lib.sh

cleanup() {
    local rc=$?
    set +e
    if declare -F run_mysql >/dev/null 2>&1; then
        run_mysql -e \
            "DROP DATABASE IF EXISTS \`${DEPLOY_STATE_DB}\`;
             DROP DATABASE IF EXISTS \`${MYSQL_MASTER_DB}\`;" \
            >/dev/null 2>&1
    fi
    exit "$rc"
}
trap cleanup EXIT

run_mysql -N -B -e "SELECT 1;" >/dev/null 2>&1 ||
    fail "MYSQL_REHEARSAL_DSN is configured, but the MySQL server is unreachable."

run_mysql <<SQL
CREATE DATABASE \`${MYSQL_MASTER_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
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
