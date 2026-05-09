#!/usr/bin/env bash
# =============================================================================
# restart-stack.sh — Restart the Dokku container + Dashboard for one env
# =============================================================================
# One command to bounce both pieces of the stack. Use this after editing
# install.env / config.env / dashboard.env, after a host reboot, or to recover
# from a wedged container.
#
# Usage:
#   sudo bash scripts/restart-stack.sh                # default: dev
#   sudo bash scripts/restart-stack.sh --env dev
#   sudo bash scripts/restart-stack.sh --env prod
#   sudo bash scripts/restart-stack.sh --env prod --dokku-only
#   sudo bash scripts/restart-stack.sh --env dev --dashboard-only
#
# Behavior:
#   1. (Re)create the Dokku container if missing (via setup-dokku.sh, which
#      reads DOKKU_PORT / DOKKU_HOSTNAME from install.env / config.env), or
#      `docker restart dokku` if it exists.
#   2. `docker compose -f dashboard/docker-compose.<env>.yml up -d` to bring
#      the dashboard up. Uses --force-recreate so env-file changes are picked
#      up. For prod, the binary is expected to be already built into the
#      image; for dev, runs dashboard/dev-up.sh which rebuilds locally.
#   3. On any failure, dumps the last 200 log lines of the offending container.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

ENV_NAME="dev"
DOKKU_ONLY=false
DASHBOARD_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)            ENV_NAME="$2"; shift 2 ;;
        --dokku-only)     DOKKU_ONLY=true; shift ;;
        --dashboard-only) DASHBOARD_ONLY=true; shift ;;
        -h|--help)        sed -n '1,30p' "$0"; exit 0 ;;
        *)                error "Unknown flag: $1"; exit 1 ;;
    esac
done

case "$ENV_NAME" in
    dev|prod) ;;
    *)        error "--env must be 'dev' or 'prod' (got: $ENV_NAME)"; exit 1 ;;
esac

if ! command -v docker &>/dev/null; then
    error "docker not installed"
    exit 1
fi

DASHBOARD_DIR="${REPO_DIR}/dashboard"
COMPOSE_FILE="${DASHBOARD_DIR}/docker-compose.${ENV_NAME}.yml"
DASHBOARD_CONTAINER="dokku-dashboard-${ENV_NAME}"

# ---- 1. Dokku ------------------------------------------------------------
if ! $DASHBOARD_ONLY; then
    log "Restarting Dokku container..."
    if docker ps -a --format '{{.Names}}' | grep -qx 'dokku'; then
        if docker restart dokku >/dev/null; then
            info "  dokku restarted"
        else
            error "  docker restart dokku failed. Last 200 log lines:"
            docker logs --tail 200 dokku 2>&1 | sed 's/^/    /' >&2 || true
            exit 1
        fi
        # Wait for the daemon to answer.
        for i in $(seq 1 30); do
            if docker exec dokku dokku version >/dev/null 2>&1; then
                info "  dokku ready: $(docker exec dokku dokku version | head -1)"
                break
            fi
            sleep 2
            if [ "$i" -eq 30 ]; then
                error "  dokku did not become ready in 60s. Last 200 log lines:"
                docker logs --tail 200 dokku 2>&1 | sed 's/^/    /' >&2 || true
                exit 1
            fi
        done
    else
        warn "  dokku container missing — bootstrapping via ensure_dokku_running"
        if ! ensure_dokku_running; then
            error "  bootstrap failed (see logs above)"
            exit 1
        fi
    fi
fi

# ---- 2. Dashboard --------------------------------------------------------
if ! $DOKKU_ONLY; then
    [ -f "$COMPOSE_FILE" ] || { error "Compose file not found: $COMPOSE_FILE"; exit 1; }

    log "Restarting Dashboard ($ENV_NAME)..."
    cd "$DASHBOARD_DIR"

    if [ "$ENV_NAME" = "dev" ] && [ -x "./dev-up.sh" ]; then
        info "  using dev-up.sh (rebuilds binary + image)"
        if ! bash ./dev-up.sh; then
            error "  dev-up.sh failed. Last 200 log lines from $DASHBOARD_CONTAINER:"
            docker logs --tail 200 "$DASHBOARD_CONTAINER" 2>&1 | sed 's/^/    /' >&2 || true
            exit 1
        fi
    else
        if ! docker compose -f "$COMPOSE_FILE" up -d --force-recreate; then
            error "  docker compose up failed. Last 200 log lines from $DASHBOARD_CONTAINER:"
            docker logs --tail 200 "$DASHBOARD_CONTAINER" 2>&1 | sed 's/^/    /' >&2 || true
            exit 1
        fi
    fi

    # Quick readiness probe.
    for i in $(seq 1 15); do
        if docker ps --format '{{.Names}}' | grep -qx "$DASHBOARD_CONTAINER"; then
            info "  dashboard container is up: $DASHBOARD_CONTAINER"
            break
        fi
        sleep 1
        if [ "$i" -eq 15 ]; then
            error "  dashboard container not running after 15s. Last 200 log lines:"
            docker logs --tail 200 "$DASHBOARD_CONTAINER" 2>&1 | sed 's/^/    /' >&2 || true
            exit 1
        fi
    done
fi

echo ""
log "Stack restarted (env=$ENV_NAME)."
docker ps --filter 'name=^dokku$' --filter "name=^${DASHBOARD_CONTAINER}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
