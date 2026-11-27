#!/usr/bin/env bash
# Regression tests for:
#   1. Canonical tenant DB naming (tenant_db_name, tenant_db_prefix, resolve_zatca_tenant_db_prefix)
#   2. Compose/script wiring for TENANT_NAME_PREFIX and TENANT_DB_PREFIX
#   3. restart-stack.sh starting dashboards before ZATCA daemon and keeping
#      dashboards running if ZATCA fails readiness (fail-fast exit non-zero)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $*" >&2; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "=== 1. Canonical tenant DB naming & ZATCA prefix resolution ==="
OUT="$(bash -c '
set -euo pipefail
source scripts/lib.sh

TENANT_NAME_PREFIX=""
[ "$(tenant_db_name acme)" = "tenant_acme" ]
[ "$(tenant_db_name my-shop)" = "tenant_my_shop" ]

TENANT_NAME_PREFIX="dev-"
[ "$(tenant_db_name acme)" = "tenant_dev_acme" ]
[ "$(tenant_db_name dev-acme)" = "tenant_dev_acme" ]
[ "$(tenant_db_name my-shop)" = "tenant_dev_my_shop" ]

TENANT_NAME_PREFIX="prod-"
[ "$(tenant_db_name acme)" = "tenant_prod_acme" ]
[ "$(tenant_db_name prod-acme)" = "tenant_prod_acme" ]

# 64-character MySQL identifier limit guard ("tenant_" = 7 chars; 58-char tenant -> 65 chars -> reject)
TENANT_NAME_PREFIX=""
long_name="$(printf "a%.0s" $(seq 1 58))"
if tenant_db_name "$long_name" >/dev/null 2>&1; then
    echo "OVERLONG_DB_ACCEPTED"
    exit 1
fi

[ "$(tenant_db_prefix dev)" = "tenant_dev_" ]
[ "$(tenant_db_prefix dev-)" = "tenant_dev_" ]
[ "$(tenant_db_prefix DEV-)" = "tenant_dev_" ]
[ "$(tenant_db_prefix prod-)" = "tenant_prod_" ]
[ "$(tenant_db_prefix qa-2-)" = "tenant_qa_2_" ]
[ -z "$(tenant_db_prefix "")" ]

[ "$(resolve_zatca_tenant_db_prefix "" "dev-")" = "tenant_dev_" ]
[ "$(resolve_zatca_tenant_db_prefix "tenant_dev_" "dev-")" = "tenant_dev_" ]
[ "$(resolve_zatca_tenant_db_prefix "tenant_prod_" "")" = "tenant_prod_" ]
[ -z "$(resolve_zatca_tenant_db_prefix "" "")" ]

if resolve_zatca_tenant_db_prefix "tenant_prod_" "dev-" >/dev/null 2>&1; then
    echo "CONFLICT_ACCEPTED"
    exit 1
fi
if resolve_zatca_tenant_db_prefix "tenant-bad" "" >/dev/null 2>&1; then
    echo "BAD_DB_PREFIX_ACCEPTED"
    exit 1
fi
if resolve_zatca_tenant_db_prefix "" "---" >/dev/null 2>&1; then
    echo "BAD_NAME_PREFIX_ACCEPTED"
    exit 1
fi
if resolve_zatca_tenant_db_prefix "" "dev--2" >/dev/null 2>&1; then
    echo "DOUBLE_HYPHEN_ACCEPTED"
    exit 1
fi
echo "CANONICAL_OK"
')"
if echo "$OUT" | grep -q '^CANONICAL_OK$'; then
    pass "tenant_db_name, tenant_db_prefix, and resolve_zatca_tenant_db_prefix enforce canonical formula and fail closed"
else
    echo "$OUT"
    fail "canonical tenant DB / prefix helpers failed"
fi

echo
echo "=== 2. Tenant scripts & Compose files wire canonical DB naming and prefixes ==="
for f in \
    scripts/create-tenant.sh \
    scripts/init-tenant-db.sh \
    scripts/remove-tenant.sh \
    scripts/cleanup-broken-tenant.sh \
    scripts/backup-tenant.sh \
    scripts/restore-tenant.sh; do
    if grep -q 'tenant_db_name' "$f"; then
        pass "$f derives database name via tenant_db_name"
    else
        fail "$f must derive database name via tenant_db_name"
    fi
done

if grep -q 'MySQL .* \${TENANT_DB_NAME} on' scripts/create-tenant.sh \
    && ! grep -q 'MySQL .* tenant_\${TENANT_NAME} on' scripts/create-tenant.sh; then
    pass "create-tenant.sh displays normalized TENANT_DB_NAME in provisioning plan"
else
    fail "create-tenant.sh provisioning plan must display TENANT_DB_NAME instead of raw tenant_\${TENANT_NAME}"
fi

if grep -q 'TENANT_NAME_PREFIX: \${TENANT_NAME_PREFIX:-}' dashboard/docker-compose.dev.yml \
    && grep -q 'TENANT_NAME_PREFIX: \${TENANT_NAME_PREFIX:-}' dashboard/docker-compose.zatca.yml \
    && grep -q 'TENANT_DB_PREFIX: \${TENANT_DB_PREFIX:-}' dashboard/docker-compose.zatca.yml; then
    pass "Compose overlays forward TENANT_NAME_PREFIX and TENANT_DB_PREFIX"
else
    fail "Compose overlays must forward TENANT_NAME_PREFIX and TENANT_DB_PREFIX"
fi

echo
echo "=== 3. restart-stack.sh starts dashboards before ZATCA and keeps dashboards up on ZATCA failure ==="
STUB_BIN="$TMP_DIR/bin"
ISOLATED_REPO="$TMP_DIR/repo"
STATE_FILE="$TMP_DIR/dokku.state"
DASH_STATE_FILE="$TMP_DIR/dash.state"
TRACE_FILE="$TMP_DIR/restart.trace"
mkdir -p "$STUB_BIN" "$ISOLATED_REPO/scripts" "$ISOLATED_REPO/dashboard"

cp scripts/restart-stack.sh scripts/lib.sh "$ISOLATED_REPO/scripts/"
cat > "$ISOLATED_REPO/config.env" <<'CFG'
ZATCA_DAEMON_ENABLED=1
ZATCA_DAEMON_CONTAINER=zatca-daemon
DOKKU_PORT=18082
CFG
cat > "$ISOLATED_REPO/dashboard/docker-compose.dev.yml" <<'YML'
services:
  dashboard:
    image: stub
YML
cat > "$ISOLATED_REPO/dashboard/dev-up.sh" <<'DEVUP'
#!/usr/bin/env bash
echo running > "${DASH_STATE_FILE:?}"
echo "dashboard:dev:start" >> "${TRACE_FILE:?}"
DEVUP
chmod +x "$ISOLATED_REPO/dashboard/dev-up.sh"

cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
state_file="${STATE_FILE:?}"
dash_state_file="${DASH_STATE_FILE:?}"
trace_file="${TRACE_FILE:?}"
state="$(cat "$state_file" 2>/dev/null || echo absent)"
dash_state="$(cat "$dash_state_file" 2>/dev/null || echo stopped)"
case "$1" in
    compose)
        if [[ "$*" == *" down "* ]]; then
            echo stopped > "$dash_state_file"
            echo "dashboard:dev:stop" >> "$trace_file"
        fi
        exit 0 ;;
    ps)
        if [[ "$*" == *"--format {{.Names}}"* || "$*" == *"--format '{{.Names}}'"* ]]; then
            if [[ "$*" == *"-a"* ]]; then
                [ "$state" != absent ] && echo dokku
                [ "$dash_state" = running ] && echo dokku-dashboard-dev
            else
                [ "$state" = running ] && echo dokku
                [ "$dash_state" = running ] && echo dokku-dashboard-dev
            fi
        else
            printf 'NAMES\tSTATUS\tPORTS\n'
            printf 'dokku\tUp 5s\t0.0.0.0:18082->80/tcp\n'
            [ "$dash_state" = running ] && printf 'dokku-dashboard-dev\tUp 4s\t127.0.0.1:19000->9000/tcp\n'
            printf 'zatca-daemon\tUp 2s (healthy)\t127.0.0.1:4222->4222/tcp\n'
        fi
        exit 0 ;;
    stop)
        echo "dokku:stop" >> "$trace_file"
        echo stopped > "$state_file"
        exit 0 ;;
    inspect)
        if [[ "$*" == *"80/tcp"* ]]; then
            echo 18082
        fi
        exit 0 ;;
    start)
        echo "dokku:start" >> "$trace_file"
        echo running > "$state_file"
        exit 0 ;;
    exec)
        if [ "$2" = dokku ] && [ "$3" = dokku ] && [ "$4" = version ]; then
            echo "dokku version stub"
        fi
        exit 0 ;;
    logs)
        echo "stub zatca failure log"
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/docker"

# 3a. ZATCA failure leaves dashboard started while exiting non-zero
cat > "$ISOLATED_REPO/scripts/setup-zatca-daemon.sh" <<'ZATCAFAIL'
#!/usr/bin/env bash
echo "zatca:start:fail" >> "${TRACE_FILE:?}"
exit 1
ZATCAFAIL
chmod +x "$ISOLATED_REPO/scripts/setup-zatca-daemon.sh"

echo running > "$STATE_FILE"
echo running > "$DASH_STATE_FILE"
: > "$TRACE_FILE"
set +e
OUT="$(STATE_FILE="$STATE_FILE" DASH_STATE_FILE="$DASH_STATE_FILE" TRACE_FILE="$TRACE_FILE" PATH="$STUB_BIN:$PATH" bash "$ISOLATED_REPO/scripts/restart-stack.sh" --env dev 2>&1)"
RC=$?
set -e
TRACE_ONE_LINE="$(paste -sd ',' "$TRACE_FILE")"
if [ "$RC" -ne 0 ] \
    && [ "$(cat "$DASH_STATE_FILE")" = "running" ] \
    && echo "$OUT" | grep -q 'Dokku and dashboard containers remain running' \
    && [ "$TRACE_ONE_LINE" = "dashboard:dev:stop,dokku:stop,dokku:start,dashboard:dev:start,zatca:start:fail" ]; then
    pass "restart-stack starts dashboard before ZATCA and fails fast while keeping dashboard running"
else
    echo "RC=$RC DASH=$(cat "$DASH_STATE_FILE") TRACE=$TRACE_ONE_LINE"
    echo "$OUT"
    fail "restart-stack ZATCA failure order/contract failed"
fi

# 3b. ZATCA success completes in expected order and includes zatca-daemon in status table
cat > "$ISOLATED_REPO/scripts/setup-zatca-daemon.sh" <<'ZATCAOK'
#!/usr/bin/env bash
echo "zatca:start:ok" >> "${TRACE_FILE:?}"
exit 0
ZATCAOK
chmod +x "$ISOLATED_REPO/scripts/setup-zatca-daemon.sh"

echo running > "$STATE_FILE"
echo running > "$DASH_STATE_FILE"
: > "$TRACE_FILE"
OUT="$(STATE_FILE="$STATE_FILE" DASH_STATE_FILE="$DASH_STATE_FILE" TRACE_FILE="$TRACE_FILE" PATH="$STUB_BIN:$PATH" bash "$ISOLATED_REPO/scripts/restart-stack.sh" --env dev 2>&1)"
TRACE_ONE_LINE="$(paste -sd ',' "$TRACE_FILE")"
if [ "$TRACE_ONE_LINE" = "dashboard:dev:stop,dokku:stop,dokku:start,dashboard:dev:start,zatca:start:ok" ] \
    && echo "$OUT" | grep -q 'dokku-dashboard-dev' \
    && echo "$OUT" | grep -q 'zatca-daemon'; then
    pass "restart-stack starts dashboard then ZATCA and lists both in final status"
else
    echo "TRACE=$TRACE_ONE_LINE"
    echo "$OUT"
    fail "restart-stack happy-path order or status table failed"
fi

echo
echo "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
