#!/usr/bin/env bash
# Run a single NATS JetStream server on the host. Idempotent: re-running just
# confirms the container is up. Listens on host port 4222, reachable from
# tenant containers via host.docker.internal:4222.
set -euo pipefail

NAME=nats
PORT="${NATS_PORT:-4222}"
DATA="${NATS_DATA:-/var/lib/nats}"

mkdir -p "$DATA"

if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "[+] NATS already running."
    exit 0
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true

docker run -d \
    --name "$NAME" \
    --restart unless-stopped \
    -p "${PORT}:4222" \
    -v "${DATA}:/data" \
    nats:2-alpine -js -sd /data

echo "[+] NATS started on host port ${PORT} (reachable inside containers as nats://host.docker.internal:${PORT})."
