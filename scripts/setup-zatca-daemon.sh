#!/usr/bin/env bash
# =============================================================================
# setup-zatca-daemon.sh — Start and verify the first-class ZATCA daemon.
# =============================================================================
# The daemon image owns an embedded NATS/JetStream server. This script starts
# the compose overlay and never creates a second broker.
#
# Usage:
#   sudo bash scripts/setup-zatca-daemon.sh --config /opt/deployment/config.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${CONFIG_FILE:-${REPO_DIR}/config.env}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-60}"

error() { echo "[x] $*" >&2; }
info()  { echo "[i] $*"; }
fail()  { error "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
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
            sed -n '1,24p' "$0"
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[ -f "$CONFIG_FILE" ] || fail "Config file not found: $CONFIG_FILE"
[ -x "$(command -v docker || true)" ] || fail "docker is required"

# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

: "${ZATCA_DAEMON_IMAGE:?ZATCA_DAEMON_IMAGE must be set in ${CONFIG_FILE}}"
: "${ZATCA_DB_USER:?ZATCA_DB_USER must be set in ${CONFIG_FILE}}"
: "${ZATCA_DB_PASSWORD:?ZATCA_DB_PASSWORD must be set in ${CONFIG_FILE}}"
: "${ZATCA_ENCRYPT_KEY:?ZATCA_ENCRYPT_KEY must be set in ${CONFIG_FILE}}"
: "${ZATCA_MONITOR_PASSWORD:?ZATCA_MONITOR_PASSWORD must be set in ${CONFIG_FILE}}"

if { [ -n "${ZATCA_ADMIN_DB_USER:-}" ] && [ -z "${ZATCA_ADMIN_DB_PASSWORD:-}" ]; } ||
   { [ -z "${ZATCA_ADMIN_DB_USER:-}" ] && [ -n "${ZATCA_ADMIN_DB_PASSWORD:-}" ]; }; then
    fail "ZATCA_ADMIN_DB_USER and ZATCA_ADMIN_DB_PASSWORD must be set together"
fi

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

ZATCA_MAX_WORKERS_PER_TENANT="${ZATCA_MAX_WORKERS_PER_TENANT:-1}"
ZATCA_MAX_WORKERS_PER_BRANCH="${ZATCA_MAX_WORKERS_PER_BRANCH:-1}"
ZATCA_MAX_PENDING="${ZATCA_MAX_PENDING:-1000}"
ZATCA_MAX_ACK_PENDING="${ZATCA_MAX_ACK_PENDING:-100}"

is_positive_integer "$ZATCA_MAX_WORKERS_PER_TENANT" \
    || fail "ZATCA_MAX_WORKERS_PER_TENANT must be a positive integer"
is_positive_integer "$ZATCA_MAX_WORKERS_PER_BRANCH" \
    || fail "ZATCA_MAX_WORKERS_PER_BRANCH must be a positive integer"
is_positive_integer "$ZATCA_MAX_PENDING" \
    || fail "ZATCA_MAX_PENDING must be a positive integer"
is_integer "$ZATCA_MAX_ACK_PENDING" \
    || fail "ZATCA_MAX_ACK_PENDING must be a non-negative integer"

COMPOSE_FILE="${ZATCA_DAEMON_COMPOSE_FILE:-${REPO_DIR}/dashboard/docker-compose.zatca.yml}"
CONTAINER="${ZATCA_DAEMON_CONTAINER:-zatca-daemon}"
XML_ROOT="${ZATCA_XML_ROOT:-/opt/zatca-xml}"
NATS_ROOT="${ZATCA_NATS_DATA_ROOT:-/opt/zatca-nats}"
NATS_PORT="${NATS_PORT:-4222}"

[ -f "$COMPOSE_FILE" ] || fail "Compose file not found: $COMPOSE_FILE"
mkdir -p "$XML_ROOT" "$NATS_ROOT"

# The old setup-nats.sh owns a container named `nats`. Refuse a same-port
# collision so two independent JetStream stores cannot silently diverge.
if docker ps --format '{{.Names}}' | grep -qx "${NATS_CONTAINER_NAME:-nats}"; then
    legacy_port="$(docker port "${NATS_CONTAINER_NAME:-nats}" 4222/tcp 2>/dev/null \
        | awk -F: 'NR == 1 {print $NF; exit}' || true)"
    if [ "$legacy_port" = "$NATS_PORT" ]; then
        fail "legacy NATS container '${NATS_CONTAINER_NAME:-nats}' owns port ${NATS_PORT}; stop it before enabling zatca-daemon"
    fi
fi

info "Starting ZATCA daemon image: $ZATCA_DAEMON_IMAGE"
docker compose --env-file "$CONFIG_FILE" \
    -f "$COMPOSE_FILE" --profile zatca \
    up -d --force-recreate zatca-daemon

info "Waiting for $CONTAINER health..."
for _ in $(seq 1 "$HEALTH_TIMEOUT_SECONDS"); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || true)"
    case "$status" in
        healthy)
            if ! bash "${SCRIPT_DIR}/health-zatca-daemon.sh" \
                --config "$CONFIG_FILE" --json >/dev/null; then
                error "ZATCA daemon is ready but queue health is outside configured bounds. Recent logs:"
                docker logs --tail 100 "$CONTAINER" >&2 || true
                exit 1
            fi
            info "ZATCA daemon is healthy; NATS client port is ${NATS_PORT} and queue health is within bounds."
            exit 0
            ;;
        unhealthy)
            error "ZATCA daemon healthcheck failed. Recent logs:"
            docker logs --tail 100 "$CONTAINER" >&2 || true
            exit 1
            ;;
    esac
    sleep 1
done

error "ZATCA daemon did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s. Recent logs:"
docker logs --tail 100 "$CONTAINER" >&2 || true
exit 1
