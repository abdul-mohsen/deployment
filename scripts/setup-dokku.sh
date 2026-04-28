#!/usr/bin/env bash
set -euxo pipefail

echo "== Syntax check: scripts/setup.sh =="
bash -n scripts/setup.sh || { echo "SYNTAX-ERROR"; exit 1; }

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
  echo "ACTION: creating dokku container (ports 8080->80, 443->443)"
  docker run -d --name dokku --restart always --privileged --add-host=host.docker.internal:host-gateway -p 8080:80 -p 443:443 -v /var/lib/dokku:/mnt/dokku -v /var/run/docker.sock:/var/run/docker.sock -e DOKKU_HOSTNAME=localtest.me dokku/dokku:latest || { echo "RUN-FAILED"; exit 4; }
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
