#!/usr/bin/env bash
# =============================================================================
# post-merge-cleanup.sh — apply PR #41 fixes to existing tenants on a host
# =============================================================================
# What it does (idempotent):
#   1. Removes any leftover broken /api nginx snippets in
#      /home/dokku/<frontend>/nginx.conf.d/api-proxy.conf inside the dokku
#      container. These reference <backend>-web:<port> which doesn't resolve
#      from Dokku's nginx context and break `nginx:validate-config`.
#   2. For every tenant pair (<name>-backend / <name>-frontend), creates
#      tenant-<name> docker network (if missing) and attaches both apps.
#   3. Sets BACKEND_URL / PORT / APP_DOMAIN on the frontend, BASEURL on the
#      backend, then `ps:rebuild`s both apps so the new wiring is applied.
#   4. Validates Dokku nginx config and rebuilds proxy config.
#
# Usage:
#   sudo bash scripts/post-merge-cleanup.sh                 # all tenants
#   sudo bash scripts/post-merge-cleanup.sh qa-7k4m foo     # specific tenants
#
# Env overrides: DOKKU_CONTAINER (default: dokku), BACKEND_PORT (8090),
#                FRONTEND_PORT (8000), BASEURL (/api/v2), BASE_DOMAIN, DRY_RUN=1
# =============================================================================

set -euo pipefail

DOKKU_CONTAINER="${DOKKU_CONTAINER:-dokku}"
BACKEND_PORT="${BACKEND_PORT:-8090}"
FRONTEND_PORT="${FRONTEND_PORT:-8000}"
BASEURL="${BASEURL:-/api/v2}"
DRY_RUN="${DRY_RUN:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Try to source config.env for BASE_DOMAIN if not provided
if [ -z "${BASE_DOMAIN:-}" ] && [ -f "$PROJECT_DIR/config.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/config.env"
fi
BASE_DOMAIN="${BASE_DOMAIN:?BASE_DOMAIN not set (in env or $PROJECT_DIR/config.env)}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/post-merge-cleanup-$(date +%Y%m%d-%H%M%S).log"
if [ -w "$LOG_DIR" ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Logging to: $LOG_FILE"
fi

dk() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] docker exec $DOKKU_CONTAINER $*"
        return 0
    fi
    docker exec "$DOKKU_CONTAINER" "$@"
}

dk_dokku() { dk dokku "$@"; }

# Tenant list: from CLI args, else derive from `dokku apps:list`
declare -a TENANTS=()
if [ $# -gt 0 ]; then
    TENANTS=("$@")
else
    log "Discovering tenants from 'dokku apps:list'..."
    while IFS= read -r app; do
        case "$app" in
            *-frontend) TENANTS+=("${app%-frontend}") ;;
        esac
    done < <(dk_dokku apps:list 2>/dev/null | tail -n +2)
fi

if [ ${#TENANTS[@]} -eq 0 ]; then
    warn "No tenants found. Exiting."
    exit 0
fi

log "Tenants to process: ${TENANTS[*]}"

# ---------------------------------------------------------------------------
# 1. Remove broken /api nginx snippets across every frontend app
# ---------------------------------------------------------------------------
log "Removing leftover api-proxy.conf snippets..."
for t in "${TENANTS[@]}"; do
    fe="${t}-frontend"
    snippet="/home/dokku/${fe}/nginx.conf.d/api-proxy.conf"
    if dk test -f "$snippet" 2>/dev/null; then
        info "  removing $snippet"
        dk rm -f "$snippet" || warn "  failed to remove $snippet"
    fi
done

# ---------------------------------------------------------------------------
# 2-3. Per-tenant: network, env, rebuild
# ---------------------------------------------------------------------------
for t in "${TENANTS[@]}"; do
    be="${t}-backend"; fe="${t}-frontend"
    net="tenant-${t}"
    domain="${t}.${BASE_DOMAIN}"

    log "=== ${t} ==="

    # Skip if either app is missing
    if ! dk_dokku apps:exists "$be" >/dev/null 2>&1; then
        warn "  $be does not exist; skipping"
        continue
    fi
    if ! dk_dokku apps:exists "$fe" >/dev/null 2>&1; then
        warn "  $fe does not exist; skipping"
        continue
    fi

    info "  network: $net"
    dk_dokku network:create "$net" >/dev/null 2>&1 || true
    dk_dokku network:set "$be" attach-post-create "$net" >/dev/null
    dk_dokku network:set "$be" attach-post-deploy "$net" >/dev/null
    dk_dokku network:set "$fe" attach-post-create "$net" >/dev/null
    dk_dokku network:set "$fe" attach-post-deploy "$net" >/dev/null

    info "  config: backend BASEURL=$BASEURL"
    dk_dokku config:set --no-restart "$be" BASEURL="$BASEURL" >/dev/null

    info "  config: frontend BACKEND_URL=http://${be}.web:${BACKEND_PORT}"
    dk_dokku config:set --no-restart "$fe" \
        BACKEND_URL="http://${be}.web:${BACKEND_PORT}" \
        PORT="$FRONTEND_PORT" \
        APP_DOMAIN="$domain" >/dev/null

    info "  rebuild: $be, $fe"
    dk_dokku ps:rebuild "$be" || warn "  $be rebuild failed (deploy not yet done?)"
    dk_dokku ps:rebuild "$fe" || warn "  $fe rebuild failed (deploy not yet done?)"
done

# ---------------------------------------------------------------------------
# 4. Validate and rebuild Dokku nginx config
# ---------------------------------------------------------------------------
log "Validating Dokku nginx config..."
if ! dk_dokku nginx:validate-config; then
    error "nginx:validate-config failed — inspect output above"
fi

log "Rebuilding Dokku proxy config (all apps)..."
dk_dokku proxy:build-config --all >/dev/null || warn "proxy:build-config failed"

log "Done. Verify next:"
for t in "${TENANTS[@]}"; do
    echo "  curl -I http://${t}.${BASE_DOMAIN}/"
done
