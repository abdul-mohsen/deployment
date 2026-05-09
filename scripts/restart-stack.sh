#!/usr/bin/env bash
# =============================================================================
# restart-stack.sh — Stop, then start Dokku + Dashboard
# =============================================================================
# One command to bounce the stack cleanly. It always stops selected dashboard
# containers before touching Dokku, then starts Dokku, then starts dashboards.
# If the existing Dokku container has the wrong HTTP port, no HTTP port, or an
# old 443 publish, it is removed and recreated via setup-dokku.sh. Dokku state
# survives because /var/lib/dokku is bind-mounted.
#
# Usage:
#   sudo bash scripts/restart-stack.sh                # default: dev dashboard + dokku
#   sudo bash scripts/restart-stack.sh --env dev
#   sudo bash scripts/restart-stack.sh --env prod
#   sudo bash scripts/restart-stack.sh --env all      # dev + prod dashboards + dokku
#   sudo bash scripts/restart-stack.sh --env prod --dokku-only
#   sudo bash scripts/restart-stack.sh --env dev --dashboard-only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

ENV_NAME="dev"
DOKKU_ONLY=false
DASHBOARD_ONLY=false
DOKKU_STOP_SECONDS="${DOKKU_STOP_SECONDS:-20}"
COMMAND_TIMEOUT_SECONDS="${COMMAND_TIMEOUT_SECONDS:-60}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)            ENV_NAME="$2"; shift 2 ;;
        --dokku-only)     DOKKU_ONLY=true; shift ;;
        --dashboard-only) DASHBOARD_ONLY=true; shift ;;
        -h|--help)        sed -n '1,28p' "$0"; exit 0 ;;
        *)                error "Unknown flag: $1"; exit 1 ;;
    esac
done

case "$ENV_NAME" in
    dev|prod|all) ;;
    *)            error "--env must be 'dev', 'prod', or 'all' (got: $ENV_NAME)"; exit 1 ;;
esac

if $DOKKU_ONLY && $DASHBOARD_ONLY; then
    error "Use only one of --dokku-only or --dashboard-only."
    exit 1
fi

if ! command -v docker &>/dev/null; then
    error "docker not installed"
    exit 1
fi

load_stack_env() {
    local caller_dokku_port="${DOKKU_PORT:-}"
    local caller_dokku_hostname="${DOKKU_HOSTNAME:-}"
    local env_file
    for env_file in "${REPO_DIR}/config.env" "${REPO_DIR}/install.env"; do
        if [ -f "$env_file" ]; then
            # shellcheck disable=SC1090
            set -a; . "$env_file"; set +a
        fi
    done
    [ -n "$caller_dokku_port" ] && DOKKU_PORT="$caller_dokku_port"
    [ -n "$caller_dokku_hostname" ] && DOKKU_HOSTNAME="$caller_dokku_hostname"
    DOKKU_PORT="${DOKKU_PORT:-8080}"
    DOKKU_HOSTNAME="${DOKKU_HOSTNAME:-${BASE_DOMAIN:-localtest.me}}"
}

dashboard_envs() {
    if [ "$ENV_NAME" = "all" ]; then
        printf '%s\n' dev prod
    else
        printf '%s\n' "$ENV_NAME"
    fi
}

compose_file_for() { echo "${REPO_DIR}/dashboard/docker-compose.$1.yml"; }
dashboard_container_for() { echo "dokku-dashboard-$1"; }

dump_logs() {
    local container="$1"
    docker logs --tail 200 "$container" 2>&1 | sed 's/^/    /' >&2 || true
}

run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

stop_dashboard_env() {
    local env_name="$1"
    local compose_file container
    compose_file="$(compose_file_for "$env_name")"
    container="$(dashboard_container_for "$env_name")"
    [ -f "$compose_file" ] || { error "Compose file not found: $compose_file"; exit 1; }

    log "Stopping Dashboard (${env_name})..."
    if ! (cd "${REPO_DIR}/dashboard" && run_with_timeout "$COMMAND_TIMEOUT_SECONDS" docker compose -f "$compose_file" down --remove-orphans); then
        error "  docker compose down failed for $container. Last 200 log lines:"
        dump_logs "$container"
        exit 1
    fi
    info "  dashboard stopped: $container"
}

start_dashboard_env() {
    local env_name="$1"
    local compose_file container
    compose_file="$(compose_file_for "$env_name")"
    container="$(dashboard_container_for "$env_name")"
    [ -f "$compose_file" ] || { error "Compose file not found: $compose_file"; exit 1; }

    log "Starting Dashboard (${env_name})..."
    if [ "$env_name" = "dev" ] && [ -x "${REPO_DIR}/dashboard/dev-up.sh" ]; then
        info "  using dev-up.sh (rebuilds binary + image)"
        if ! (cd "${REPO_DIR}/dashboard" && bash ./dev-up.sh); then
            error "  dev-up.sh failed. Last 200 log lines from $container:"
            dump_logs "$container"
            exit 1
        fi
    else
        if ! (cd "${REPO_DIR}/dashboard" && docker compose -f "$compose_file" up -d --force-recreate); then
            error "  docker compose up failed. Last 200 log lines from $container:"
            dump_logs "$container"
            exit 1
        fi
    fi

    for i in $(seq 1 15); do
        if docker ps --format '{{.Names}}' | grep -qx "$container"; then
            info "  dashboard container is up: $container"
            return 0
        fi
        sleep 1
    done
    error "  dashboard container not running after 15s. Last 200 log lines:"
    dump_logs "$container"
    exit 1
}

dokku_exists() { docker ps -a --format '{{.Names}}' | grep -qx 'dokku'; }
dokku_running() { docker ps --format '{{.Names}}' | grep -qx 'dokku'; }
dokku_http_port() { docker port dokku 80/tcp 2>/dev/null | awk -F: 'NR == 1 { print $NF }'; }
dokku_https_port() { docker port dokku 443/tcp 2>/dev/null | awk -F: 'NR == 1 { print $NF }'; }

stop_dokku_if_present() {
    if dokku_exists; then
        if ! dokku_running; then
            info "Dokku container already stopped."
            return 0
        fi

        log "Stopping Dokku container (timeout ${DOKKU_STOP_SECONDS}s)..."
        if run_with_timeout "$((DOKKU_STOP_SECONDS + 15))" docker stop --time "$DOKKU_STOP_SECONDS" dokku >/dev/null 2>&1; then
            info "  dokku stopped"
            return 0
        fi

        warn "  docker stop did not finish cleanly; force-killing dokku..."
        run_with_timeout 20 docker kill dokku >/dev/null 2>&1 || true
        if dokku_running; then
            error "  dokku is still running after stop/kill. Last 200 log lines:"
            dump_logs dokku
            exit 1
        fi
        info "  dokku force-stopped"
    fi
}

start_or_recreate_dokku() {
    local recreate=false
    local reason=""
    local current_http current_https

    if dokku_exists; then
        current_http="$(dokku_http_port)"
        current_https="$(dokku_https_port)"
        if [ -z "$current_http" ]; then
            recreate=true
            reason="missing ${DOKKU_PORT}->80 publish"
        elif [ "$current_http" != "$DOKKU_PORT" ]; then
            recreate=true
            reason="mapped ${current_http}->80 but config requests ${DOKKU_PORT}->80"
        elif [ -n "$current_https" ]; then
            recreate=true
            reason="old unsupported 443 publish detected (${current_https}->443)"
        fi

        if $recreate; then
            warn "Recreating Dokku container: $reason"
            docker rm dokku >/dev/null
            if ! bash "${SCRIPT_DIR}/setup-dokku.sh"; then
                error "  setup-dokku.sh failed. Last 200 log lines from dokku:"
                dump_logs dokku
                exit 1
            fi
        else
            log "Starting Dokku container..."
            if ! docker start dokku >/dev/null; then
                error "  docker start dokku failed. Last 200 log lines:"
                dump_logs dokku
                exit 1
            fi
        fi
    else
        warn "Dokku container missing — tenant app containers may still be running, but Dokku nginx/CLI is absent. Bootstrapping via setup-dokku.sh"
        if ! bash "${SCRIPT_DIR}/setup-dokku.sh"; then
            error "  bootstrap failed. Last 200 log lines from dokku container (if any):"
            dump_logs dokku
            exit 1
        fi
    fi

    for i in $(seq 1 30); do
        if docker exec dokku dokku version >/dev/null 2>&1; then
            info "  dokku ready: $(docker exec dokku dokku version | head -1)"
            return 0
        fi
        sleep 2
    done
    error "  dokku did not become ready in 60s. Last 200 log lines:"
    dump_logs dokku
    exit 1
}

load_stack_env

if ! $DOKKU_ONLY; then
    while IFS= read -r env_name; do
        stop_dashboard_env "$env_name"
    done < <(dashboard_envs)
fi

if ! $DASHBOARD_ONLY; then
    stop_dokku_if_present
    start_or_recreate_dokku
fi

if ! $DOKKU_ONLY; then
    while IFS= read -r env_name; do
        start_dashboard_env "$env_name"
    done < <(dashboard_envs)
fi

echo ""
log "Stack restarted (env=$ENV_NAME)."
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
    | awk '$1 == "NAMES" || $1 == "dokku" || $1 == "dokku-dashboard-dev" || $1 == "dokku-dashboard-prod"'
