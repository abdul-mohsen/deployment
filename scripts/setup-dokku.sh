#!/usr/bin/env bash
set -euo pipefail

# Directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Pull DOKKU_PORT / DOKKU_HOSTNAME from install.env / config.env so callers
# don't have to remember to export them. Order: config.env (auto-generated)
# is sourced first, then install.env (operator's source of truth) so it wins.
# Explicit env vars set by the caller still beat both.
_caller_dokku_port="${DOKKU_PORT:-}"
_caller_dokku_hostname="${DOKKU_HOSTNAME:-}"
for _f in "${REPO_DIR}/config.env" "${REPO_DIR}/install.env"; do
  if [ -f "$_f" ]; then
    # shellcheck disable=SC1090
    set -a; . "$_f"; set +a
  fi
done
[ -n "$_caller_dokku_port" ]     && DOKKU_PORT="$_caller_dokku_port"
[ -n "$_caller_dokku_hostname" ] && DOKKU_HOSTNAME="$_caller_dokku_hostname"

# Allow overriding these from the environment; sane defaults for local/dev use
DOKKU_PORT="${DOKKU_PORT:-8080}"
DOKKU_HOSTNAME="${DOKKU_HOSTNAME:-localtest.me}"

get_dokku_host_port() {
  local port_output
  port_output="$(docker inspect dokku --format '{{range $port, $bindings := .HostConfig.PortBindings}}{{if eq $port "80/tcp"}}{{range $binding := $bindings}}{{println $binding.HostPort}}{{end}}{{end}}{{end}}' 2>/dev/null || true)"
  if [ -n "$port_output" ]; then
    awk 'NF { print; exit }' <<<"$port_output"
    return 0
  fi
  port_output="$(docker port dokku 80/tcp 2>/dev/null || true)"
  awk -F: 'NR == 1 { print $NF }' <<<"$port_output"
}

get_dokku_container_hostname() {
  docker inspect dokku --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^DOKKU_HOSTNAME=//p' | head -1
}

validate_existing_dokku_container() {
  local current_port current_hostname
  current_port="$(get_dokku_host_port)"
  current_hostname="$(get_dokku_container_hostname)"

  if [ -n "$current_port" ] && [ "$current_port" != "$DOKKU_PORT" ]; then
    echo "PORT-MISMATCH: existing dokku container maps host port ${current_port}->80, requested ${DOKKU_PORT}->80."
    echo "Fix: remove/recreate dokku with DOKKU_PORT=${DOKKU_PORT}, or run with DOKKU_PORT=${current_port}."
    exit 5
  fi

  if [ -n "$current_hostname" ] && [ "$current_hostname" != "$DOKKU_HOSTNAME" ]; then
    echo "HOSTNAME-MISMATCH: existing dokku container was created with DOKKU_HOSTNAME=${current_hostname}; requested ${DOKKU_HOSTNAME}."
    echo "Updating Dokku global domain to ${DOKKU_HOSTNAME}; recreate the container if you need the Docker env value changed too."
  fi
}

echo "== Syntax check: scripts/setup.sh =="
bash -n "${SCRIPT_DIR}/setup.sh" || { echo "SYNTAX-ERROR"; exit 1; }

echo "== docker --version =="
docker --version || { echo "DOCKER-MISSING"; exit 2; }

# Check existing dokku container
if docker ps -a --format '{{.Names}}' | grep -q '^dokku$'; then
  echo "EXISTS: dokku container found"
  validate_existing_dokku_container
  if docker ps --format '{{.Names}}' | grep -q '^dokku$'; then
    echo "STATUS: dokku already running"
  else
    echo "ACTION: starting existing dokku container"
    docker start dokku || { echo "START-FAILED"; exit 3; }
  fi
else
  echo "ACTION: creating dokku container (port ${DOKKU_PORT}->80)"
  docker run -d --name dokku --hostname dokku --restart always --privileged --add-host=host.docker.internal:host-gateway -p "${DOKKU_PORT}":80 -v /var/lib/dokku:/mnt/dokku -v /var/run/docker.sock:/var/run/docker.sock -e DOKKU_HOSTNAME="${DOKKU_HOSTNAME}" dokku/dokku:latest || { echo "RUN-FAILED"; exit 4; }
fi

# Wait up to 60s for dokku to respond
ready=false
for i in $(seq 1 30); do
  if docker exec dokku dokku version >/dev/null 2>&1; then
    echo "DOKKU-READY: $(docker exec dokku dokku version | head -1)"
    docker exec dokku dokku domains:set-global "${DOKKU_HOSTNAME}" >/dev/null
    ready=true
    break
  fi
  sleep 2
done

if [ "$ready" != "true" ]; then
  echo "DOKKU-NOT-READY: dokku did not answer within 60s."
  exit 6
fi

# Final status
docker ps --filter name=dokku --format 'CONTAINER:\t{{.Names}}\tSTATUS:\t{{.Status}}\tPORTS:\t{{.Ports}}' || true

echo "== last 200 lines of dokku logs =="
docker logs --tail 200 dokku || true
