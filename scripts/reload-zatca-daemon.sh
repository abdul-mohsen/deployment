#!/usr/bin/env bash
# =============================================================================
# reload-zatca-daemon.sh — Reload tenant discovery through the T009 lifecycle.
# =============================================================================
# The T009 daemon builds its tenant/branch map at startup. Until an approved
# image exposes a live reload API, a controlled Compose recreation is the
# compatible reload mechanism. Persistent XML/JetStream volumes are retained.
#
# Usage:
#   bash scripts/reload-zatca-daemon.sh --tenant acme --config /opt/deployment/config.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$(cd "${SCRIPT_DIR}/.." && pwd)/config.env}"
TENANT_NAME=""
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-60}"

error() { echo "[x] $*" >&2; }
info()  { echo "[i] $*"; }
fail()  { error "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant)
            [ "$#" -ge 2 ] || fail "--tenant requires a name"
            TENANT_NAME="$2"
            shift 2
            ;;
        --config)
            [ "$#" -ge 2 ] || fail "--config requires a path"
            CONFIG_FILE="$2"
            shift 2
            ;;
        --health-timeout)
            [ "$#" -ge 2 ] || fail "--health-timeout requires seconds"
            HEALTH_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '1,18p' "$0"
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[ -f "$CONFIG_FILE" ] || fail "Config file not found: $CONFIG_FILE"

# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

case "${ZATCA_DAEMON_ENABLED:-0}" in
    1|true|yes) ;;
    *)
        info "ZATCA daemon is disabled; tenant reload is a no-op."
        exit 0
        ;;
esac

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer "${ZATCA_MAX_WORKERS_PER_TENANT:-1}" \
    || fail "ZATCA_MAX_WORKERS_PER_TENANT must be a positive integer"
is_positive_integer "${ZATCA_MAX_WORKERS_PER_BRANCH:-1}" \
    || fail "ZATCA_MAX_WORKERS_PER_BRANCH must be a positive integer"
is_positive_integer "${ZATCA_MAX_PENDING:-1000}" \
    || fail "ZATCA_MAX_PENDING must be a positive integer"
is_integer "${ZATCA_MAX_ACK_PENDING:-100}" \
    || fail "ZATCA_MAX_ACK_PENDING must be a non-negative integer"
is_positive_integer "$HEALTH_TIMEOUT_SECONDS" \
    || fail "--health-timeout must be a positive integer"

command -v docker >/dev/null 2>&1 || fail "docker is required for daemon reload"

COMPOSE_FILE="${ZATCA_DAEMON_COMPOSE_FILE:-$(cd "${SCRIPT_DIR}/.." && pwd)/dashboard/docker-compose.zatca.yml}"
[ -f "$COMPOSE_FILE" ] || fail "Compose file not found: $COMPOSE_FILE"

if [ -n "$TENANT_NAME" ]; then
    info "Refreshing daemon tenant discovery after registration of '$TENANT_NAME'..."
else
    info "Refreshing daemon tenant discovery..."
fi

# setup-zatca-daemon.sh owns image/config validation, legacy NATS collision
# checks, persistent directory creation, Compose recreation, and readiness.
bash "$SCRIPT_DIR/setup-zatca-daemon.sh" \
    --config "$CONFIG_FILE" \
    --health-timeout "$HEALTH_TIMEOUT_SECONDS"

info "Daemon tenant discovery refreshed and queue health is within configured bounds."
