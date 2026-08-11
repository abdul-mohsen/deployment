#!/usr/bin/env bash
# =============================================================================
# prod-up.sh — Pull the latest dashboard image and restart the container.
#
# The image is built automatically by GitHub Actions on every push to main.
# No Go installation or docker build step required on the server.
#
# Usage:
#   bash prod-up.sh
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${DASHBOARD_IMAGE:-ssdawweq/dokku-dashboard:prod}"

echo "[+] Pulling latest image: $IMAGE"
docker pull "$IMAGE"

echo "[+] Recreating container..."
docker compose -f docker-compose.prod.yml up -d --force-recreate

echo ""
echo "[+] Verifying..."
sleep 2

CONTAINER="dokku-dashboard-prod"
STATUS=$(docker inspect "$CONTAINER" --format "{{.State.Status}}" 2>/dev/null || echo "not found")
CREATED=$(docker inspect "$CONTAINER" --format "{{.Created}}" 2>/dev/null || echo "-")
IMGID=$(docker inspect "$CONTAINER" --format "{{.Image}}" 2>/dev/null | cut -c1-20 || echo "-")

echo "    Container : $CONTAINER"
echo "    Status    : $STATUS"
echo "    Created   : $CREATED"
echo "    Image SHA : $IMGID..."

if [ "$STATUS" = "running" ]; then
    HEALTH=$(curl -sf http://127.0.0.1:8080/healthz 2>/dev/null || echo "unreachable")
    echo "    Healthz   : $HEALTH"
    echo ""
    echo "[+] Dashboard updated and running."
else
    echo ""
    echo "[!] Container is not running — check logs:"
    echo "    docker logs $CONTAINER"
    exit 1
fi
