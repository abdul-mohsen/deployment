#!/usr/bin/env bash
# =============================================================================
# dev-up.sh — Build and restart the complete local dashboard/observability stack.
#
# Builds the dashboard from source (multi-stage Dockerfile — no Go installation
# needed), then starts the profile-gated OpenObserve stack.
#
# Usage (from anywhere):
#   bash /opt/deployment/dashboard/dev-up.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.dev.yml"
OPENOBSERVE_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.openobserve.yml"
OPENOBSERVE_ENV_FILE="${OPENOBSERVE_ENV_FILE:-${SCRIPT_DIR}/observability/openobserve.env}"
IMAGE="ssdawweq/dokku-dashboard:dev"

if [[ ! -f "$OPENOBSERVE_ENV_FILE" ]]; then
    echo "[!] OpenObserve credentials file is missing: $OPENOBSERVE_ENV_FILE" >&2
    echo "    Create it from observability/openobserve.env.example before running dev-up.sh." >&2
    exit 1
fi

# Compose needs the host path so the dashboard can mount the deployment
# scripts into its sidecar runner. Derive it for local invocations when the
# caller did not provide an override.
if [[ -z "${SCRIPTS_HOST_PATH:-}" ]]; then
    export SCRIPTS_HOST_PATH="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
if [[ -z "${BUILD_COMMIT:-}" || "${BUILD_COMMIT}" == "local" ]]; then
    BUILD_COMMIT="$(git -C "${SCRIPT_DIR}/.." rev-parse --verify HEAD 2>/dev/null || printf 'local')"
fi
export DEPLOYMENT_SCRIPTS_REVISION="$BUILD_COMMIT"
export BUILD_COMMIT="$DEPLOYMENT_SCRIPTS_REVISION"

# Make the selected credentials file explicit for Compose service env_file
# resolution, including when OPENOBSERVE_ENV_FILE is overridden.
export OBS_OPENOBSERVE_ENV_FILE="$OPENOBSERVE_ENV_FILE"

echo "[+] Validating OpenObserve Compose configuration..."
docker compose \
    --env-file "$OPENOBSERVE_ENV_FILE" \
    -f "$OPENOBSERVE_COMPOSE_FILE" \
    --profile openobserve \
    config --quiet

echo "[+] Restarting OpenObserve stack..."
docker compose \
    --env-file "$OPENOBSERVE_ENV_FILE" \
    -f "$OPENOBSERVE_COMPOSE_FILE" \
    --profile openobserve \
    up -d --build --force-recreate

echo "[+] Removing old local image to bust layer cache..."
docker image rm "$IMAGE" 2>/dev/null || true

echo "[+] Building dashboard image from source (multi-stage — Go compiles inside Docker)..."
docker compose -f "$COMPOSE_FILE" build --no-cache

echo "[+] Starting dashboard container..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo ""
echo "[+] Done."
echo "    Dashboard:   http://localhost:8088"
echo "    OpenObserve: http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}"
echo ""
echo "[+] OpenObserve services:"
docker compose \
    --env-file "$OPENOBSERVE_ENV_FILE" \
    -f "$OPENOBSERVE_COMPOSE_FILE" \
    --profile openobserve \
    ps
