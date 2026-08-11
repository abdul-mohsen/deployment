#!/usr/bin/env bash
# =============================================================================
# prod-up.sh — Build the Linux binary and force a clean container rebuild.
#
# Usage:
#   bash prod-up.sh
#
# What it does:
#   1. Compiles a fresh Linux/amd64 static binary into bin/dashboard
#   2. Removes the existing local image so Docker can't reuse a stale layer
#   3. Rebuilds the image from scratch (--no-cache)
#   4. Recreates the container (--force-recreate)
#
# This guarantees the running container always uses the code from the current
# working directory — no stale cache, no surprise old binary.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

export GOOS=linux
export GOARCH=amd64
export CGO_ENABLED=0

echo "[+] Building dashboard binary..."
mkdir -p bin
go build -ldflags="-s -w" -trimpath -o bin/dashboard .
echo "[+] Binary built: $(du -sh bin/dashboard | cut -f1)"

# Remove the existing local image so --no-cache truly starts from scratch.
# Ignore errors if the image doesn't exist yet.
echo "[+] Removing old local image (if any)..."
docker image rm ssdawweq/dokku-dashboard:prod 2>/dev/null || true

echo "[+] Building Docker image (no cache)..."
docker compose -f docker-compose.prod.yml build --no-cache

echo "[+] Recreating container..."
docker compose -f docker-compose.prod.yml up -d --force-recreate

echo ""
echo "[+] Done. Verifying..."
sleep 2

CONTAINER="dokku-dashboard-prod"
STATUS=$(docker inspect "$CONTAINER" --format "{{.State.Status}}" 2>/dev/null || echo "not found")
CREATED=$(docker inspect "$CONTAINER" --format "{{.Created}}" 2>/dev/null || echo "-")
IMAGE=$(docker inspect "$CONTAINER" --format "{{.Image}}" 2>/dev/null | cut -c1-20 || echo "-")

echo "    Container : $CONTAINER"
echo "    Status    : $STATUS"
echo "    Created   : $CREATED"
echo "    Image SHA : $IMAGE..."

if [ "$STATUS" = "running" ]; then
    HEALTH=$(curl -sf http://127.0.0.1:8080/healthz 2>/dev/null || echo "unreachable")
    echo "    Healthz   : $HEALTH"
    echo ""
    echo "[+] Dashboard is running."
else
    echo ""
    echo "[!] Container is not running — check logs:"
    echo "    docker logs $CONTAINER"
    exit 1
fi
