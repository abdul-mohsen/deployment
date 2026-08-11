#!/usr/bin/env bash
# =============================================================================
# prod-up.sh — Build the dashboard image from source and restart the container.
#
# Builds entirely inside Docker (multi-stage Dockerfile with vendored deps).
# No Go installation needed on the server. No internet access needed for Go.
#
# Once GitHub Actions is pushing to Docker Hub, this script will automatically
# use `docker pull` instead of building locally (controlled by DASHBOARD_IMAGE).
#
# Usage (from anywhere on the server):
#   sudo bash /opt/deployment/dashboard/prod-up.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.prod.yml"
CONTAINER="dokku-dashboard-prod"
IMAGE="${DASHBOARD_IMAGE:-ssdawweq/dokku-dashboard:prod}"

# Try to pull a pre-built image from Docker Hub first.
# If the repo doesn't exist or pull fails, build from source instead.
if docker pull "$IMAGE" 2>/dev/null; then
    echo "[+] Using pre-built image from Docker Hub: $IMAGE"
else
    echo "[+] No pre-built image found — building from source (this takes ~1-2 min)..."
    echo "    (All dependencies are vendored — no internet needed)"

    # Remove any old local image so Docker cannot reuse stale layers.
    docker image rm "$IMAGE" 2>/dev/null || true

    docker build \
        --no-cache \
        --tag "$IMAGE" \
        "$SCRIPT_DIR"
fi

echo "[+] Stopping old container (if running)..."
docker stop "$CONTAINER" 2>/dev/null || true
docker rm   "$CONTAINER" 2>/dev/null || true

echo "[+] Starting new container..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo ""
echo "[+] Verifying..."
sleep 3

STATUS=$(docker inspect "$CONTAINER" --format "{{.State.Status}}" 2>/dev/null || echo "not found")
IMAGE_ID=$(docker inspect "$CONTAINER" --format "{{.Image}}" 2>/dev/null | cut -c1-20 || echo "-")

echo "    Container : $CONTAINER"
echo "    Status    : $STATUS"
echo "    Image SHA : $IMAGE_ID..."

if [ "$STATUS" = "running" ]; then
    HEALTH=$(curl -sf http://127.0.0.1:8080/healthz 2>/dev/null || echo "unreachable")
    echo "    Healthz   : $HEALTH"
    echo ""
    echo "[+] Dashboard updated and running at http://127.0.0.1:8080"
else
    echo ""
    echo "[!] Container is not running — check logs:"
    echo "    docker logs $CONTAINER"
    exit 1
fi
