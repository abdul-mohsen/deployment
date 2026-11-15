#!/usr/bin/env bash
# Disposable MySQL 8 integration test for the ZATCA master registry migration.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker is required for this disposable MySQL test"
docker version >/dev/null 2>&1 || fail "Docker daemon is unavailable"
if command -v openssl >/dev/null 2>&1; then
    MYSQL_TEST_PASSWORD="$(openssl rand -hex 24)"
elif command -v python3 >/dev/null 2>&1; then
    MYSQL_TEST_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
else
    fail "openssl or python3 is required to generate an ephemeral MySQL password"
fi

TEST_DIR="$REPO_DIR/.test-migrate-zatca-master-mysql.$$"
MYSQL_CONTAINER="zatca-master-mysql-test-$$"
MYSQL_IMAGE="${MYSQL_TEST_IMAGE:-mysql:8.0}"
mkdir -p "$TEST_DIR"
trap 'docker rm --force "$MYSQL_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$TEST_DIR"' EXIT

if ! docker run --detach --rm --name "$MYSQL_CONTAINER" --network bridge \
    --env "MYSQL_ROOT_PASSWORD=$MYSQL_TEST_PASSWORD" \
    --env MYSQL_ROOT_HOST='%' "$MYSQL_IMAGE" >"$TEST_DIR/container-id"; then
    fail "could not start disposable MySQL 8 container"
fi

ready=false
for ((attempt = 1; attempt <= 90; attempt++)); do
    if docker exec --env "MYSQL_PWD=$MYSQL_TEST_PASSWORD" "$MYSQL_CONTAINER" \
        mysqladmin --protocol=TCP -h 127.0.0.1 -u root ping --silent \
        >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done
if ! $ready; then
    docker logs "$MYSQL_CONTAINER" >"$TEST_DIR/container.log" 2>&1 || true
    cat "$TEST_DIR/container.log"
    fail "disposable MySQL did not become ready"
fi

MYSQL_HOST="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MYSQL_CONTAINER")"
[ -n "$MYSQL_HOST" ] || fail "could not resolve disposable MySQL container address"

cat > "$TEST_DIR/config.env" <<EOF
MYSQL_CLIENT_MODE=docker
MYSQL_HOST=$MYSQL_HOST
MYSQL_PORT=3306
MYSQL_ROOT_USER=root
MYSQL_MASTER_DB=zatca_master
BACKUP_DIR=$TEST_DIR/backups
DEPLOY_STATE_DIR=$TEST_DIR/state
ZATCA_MASTER_MIGRATION_LOCK_FILE=$TEST_DIR/master.lock
EOF

mysql_exec() {
    docker run --rm --network bridge \
        --env "MYSQL_PWD=$MYSQL_TEST_PASSWORD" \
        "$MYSQL_IMAGE" mysql --protocol=TCP -h "$MYSQL_HOST" -P 3306 -u root -N -B "$@"
}

run_migration() {
    local database="$1"
    if ! MYSQL_ROOT_PASSWORD="$MYSQL_TEST_PASSWORD" \
        bash scripts/migrate-zatca-master.sh --config "$TEST_DIR/config.env" \
        --master-db "$database" >"$TEST_DIR/migration.log" 2>&1; then
        cat "$TEST_DIR/migration.log"
        fail "migration failed for $database"
    fi
}

assert_value() {
    local expected="$1" actual="$2" message="$3"
    [ "$actual" = "$expected" ] || fail "$message (expected '$expected', got '$actual')"
}

echo "=== clean registry and identity behaviors ==="
run_migration zatca_master
assert_value tenant_alpha \
    "$(mysql_exec -e "INSERT INTO zatca_master.tenant (name, db_name) VALUES ('Alpha','tenant_alpha'); SELECT tenant_key FROM zatca_master.tenant WHERE db_name='tenant_alpha';")" \
    "insert default did not use db_name"
mysql_exec -e "INSERT INTO zatca_master.tenant (name, db_name, tenant_key) VALUES ('Beta','tenant_beta','custom-key');"
assert_value custom-key \
    "$(mysql_exec -e "SELECT tenant_key FROM zatca_master.tenant WHERE db_name='tenant_beta';")" \
    "explicit tenant_key was not preserved"

if mysql_exec -e "INSERT INTO zatca_master.tenant (name, db_name, tenant_key) VALUES ('Duplicate','tenant_duplicate','custom-key');" \
    >"$TEST_DIR/duplicate.log" 2>&1; then
    fail "duplicate tenant_key was accepted"
fi
grep -q 'Duplicate entry' "$TEST_DIR/duplicate.log" ||
    fail "duplicate tenant_key did not produce a unique-index error"

if mysql_exec -e "UPDATE zatca_master.tenant SET tenant_key='changed-key' WHERE db_name='tenant_beta';" \
    >"$TEST_DIR/immutable.log" 2>&1; then
    fail "tenant_key update was accepted"
fi
grep -q 'tenant_key is immutable' "$TEST_DIR/immutable.log" ||
    fail "tenant_key update did not report the immutable-trigger error"
mysql_exec -e "UPDATE zatca_master.tenant SET name='Alpha updated' WHERE db_name='tenant_alpha';"

run_migration zatca_master
assert_value tenant_alpha \
    "$(mysql_exec -e "SELECT tenant_key FROM zatca_master.tenant WHERE db_name='tenant_alpha';")" \
    "complete rerun changed an existing tenant_key"
assert_value custom-key \
    "$(mysql_exec -e "SELECT tenant_key FROM zatca_master.tenant WHERE db_name='tenant_beta';")" \
    "complete rerun changed a non-empty tenant_key"
pass "clean schema, defaulting, uniqueness, immutability, and complete rerun"

echo
echo "=== existing nullable column is completed without replacing keys ==="
mysql_exec -e "CREATE DATABASE zatca_master_partial CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql_exec -e "
CREATE TABLE zatca_master_partial.tenant (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(100)  NOT NULL,
    db_name     VARCHAR(100)  NOT NULL UNIQUE,
    zatca_env   VARCHAR(20)   NOT NULL DEFAULT 'production',
    alert_email VARCHAR(255)  NOT NULL DEFAULT '',
    enabled     TINYINT(1)    NOT NULL DEFAULT 1,
    created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_enabled (enabled)
) ENGINE=InnoDB;
ALTER TABLE zatca_master_partial.tenant
    ADD COLUMN tenant_key VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin NULL AFTER db_name;
INSERT INTO zatca_master_partial.tenant (name, db_name, tenant_key)
VALUES ('Preserved','tenant_preserved','custom-preserved'),
       ('Missing','tenant_missing',NULL);
"
run_migration zatca_master_partial
assert_value custom-preserved \
    "$(mysql_exec -e "SELECT tenant_key FROM zatca_master_partial.tenant WHERE db_name='tenant_preserved';")" \
    "partial migration changed a non-empty tenant_key"
assert_value tenant_missing \
    "$(mysql_exec -e "SELECT tenant_key FROM zatca_master_partial.tenant WHERE db_name='tenant_missing';")" \
    "partial migration did not backfill a missing tenant_key"
pass "partial migration preserves non-empty keys and backfills missing keys"

echo
echo "ALL DISPOSABLE MYSQL MIGRATION TESTS PASSED"
