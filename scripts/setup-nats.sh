#!/usr/bin/env bash
# Run a single NATS JetStream server on the host. Idempotent: re-running just
# confirms the container is up. Listens on host port 4222, reachable from
# tenant containers via host.docker.internal:4222.
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || { echo "[x] --config requires a path" >&2; exit 1; }
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '1,18p' "$0"
            exit 0
            ;;
        *)
            echo "[x] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || { echo "[x] Config file not found: $CONFIG_FILE" >&2; exit 1; }
    # shellcheck disable=SC1090
    set -a; source "$CONFIG_FILE"; set +a
fi

NAME=nats
PORT="${NATS_PORT:-4222}"
DATA="${NATS_DATA:-/var/lib/nats}"

case "${ZATCA_DAEMON_ENABLED:-0}" in
    1|true|yes)
        echo "[i] ZATCA daemon owns embedded NATS/JetStream; use setup-zatca-daemon.sh instead."
        exit 0
        ;;
esac

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
