#!/usr/bin/env bash
# =============================================================================
# set-tenant-image.sh — Pin a tenant to a specific image (or unpin)
# =============================================================================
# When pinned, auto-pull.sh and deploy-all.sh will SKIP this tenant during
# global deploys. Use update-tenant.sh to deploy a new image to a pinned tenant.
#
# Usage:
#   ./scripts/set-tenant-image.sh <tenant> --backend <image>
#   ./scripts/set-tenant-image.sh <tenant> --frontend <image>
#   ./scripts/set-tenant-image.sh <tenant> --unpin                # remove all pins
#   ./scripts/set-tenant-image.sh --list                          # show all pins
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

TENANT=""
BACKEND_IMG=""
FRONTEND_IMG=""
UNPIN=false
LIST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)  BACKEND_IMG="$2"; shift 2 ;;
        --frontend) FRONTEND_IMG="$2"; shift 2 ;;
        --unpin)    UNPIN=true; shift ;;
        --list)     LIST=true; shift ;;
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        -*)         error "Unknown option: $1"; exit 1 ;;
        *)          [ -z "$TENANT" ] && TENANT="$1"; shift ;;
    esac
done

if $LIST; then
    run_mysql -t "$MYSQL_MASTER_DB" -e \
        "SELECT name, backend_image, frontend_image, enabled FROM tenant ORDER BY name;"
    exit 0
fi

if [ -z "$TENANT" ]; then
    echo "Usage: $0 <tenant> [--backend <image>] [--frontend <image>] [--unpin]"
    echo "       $0 --list"
    exit 1
fi

if $UNPIN; then
    log "Unpinning ${TENANT} (will follow global image)"
    run_mysql "$MYSQL_MASTER_DB" -e \
        "UPDATE tenant SET backend_image='', frontend_image='' WHERE name='${TENANT}';"
    exit 0
fi

if [ -n "$BACKEND_IMG" ]; then
    log "Pinning ${TENANT} backend → ${BACKEND_IMG}"
    run_mysql "$MYSQL_MASTER_DB" -e \
        "UPDATE tenant SET backend_image='${BACKEND_IMG}' WHERE name='${TENANT}';"
fi

if [ -n "$FRONTEND_IMG" ]; then
    log "Pinning ${TENANT} frontend → ${FRONTEND_IMG}"
    run_mysql "$MYSQL_MASTER_DB" -e \
        "UPDATE tenant SET frontend_image='${FRONTEND_IMG}' WHERE name='${TENANT}';"
fi

log "Done. Use update-tenant.sh to apply the pinned image."
