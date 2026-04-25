#!/usr/bin/env bash
# =============================================================================
# update-tenant.sh — Update a tenant's app images or config
# =============================================================================
# Usage:
#   ./scripts/update-tenant.sh <tenant-name> [options]
#
# Options:
#   --backend-image <image>    Deploy new backend image
#   --frontend-image <image>   Deploy new frontend image
#   --env KEY=VALUE            Set/update env var (repeatable)
#   --restart                  Restart all tenant containers
#   --scale <n>                Scale backend to n instances
#   --config <path>            Path to config.env file (default: ../config.env)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse --config early
CONFIG_FILE="$PROJECT_DIR/config.env"
for i in $(seq 1 $#); do
    if [ "${!i}" = "--config" ]; then
        j=$((i+1))
        CONFIG_FILE="${!j}"
        break
    fi
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

TENANT_NAME=""
BACKEND_IMAGE=""
FRONTEND_IMAGE=""
RESTART=false
SCALE=""
declare -a ENV_VARS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend-image)  BACKEND_IMAGE="$2"; shift 2 ;;
        --frontend-image) FRONTEND_IMAGE="$2"; shift 2 ;;
        --env)            ENV_VARS+=("$2"); shift 2 ;;
        --restart)        RESTART=true; shift ;;
        --scale)          SCALE="$2"; shift 2 ;;
        --config)         shift 2 ;;  # already parsed above
        -*)               error "Unknown option: $1"; exit 1 ;;
        *)                [ -z "$TENANT_NAME" ] && TENANT_NAME="$1"; shift ;;
    esac
done

if [ -z "$TENANT_NAME" ]; then
    echo "Usage: $0 <tenant-name> [options]"
    exit 1
fi

BACKEND_APP="${TENANT_NAME}-backend"
FRONTEND_APP="${TENANT_NAME}-frontend"

# ---- Set env vars ----
for ev in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    if [[ "$ev" == *"="* ]]; then
        log "Setting env: $ev"
        dokku config:set --no-restart "$BACKEND_APP" "$ev"
    fi
done

# ---- Deploy new images ----
if [ -n "$BACKEND_IMAGE" ]; then
    log "Deploying backend: $BACKEND_IMAGE"
    dokku git:from-image "$BACKEND_APP" "$BACKEND_IMAGE"
fi

if [ -n "$FRONTEND_IMAGE" ]; then
    log "Deploying frontend: $FRONTEND_IMAGE"
    dokku git:from-image "$FRONTEND_APP" "$FRONTEND_IMAGE"
fi

# ---- Scale ----
if [ -n "$SCALE" ]; then
    log "Scaling backend to $SCALE instances"
    dokku ps:scale "$BACKEND_APP" web="$SCALE"
fi

# ---- Restart ----
if $RESTART; then
    log "Restarting tenant..."
    dokku ps:restart "$BACKEND_APP"
    dokku ps:restart "$FRONTEND_APP"
fi

log "Done. Check status: dokku ps:report $BACKEND_APP"
