#!/usr/bin/env bash
# Diagnose OpenObserve startup and health failures without changing services.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${REPO_DIR}/dashboard"
COMPOSE_FILE="${DASHBOARD_DIR}/docker-compose.openobserve.yml"
ENV_FILE="${OPENOBSERVE_ENV_FILE:-${DASHBOARD_DIR}/observability/openobserve.env}"
LOG_LINES="${OPENOBSERVE_LOG_LINES:-200}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "OpenObserve Compose file is missing: $COMPOSE_FILE" >&2
    exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
    echo "OpenObserve env file is missing: $ENV_FILE" >&2
    echo "Create it from dashboard/observability/openobserve.env.example." >&2
    exit 1
fi

compose() {
    docker compose \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        --profile openobserve \
        "$@"
}

echo "== OpenObserve services =="
compose ps --all

echo
echo "== OpenObserve startup logs =="
compose logs --no-color --tail="$LOG_LINES" openobserve || true

container_id="$(compose ps --all --quiet openobserve | head -n 1)"
if [[ -z "$container_id" ]]; then
    echo
    echo "No OpenObserve container exists."
    echo "Start only OpenObserve to see its live startup error:"
    echo "docker compose --env-file \"$ENV_FILE\" -f \"$COMPOSE_FILE\" --profile openobserve up --no-deps openobserve"
    exit 0
fi

echo
echo "== OpenObserve container health =="
docker inspect "$container_id" \
    --format 'name={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'

docker inspect "$container_id" \
    --format '{{if .State.Health}}{{range .State.Health.Log}}{{println .Start "exit=" .ExitCode .Output}}{{end}}{{else}}no healthcheck state{{end}}'
