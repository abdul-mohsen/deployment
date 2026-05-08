#!/usr/bin/env bash
# Builds the Linux binary on the host and rebuilds the dev container.
set -euo pipefail

cd "$(dirname "$0")"

export GOOS=linux
export GOARCH=amd64
export CGO_ENABLED=0

mkdir -p bin
go build -ldflags="-s -w" -trimpath -o bin/dashboard .

# Force a clean image rebuild so freshly-baked binary + templates always land
# in the running container (avoids stale layers cached by Docker).
docker compose -f docker-compose.dev.yml build --no-cache
docker compose -f docker-compose.dev.yml up -d --force-recreate
