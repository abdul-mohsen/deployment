#!/usr/bin/env bash
# =============================================================================
# update.sh — Update the deployment stack to the latest version.
#
# Run this on the server whenever you want to pick up code changes:
#
#   sudo bash /opt/deployment/update.sh
#
# What it does:
#   1. git pull origin main   (get the latest scripts + Dockerfile + vendor/)
#   2. Build or pull the latest dashboard Docker image
#   3. Stop the old container, start the new one
#   4. Verify the dashboard is healthy at http://127.0.0.1:8080
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo " Deployment stack update"
echo "========================================"

# 1. Pull latest code (includes updated Dockerfile, vendor/, scripts)
echo ""
echo "[1/2] Pulling latest code..."
git -C "$SCRIPT_DIR" pull origin main

# 2. Rebuild dashboard image and restart container
echo ""
echo "[2/2] Updating dashboard..."
bash "${SCRIPT_DIR}/scripts/restart-stack.sh" --env prod --dashboard-only

echo ""
echo "========================================"
echo " Update complete."
echo " Dashboard: http://127.0.0.1:8080"
echo "========================================"
