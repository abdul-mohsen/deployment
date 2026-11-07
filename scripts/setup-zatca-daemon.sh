#!/usr/bin/env bash
# =============================================================================
# setup-zatca-daemon.sh — Start and verify the optional ZATCA daemon.
# =============================================================================
# The daemon owns embedded NATS/JetStream. This command starts the Compose
# overlay, waits for NATS readiness, and then checks the ZATCA stream backlog.
# Use --recreate when the tenant registry changed; persistent XML and JetStream
# JetStream volumes are retained across that controlled restart.
#
# Usage:
#   bash scripts/setup-zatca-daemon.sh --config /opt/deployment/config.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${CONFIG_FILE:-${REPO_DIR}/config.env}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-60}"
RECREATE=false

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
        --recreate|--force-recreate)
            RECREATE=true
            shift
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
command -v docker >/dev/null 2>&1 || fail "docker is required"

# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

case "${ZATCA_DAEMON_ENABLED:-0}" in
    1|true|yes)
        ;;
    *)
        info "ZATCA daemon is disabled; nothing to start."
        exit 0
        ;;
esac

: "${ZATCA_DAEMON_IMAGE:?ZATCA_DAEMON_IMAGE must be set in ${CONFIG_FILE}}"
: "${ZATCA_DB_USER:?ZATCA_DB_USER must be set in ${CONFIG_FILE}}"
: "${ZATCA_DB_PASSWORD:?ZATCA_DB_PASSWORD must be set in ${CONFIG_FILE}}"
: "${ZATCA_ENCRYPT_KEY:?ZATCA_ENCRYPT_KEY must be set in ${CONFIG_FILE}}"
: "${ZATCA_MONITOR_PASSWORD:?ZATCA_MONITOR_PASSWORD must be set in ${CONFIG_FILE}}"

[[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && [ "$HEALTH_TIMEOUT_SECONDS" -gt 0 ] \
    || fail "--health-timeout must be a positive integer"

COMPOSE_FILE="${ZATCA_DAEMON_COMPOSE_FILE:-${REPO_DIR}/dashboard/docker-compose.zatca.yml}"
CONTAINER="${ZATCA_DAEMON_CONTAINER:-zatca-daemon}"
NATS_PORT="${ZATCA_NATS_PORT:-4222}"
NATS_ROOT="${ZATCA_NATS_DATA_ROOT:-/opt/zatca-nats}"

[ -f "$COMPOSE_FILE" ] || fail "Compose file not found: $COMPOSE_FILE"
mkdir -p "$NATS_ROOT"

# A legacy standalone NATS container and the daemon's embedded NATS must never
# own the same client port: that would split the queue and lose delivery.
if docker ps --format '{{.Names}}' | grep -qx "${NATS_CONTAINER_NAME:-nats}"; then
    legacy_port="$(docker port "${NATS_CONTAINER_NAME:-nats}" 4222/tcp 2>/dev/null \
        | awk -F: 'NR == 1 {print $NF; exit}' || true)"
    if [ "$legacy_port" = "$NATS_PORT" ]; then
        fail "legacy NATS container '${NATS_CONTAINER_NAME:-nats}' owns port ${NATS_PORT}; stop it before enabling zatca-daemon"
    fi
fi

compose_args=(--env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" --profile zatca up -d)
$RECREATE && compose_args+=(--force-recreate)
compose_args+=(zatca-daemon)

info "Starting ZATCA daemon image: $ZATCA_DAEMON_IMAGE"
docker compose "${compose_args[@]}"

info "Waiting for $CONTAINER readiness..."
for _ in $(seq 1 "$HEALTH_TIMEOUT_SECONDS"); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || true)"
    case "$status" in
        healthy)
            if ! bash "${SCRIPT_DIR}/health-zatca-daemon.sh" \
                --config "$CONFIG_FILE" --json --quiet; then
                error "ZATCA daemon is ready but queue health is outside configured thresholds. Recent logs:"
                docker logs --tail 100 "$CONTAINER" >&2 || true
                exit 1
            fi
            info "ZATCA daemon is ready; stream backlog is within configured thresholds."
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

error "ZATCA daemon did not become ready within ${HEALTH_TIMEOUT_SECONDS}s. Recent logs:"
docker logs --tail 100 "$CONTAINER" >&2 || true
exit 1
