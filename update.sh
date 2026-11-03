#!/usr/bin/env bash
# =============================================================================
# update.sh — Update the deployment stack to the latest version.
#
# Pulls the latest code from Git, then validates and pulls the matching
# pre-built dashboard image before replacing the running container.
#
# Usage:
#   sudo bash /opt/deployment/update.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"
deployment_init_logging

echo "========================================"
echo " Deployment stack update"
echo "========================================"

# 1. Pull latest code
echo ""
echo "[1/2] Pulling latest deployment scripts..."
deployment_log INFO "updating deployment checkout"
branch="$(git -C "$SCRIPT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ "$branch" != "main" ]; then
    echo "[x] Deployment checkout must be on main (found '${branch:-detached}')." >&2
    exit 1
fi
git -C "$SCRIPT_DIR" fetch origin main
git -C "$SCRIPT_DIR" merge --ff-only origin/main
revision="$(git -C "$SCRIPT_DIR" rev-parse --verify HEAD)"
echo "[+] Deployment revision: $revision"
deployment_log INFO "deployment checkout updated revision=$revision"

# 2. Update the dashboard. prod-up.sh validates the image/script revision
# before stopping the current container, so a publication lag cannot cause an
# avoidable dashboard outage.
echo ""
echo "[2/2] Updating dashboard..."
deployment_log INFO "updating production dashboard"
bash "${SCRIPT_DIR}/dashboard/prod-up.sh"

echo ""
echo "========================================"
echo " Done."
echo "========================================"
