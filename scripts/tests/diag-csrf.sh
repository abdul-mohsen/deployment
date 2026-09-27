#!/usr/bin/env bash
# =============================================================================
# scripts/tests/diag-csrf.sh — one-off: is /api/v2/register's 403 CSRF from
# the frontend proxy or the backend?
# =============================================================================
# Hits the backend container directly (bypassing frontend), and hits it via
# the tenant frontend for comparison. Prints both responses so we know which
# layer is enforcing CSRF.
#
# Usage:
#   sudo bash scripts/tests/diag-csrf.sh <tenant-name>
# =============================================================================
set -euo pipefail

TENANT="${1:?tenant name required}"
BE_APP="${TENANT}-backend"
PAYLOAD='{"username":"admin","email":"a@a.local","password":"BillTest12345","full_name":"Test","phone":""}'

DOKKU_CONTAINER="${DOKKU_CONTAINER:-dokku}"

echo "=== 1) backend container id ==="
BE_ID="$(docker exec "$DOKKU_CONTAINER" dokku ps:report "$BE_APP" 2>/dev/null \
    | awk -F: '/Container id/{gsub(/ /,"",$2); print $2}' | head -1)"
echo "backend container: ${BE_ID:-<none>}"

if [ -z "$BE_ID" ]; then
    echo "backend container not running — nothing to compare"
    exit 1
fi

echo ""
echo "=== 2) POST /api/v2/register directly to backend (bypasses frontend proxy) ==="
docker exec "$BE_ID" sh -c "wget -qSO- \
    --post-data='$PAYLOAD' \
    --header='Content-Type: application/json' \
    http://localhost:8090/api/v2/register 2>&1; echo; echo EXIT=\$?"

echo ""
echo "=== 3) POST /api/v2/register via Dokku nginx + frontend proxy (what init-tenant-db does) ==="
DOKKU_PORT="$(docker port "$DOKKU_CONTAINER" 80/tcp | awk -F: 'NR==1{print $NF}')"
curl -sS -w '\nSTATUS=%{http_code}\n' \
    -H "Host: ${TENANT}.$(docker exec "$DOKKU_CONTAINER" dokku domains:report --global 2>/dev/null | awk -F': ' '/Domains global vhosts:/ {print $2; exit}' | awk '{print $1}')" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" \
    "http://127.0.0.1:${DOKKU_PORT}/api/v2/register"

echo ""
echo "=== done ==="
