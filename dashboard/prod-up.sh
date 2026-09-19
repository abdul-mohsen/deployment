#!/usr/bin/env bash
# =============================================================================
# prod-up.sh — Pull the latest dashboard image and restart the container.
#
# Pulls the pre-built image from Docker Hub (built automatically by GitHub
# Actions on every push to main) and runs it — no Go, no docker build.
#
# Usage (from anywhere on the server):
#   sudo bash /opt/deployment/dashboard/prod-up.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/lib.sh"

# Preserve production path and Docker settings used by restart-stack.sh while
# keeping image identity validation in this stop-safe entrypoint.
for env_file in "${REPO_DIR}/config.env" "${REPO_DIR}/install.env"; do
    if [ -f "$env_file" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$env_file"
        set +a
    fi
done

IMAGE="${DASHBOARD_IMAGE:-ssdawweq/dokku-dashboard:prod}"
CONTAINER="dokku-dashboard-prod"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.prod.yml"
DASHBOARD_LOG_TAIL_LINES="${DASHBOARD_LOG_TAIL_LINES:-80}"
if ! [[ "$DASHBOARD_LOG_TAIL_LINES" =~ ^[0-9]+$ ]] ||
    [ "$DASHBOARD_LOG_TAIL_LINES" -lt 1 ] ||
    [ "$DASHBOARD_LOG_TAIL_LINES" -gt 200 ]; then
    DASHBOARD_LOG_TAIL_LINES=80
fi
FAILURE_REPORTED=0

# Keep failure diagnostics bounded and focused on the dashboard container.
# This reports state and recent dashboard logs; it never attempts an automatic
# rollback or emits tenant application log streams.
deployment_failure_report() {
    local exit_code="${1:-1}" line_number="${2:-0}"
    [ "$FAILURE_REPORTED" -eq 0 ] || return 0
    FAILURE_REPORTED=1
    echo "" >&2
    echo "[!] Dashboard update failed (exit=${exit_code}, line=${line_number})." >&2
    echo "    Container state:" >&2
    if ! docker inspect "$CONTAINER" --format \
        'status={{.State.Status}} exit_code={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} error_present={{if .State.Error}}true{{else}}false{{end}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} image={{.Image}}' \
        2>/dev/null | sed -n '1p' | cut -c1-2048 >&2; then
        echo "    container=${CONTAINER} not found" >&2
    fi
    echo "    Recent dashboard logs (up to ${DASHBOARD_LOG_TAIL_LINES} lines):" >&2
    docker logs --tail "$DASHBOARD_LOG_TAIL_LINES" --timestamps "$CONTAINER" 2>&1 \
        | sed -n "1,${DASHBOARD_LOG_TAIL_LINES}p" \
        | sed 's/^/      /' >&2 || true
}

deployment_init_logging
deployment_exit_report() {
    local exit_code=$?
    trap - EXIT
    if [ "$exit_code" -ne 0 ]; then
        deployment_failure_report "$exit_code" "${BASH_LINENO[0]:-0}"
    fi
    exit "$exit_code"
}
trap deployment_exit_report EXIT

BRANCH="$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ "$BRANCH" != "main" ]; then
    echo "[!] Deployment checkout must be on main (found '${BRANCH:-detached}')." >&2
    exit 1
fi
if [ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]; then
    echo "[!] Deployment checkout has tracked changes; refusing to mix dashboard and runner revisions." >&2
    exit 1
fi
SCRIPT_REVISION="$(git -C "$REPO_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
if [[ ! "$SCRIPT_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
    echo "[!] Could not resolve the deployment script revision." >&2
    exit 1
fi
export DEPLOYMENT_SCRIPTS_REVISION="$SCRIPT_REVISION"
echo "[+] Deployment scripts revision: $SCRIPT_REVISION"

echo "[+] Pulling latest image: $IMAGE"
docker pull "$IMAGE"
IMAGE_DIGEST="$(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' \
  | sed 's/.*@//')"
if [[ ! "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "[!] Pulled image did not expose a manifest digest: $IMAGE" >&2
    exit 1
fi
IMAGE_REVISION="$(docker image inspect "$IMAGE" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)"
if [ "$IMAGE_REVISION" != "$SCRIPT_REVISION" ]; then
    echo "[!] Dashboard image/scripts revision mismatch." >&2
    echo "    image:   ${IMAGE_REVISION:-unknown}" >&2
    echo "    scripts: $SCRIPT_REVISION" >&2
    echo "[!] Wait for the dashboard image workflow for this deployment commit, then retry." >&2
    exit 1
fi
export DASHBOARD_IMAGE_REF="$IMAGE"
export DASHBOARD_IMAGE_DIGEST="$IMAGE_DIGEST"
export DASHBOARD_IMAGE_REVISION="$IMAGE_REVISION"
echo "[+] Resolved manifest digest: $IMAGE_DIGEST"

echo "[+] Stopping old container (if running)..."
docker stop "$CONTAINER" 2>/dev/null || true
docker rm   "$CONTAINER" 2>/dev/null || true

echo "[+] Starting new container..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo ""
echo "[+] Verifying..."
sleep 3

STATUS=$(docker inspect "$CONTAINER" --format "{{.State.Status}}" 2>/dev/null || echo "not found")
IMAGE_ID=$(docker inspect "$CONTAINER" --format "{{.Image}}" 2>/dev/null | cut -c1-20 || echo "-")

echo "    Container : $CONTAINER"
echo "    Status    : $STATUS"
echo "    Image SHA : $IMAGE_ID..."

if [ "$STATUS" = "running" ]; then
    HEALTH=$(curl -fsS http://127.0.0.1:8080/healthz 2>/dev/null || true)
    if [ "$HEALTH" != "ok" ]; then
        echo "    Healthz   : ${HEALTH:-unreachable}"
        echo "[!] Dashboard health check failed." >&2
        exit 1
    fi
    BUILD_INFO="$(curl -fsS http://127.0.0.1:8080/api/build-info)"
    ACTUAL_IMAGE_REVISION="$(printf '%s' "$BUILD_INFO" \
        | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p')"
    ACTUAL_SCRIPT_REVISION="$(printf '%s' "$BUILD_INFO" \
        | sed -n 's/.*"scripts_revision":"\([^"]*\)".*/\1/p')"
    if [ "$ACTUAL_IMAGE_REVISION" != "$SCRIPT_REVISION" ] ||
        [ "$ACTUAL_SCRIPT_REVISION" != "$SCRIPT_REVISION" ]; then
        echo "[!] Running dashboard identity does not match deployment scripts." >&2
        echo "    image:   ${ACTUAL_IMAGE_REVISION:-unknown}" >&2
        echo "    scripts: ${ACTUAL_SCRIPT_REVISION:-unknown}" >&2
        exit 1
    fi
    echo "    Healthz   : $HEALTH"
    echo "    Revision  : $SCRIPT_REVISION"
    echo ""
    echo "[+] Dashboard updated and running at http://127.0.0.1:8080"
else
    echo ""
    echo "[!] Container is not running — check logs:"
    deployment_failure_report 1 "${LINENO}"
    exit 1
fi
