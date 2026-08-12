#!/usr/bin/env bash
# Builds the Linux binary on the host and rebuilds the dev container.
#
# Optionally also rebuilds the backend tenant image, since
# TENANT_IMAGE_PULL_POLICY=always (the default) makes create-tenant.sh
# silently re-pull and overwrite any locally-built backend image that isn't
# also pushed to Docker Hub. Set BACKEND_REPO_PATH to enable this step:
#
#   BACKEND_REPO_PATH=/path/to/ifritah-go ./dev-up.sh
#   BACKEND_REPO_PATH=/path/to/ifritah-go PUSH_BACKEND_IMAGE=true ./dev-up.sh
set -euo pipefail

cd "$(dirname "$0")"

if [ -n "${BACKEND_REPO_PATH:-}" ]; then
    BACKEND_IMAGE="${BACKEND_IMAGE:-${DOCKERHUB_USERNAME:-ssdawweq}/ifritah-api:dev}"
    echo "[+] Rebuilding backend image: ${BACKEND_IMAGE} (from ${BACKEND_REPO_PATH})"
    docker build -t "$BACKEND_IMAGE" "$BACKEND_REPO_PATH"
    if [ "${PUSH_BACKEND_IMAGE:-false}" = "true" ]; then
        echo "[+] Pushing backend image: ${BACKEND_IMAGE}"
        docker push "$BACKEND_IMAGE"
    else
        echo "[!] Backend image built locally only. TENANT_IMAGE_PULL_POLICY=always"
        echo "[!] will overwrite it on the next create-tenant run unless you either"
        echo "[!] set PUSH_BACKEND_IMAGE=true here, or set"
        echo "[!] TENANT_IMAGE_PULL_POLICY=missing in config.env."
    fi
fi

export GOOS=linux
export GOARCH=amd64
export CGO_ENABLED=0

mkdir -p bin
go build -ldflags="-s -w" -trimpath -o bin/dashboard .

# Force a clean image rebuild so freshly-baked binary + templates always land
# in the running container (avoids stale layers cached by Docker).
docker compose -f docker-compose.dev.yml build --no-cache
docker compose -f docker-compose.dev.yml up -d --force-recreate
