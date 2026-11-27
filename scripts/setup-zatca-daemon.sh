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
#   bash scripts/setup-zatca-daemon.sh --config /opt/deployment/config.env --image zatca-daemon:refresh --recreate
#   bash scripts/setup-zatca-daemon.sh --config /opt/deployment/config.env --validate-only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${CONFIG_FILE:-${REPO_DIR}/config.env}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-60}"
RECREATE=false
VALIDATE_ONLY=false
IMAGE_OVERRIDE=""

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
        --image)
            [ "$#" -ge 2 ] || fail "--image requires a value"
            [ -n "$2" ] || fail "--image must not be empty"
            IMAGE_OVERRIDE="$2"
            shift 2
            ;;
        --recreate|--force-recreate)
            RECREATE=true
            shift
            ;;
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        -h|--help)
            sed -n '1,28p' "$0"
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
if [ -n "$IMAGE_OVERRIDE" ]; then
    ZATCA_DAEMON_IMAGE="$IMAGE_OVERRIDE"
    export ZATCA_DAEMON_IMAGE
fi

case "${ZATCA_DAEMON_ENABLED:-0}" in
    1|true|yes)
        ;;
    *)
        $VALIDATE_ONLY && fail "ZATCA daemon must be enabled for validation-only operation"
        info "ZATCA daemon is disabled; nothing to start."
        exit 0
        ;;
esac

: "${ZATCA_DAEMON_IMAGE:?ZATCA_DAEMON_IMAGE must be set in ${CONFIG_FILE}}"
: "${ZATCA_DB_USER:?ZATCA_DB_USER must be set in ${CONFIG_FILE}}"
: "${ZATCA_DB_PASSWORD:?ZATCA_DB_PASSWORD must be set in ${CONFIG_FILE}}"
: "${ZATCA_ENCRYPT_KEY:?ZATCA_ENCRYPT_KEY must be set in ${CONFIG_FILE}}"
: "${ZATCA_MONITOR_PASSWORD:?ZATCA_MONITOR_PASSWORD must be set in ${CONFIG_FILE}}"
: "${NATS_USER:?NATS_USER must be set in ${CONFIG_FILE}}"
: "${NATS_PASSWORD:?NATS_PASSWORD must be set in ${CONFIG_FILE}}"
case "${NATS_PRIVATE_NETWORK_ONLY:-false}" in
    1|true|yes) ;;
    *) fail "NATS_PRIVATE_NETWORK_ONLY=true is required because this overlay runs NATS without TLS" ;;
esac
validate_zatca_daemon_security_gates || exit 1
RESOLVED_ZATCA_TENANT_DB_PREFIX="$(resolve_zatca_tenant_db_prefix "${TENANT_DB_PREFIX:-}" "${TENANT_NAME_PREFIX:-}")" || exit 1

[[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && [ "$HEALTH_TIMEOUT_SECONDS" -gt 0 ] \
    || fail "--health-timeout must be a positive integer"

COMPOSE_FILE="${ZATCA_DAEMON_COMPOSE_FILE:-${REPO_DIR}/dashboard/docker-compose.zatca.yml}"
CONTAINER="${ZATCA_DAEMON_CONTAINER:-zatca-daemon}"
NATS_PORT="${ZATCA_NATS_PORT:-4222}"
NATS_ROOT="${ZATCA_NATS_DATA_ROOT:-/opt/zatca-nats}"

[ -f "$COMPOSE_FILE" ] || fail "Compose file not found: $COMPOSE_FILE"
if ! docker compose --env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" \
    --profile zatca config --quiet; then
    fail "Docker Compose config validation failed for ${COMPOSE_FILE}"
fi

if $VALIDATE_ONLY; then
    info "ZATCA daemon configuration is valid."
    exit 0
fi

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

if $RECREATE; then
    existing_container_names="$(docker ps -a --format '{{.Names}}')" ||
        fail "Could not inspect existing ZATCA daemon containers"
    if printf '%s\n' "$existing_container_names" | grep -qxF "$CONTAINER"; then
        info "Removing existing ZATCA daemon container ${CONTAINER} before recreation..."
        docker rm --force "$CONTAINER" ||
            fail "Could not remove existing ZATCA daemon container ${CONTAINER}"
    fi
fi

compose_args=(--env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" --profile zatca up -d)
$RECREATE && compose_args+=(--force-recreate)
compose_args+=(zatca-daemon)

info "Starting ZATCA daemon image: $ZATCA_DAEMON_IMAGE"
if [ -n "$RESOLVED_ZATCA_TENANT_DB_PREFIX" ]; then
    info "ZATCA daemon tenant DB prefix scope: $RESOLVED_ZATCA_TENANT_DB_PREFIX"
fi
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
