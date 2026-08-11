#!/usr/bin/env bash
# =============================================================================
# update.sh — Update the deployment stack to the latest version.
#
# Pulls the latest code from Git, then pulls the latest pre-built dashboard
# image from Docker Hub and restarts the container.  That's it.
#
# Usage:
#   sudo bash /opt/deployment/update.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo " Deployment stack update"
echo "========================================"

# 1. Pull latest code
echo ""
echo "[1/2] Pulling latest deployment scripts..."
git -C "$SCRIPT_DIR" pull origin main

# 2. Update the dashboard (pull image + restart container)
echo ""
echo "[2/2] Updating dashboard..."
bash "${SCRIPT_DIR}/scripts/restart-stack.sh" --env prod --dashboard-only

echo ""
echo "========================================"
echo " Done."
echo "========================================"
