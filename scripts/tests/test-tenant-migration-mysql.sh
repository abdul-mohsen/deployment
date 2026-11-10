#!/usr/bin/env bash
# Run the real tenant initializer against a disposable MySQL container.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

IMAGE="${MIGRATION_TEST_IMAGE:-ssdawweq/ifritah-api:dev}"
CONTAINER="${MIGRATION_TEST_CONTAINER:-afrita-migration-test-$$}"
TMP_DIR="$(mktemp -d)"
CONFIG_FILE="$TMP_DIR/config.env"
FIRST_LOG="$TMP_DIR/first.log"
SECOND_LOG="$TMP_DIR/second.log"

cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "--- first migration log ---" >&2
        [ -f "$FIRST_LOG" ] && tail -80 "$FIRST_LOG" >&2 || true
        echo "--- second migration log ---" >&2
        [ -f "$SECOND_LOG" ] && tail -80 "$SECOND_LOG" >&2 || true
        docker logs "$CONTAINER" 2>&1 | tail -80 >&2 || true
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
    -e MYSQL_ROOT_PASSWORD=rootpass \
    -p 0:3306 \
    mysql:8.0 >/dev/null

ready=false
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" mysqladmin ping -uroot -prootpass --silent >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 2
done
$ready || {
    echo "MySQL container did not become ready." >&2
    exit 1
}

MYSQL_PORT="$(docker port "$CONTAINER" 3306/tcp | sed -E 's/.*://' | head -1)"
[ -n "$MYSQL_PORT" ] || {
    echo "Could not determine published MySQL port." >&2
    exit 1
}

docker exec "$CONTAINER" mysql -uroot -prootpass -e \
    "CREATE USER IF NOT EXISTS 'usr_acme'@'%' IDENTIFIED BY 'tenantpass';
     GRANT ALL PRIVILEGES ON tenant_acme.* TO 'usr_acme'@'%';
     FLUSH PRIVILEGES;" >/dev/null

cat > "$CONFIG_FILE" <<EOF
BASE_DOMAIN=test.example.com
MYSQL_ROOT_USER=root
MYSQL_ROOT_PASSWORD=rootpass
MYSQL_HOST=127.0.0.1
MYSQL_PORT=$MYSQL_PORT
TENANT_IMAGE_PULL_POLICY=never
EOF

COMMON_ARGS=(
    acme
    --schema-only
    --backend-image "$IMAGE"
    --config "$CONFIG_FILE"
    --env DB_HOST=127.0.0.1
    --env DB_PORT="$MYSQL_PORT"
    --env DB_USER=usr_acme
    --env DB_PASSWORD=tenantpass
)

echo "=== first migration run ==="
MYSQL_CLIENT_MODE=docker bash scripts/init-tenant-db.sh "${COMMON_ARGS[@]}" >"$FIRST_LOG" 2>&1
grep -q 'Migration applied:' "$FIRST_LOG" \
    || { tail -80 "$FIRST_LOG"; echo "No migration was recorded as applied." >&2; exit 1; }

echo "=== idempotent migration rerun ==="
MYSQL_CLIENT_MODE=docker bash scripts/init-tenant-db.sh "${COMMON_ARGS[@]}" >"$SECOND_LOG" 2>&1
grep -q 'Migration already applied:' "$SECOND_LOG" \
    || { tail -80 "$SECOND_LOG"; echo "Rerun did not use migration ledger." >&2; exit 1; }

echo "=== migration status ==="
STATUS_OUTPUT="$(
    MYSQL_CLIENT_MODE=docker bash scripts/init-tenant-db.sh acme \
        --status \
        --backend-image "$IMAGE" \
        --config "$CONFIG_FILE" \
        --env DB_HOST=127.0.0.1 \
        --env DB_PORT="$MYSQL_PORT" \
        --env DB_USER=usr_acme \
        --env DB_PASSWORD=tenantpass 2>&1
)"
echo "$STATUS_OUTPUT"
echo "$STATUS_OUTPUT" | grep -q 'schema_status=up_to_date' \
    || { echo "Migration status was not up_to_date." >&2; exit 1; }

echo "=== failed migration status ==="
docker exec "$CONTAINER" mysql -uroot -prootpass -e \
    "UPDATE tenant_acme.deployment_schema_migrations
     SET status='failed', error_message='fixture failure'
     WHERE migration_id='0005_purchase_bill_product_item_fields.sql';" >/dev/null
set +e
FAILED_STATUS_OUTPUT="$(
    MYSQL_CLIENT_MODE=docker bash scripts/init-tenant-db.sh acme \
        --status \
        --backend-image "$IMAGE" \
        --config "$CONFIG_FILE" \
        --env DB_HOST=127.0.0.1 \
        --env DB_PORT="$MYSQL_PORT" \
        --env DB_USER=usr_acme \
        --env DB_PASSWORD=tenantpass 2>&1
)"
FAILED_STATUS_RC=$?
set -e
echo "$FAILED_STATUS_OUTPUT"
[ "$FAILED_STATUS_RC" -ne 0 ] || {
    echo "Failed migration status returned zero." >&2
    exit 1
}
echo "$FAILED_STATUS_OUTPUT" | grep -q \
    'failed_migration=0005_purchase_bill_product_item_fields.sql status=failed' \
    || { echo "Failed migration file was not reported." >&2; exit 1; }
echo "$FAILED_STATUS_OUTPUT" | grep -q 'schema_status=failed' \
    || { echo "Failed migration status was not surfaced." >&2; exit 1; }

applied_count="$(docker exec "$CONTAINER" mysql -N -B -uroot -prootpass -e \
    "SELECT COUNT(*) FROM tenant_acme.deployment_schema_migrations WHERE status='applied';")"
[ "$applied_count" -gt 0 ] || {
    echo "Migration ledger has no applied rows." >&2
    exit 1
}

required_columns="$(docker exec "$CONTAINER" mysql -N -B -uroot -prootpass -e \
    "SELECT COUNT(*) FROM information_schema.columns
     WHERE table_schema='tenant_acme'
       AND table_name='purchase_bill_product'
       AND column_name IN ('cost_price', 'shelf_number');")"
[ "$required_columns" = "2" ] || {
    echo "Purchase-bill migration columns missing; found $required_columns." >&2
    exit 1
}

echo "REAL MYSQL MIGRATION TEST PASSED: applied=$applied_count required_columns=$required_columns"
