#!/usr/bin/env bash
# Builds the dashboard image and restarts the dev container.
# The Dockerfile handles Go compilation internally (multi-stage build).
set -euo pipefail

cd "$(dirname "$0")"

# Remove old image to bust Docker layer cache
docker image rm ssdawweq/dokku-dashboard:dev 2>/dev/null || true

docker compose -f docker-compose.dev.yml build --no-cache
docker compose -f docker-compose.dev.yml up -d --force-recreate
