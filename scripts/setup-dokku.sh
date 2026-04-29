#!/usr/bin/env bash
set -euo pipefail

# Directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow overriding these from the environment; sane defaults for local/dev use
DOKKU_PORT="${DOKKU_PORT:-8080}"
DOKKU_HOSTNAME="${DOKKU_HOSTNAME:-localtest.me}"

echo "== Syntax check: scripts/setup.sh =="
bash -n "${SCRIPT_DIR}/setup.sh" || { echo "SYNTAX-ERROR"; exit 1; }

echo "== docker --version =="
docker --version || { echo "DOCKER-MISSING"; exit 2; }

# Check existing dokku container
if docker ps -a --format '{{.Names}}' | grep -q '^dokku$'; then
  echo "EXISTS: dokku container found"
  if docker ps --format '{{.Names}}' | grep -q '^dokku$'; then
    echo "STATUS: dokku already running"
  else
    echo "ACTION: starting existing dokku container"
    docker start dokku || { echo "START-FAILED"; exit 3; }
  fi
else
  echo "ACTION: creating dokku container (ports ${DOKKU_PORT}->80, 443->443)"
  docker run -d --name dokku --restart always --privileged --add-host=host.docker.internal:host-gateway -p "${DOKKU_PORT}":80 -p 443:443 -v /var/lib/dokku:/mnt/dokku -v /var/run/docker.sock:/var/run/docker.sock -e DOKKU_HOSTNAME="${DOKKU_HOSTNAME}" dokku/dokku:latest || { echo "RUN-FAILED"; exit 4; }
fi

# Wait up to 60s for dokku to respond
for i in $(seq 1 30); do
  if docker exec dokku dokku version >/dev/null 2>&1; then
    echo "DOKKU-READY: $(docker exec dokku dokku version | head -1)"
    break
  fi
  sleep 2
done

# Final status
docker ps --filter name=dokku --format 'CONTAINER:\t{{.Names}}\tSTATUS:\t{{.Status}}\tPORTS:\t{{.Ports}}' || true

echo "== last 200 lines of dokku logs =="
docker logs --tail 200 dokku || true
