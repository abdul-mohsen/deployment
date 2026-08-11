#!/usr/bin/env bash
# =============================================================================
# dev-up.sh — Build the dashboard image locally and restart the dev container.
#
# Builds from source (multi-stage Dockerfile — no Go installation needed).
# Forces a clean rebuild: removes the old image so no layer is reused.
#
# Usage (from anywhere):
#   bash /opt/deployment/dashboard/dev-up.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.dev.yml"
IMAGE="ssdawweq/dokku-dashboard:dev"

echo "[+] Removing old local image to bust layer cache..."
docker image rm "$IMAGE" 2>/dev/null || true

echo "[+] Building image from source (multi-stage — Go compiles inside Docker)..."
docker compose -f "$COMPOSE_FILE" build --no-cache

echo "[+] Starting container..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo ""
echo "[+] Done. Dashboard at http://localhost:8088"
