#!/usr/bin/env bash
# =============================================================================
# reload-zatca-daemon.sh — Refresh startup-loaded tenant discovery.
# =============================================================================
# The daemon contract loads enabled tenants and active branches at startup and
# has no live reload endpoint. A controlled Compose recreation is therefore
# the reload mechanism; XML and JetStream volumes remain persistent.
#
# Usage:
#   bash scripts/reload-zatca-daemon.sh --tenant acme --config /opt/deployment/config.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${CONFIG_FILE:-${REPO_DIR}/config.env}"
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
            sed -n '1,20p' "$0"
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
    1|true|yes)
        ;;
    *)
        info "ZATCA daemon is disabled; tenant reload is a no-op."
        exit 0
        ;;
esac

if [ -n "$TENANT_NAME" ] && ! [[ "$TENANT_NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    fail "invalid tenant name: $TENANT_NAME"
fi

if [ -n "$TENANT_NAME" ]; then
    info "Refreshing daemon tenant discovery after registry change for '$TENANT_NAME'..."
else
    info "Refreshing daemon tenant discovery..."
fi

bash "$SCRIPT_DIR/setup-zatca-daemon.sh" \
    --config "$CONFIG_FILE" \
    --health-timeout "$HEALTH_TIMEOUT_SECONDS" \
    --recreate

info "Daemon tenant discovery refreshed; readiness and queue health passed."
