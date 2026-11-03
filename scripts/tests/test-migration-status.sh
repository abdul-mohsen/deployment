#!/usr/bin/env bash
# Verify migration-status.sh reports all-tenant schema drift.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    exec)
        printf '%s\n' "acme-backend" "hockun-backend"
        ;;
    ps)
        echo "cid"
        ;;
    inspect)
        echo "ssdawweq/ifritah-api:dev"
        ;;
esac
EOF

cat > "$TMP_DIR/init-status.sh" <<'EOF'
#!/usr/bin/env bash
tenant="$1"
if [ "$tenant" = "hockun" ]; then
    printf 'tenant=hockun\nimage=ssdawweq/ifritah-api:dev\nfailed_migration=0005_purchase_bill_product_item_fields.sql status=failed\nschema_status=failed\n'
    exit 1
fi
printf 'tenant=acme\nimage=ssdawweq/ifritah-api:dev\napplied_migration=0001_auth_tables.sql\nschema_status=up_to_date\n'
EOF

cat > "$TMP_DIR/config.env" <<'EOF'
BASE_DOMAIN=test.example.com
MYSQL_ROOT_PASSWORD=rootpass
TENANT_IMAGE_PULL_POLICY=never
EOF

chmod +x "$TMP_DIR/docker" "$TMP_DIR/init-status.sh"
export PATH="$TMP_DIR:$PATH"
export MIGRATION_STATUS_INIT_SCRIPT="$TMP_DIR/init-status.sh"
export DOKKU_CONTAINER=dokku-test

if bash scripts/migration-status.sh --json --config "$TMP_DIR/config.env" >"$TMP_DIR/status.json"; then
    fail "failed tenant status returned zero"
fi

grep -q '"tenant":"acme"' "$TMP_DIR/status.json" || fail "healthy tenant missing"
grep -q '"schema_status":"up_to_date"' "$TMP_DIR/status.json" || fail "healthy status missing"
grep -q '"tenant":"hockun"' "$TMP_DIR/status.json" || fail "failed tenant missing"
grep -q '"schema_status":"failed"' "$TMP_DIR/status.json" || fail "failed status missing"
grep -q '0005_purchase_bill_product_item_fields.sql' "$TMP_DIR/status.json" \
    || fail "failed migration filename missing"
pass "all-tenant JSON migration status reports schema drift"

echo
echo "ALL MIGRATION STATUS TESTS PASSED"
