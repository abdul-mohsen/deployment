#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

compose="dashboard/docker-compose.openobserve.yml"
credentials_example="dashboard/observability/openobserve.env.example"
compose_cli="${COMPOSE_CLI:-docker}"
compose_text="$(tr -d '\r' < "$compose" 2>/dev/null || true)"
credentials_text="$(tr -d '\r' < "$credentials_example" 2>/dev/null || true)"
gitignore_text="$(tr -d '\r' < .gitignore)"

[ -f "$compose" ] || fail "missing OpenObserve Compose file"
[ -f "$credentials_example" ] || fail "missing OpenObserve credentials example"
pass "OpenObserve profile files are present"

grep -Eq 'image: public\.ecr\.aws/zinclabs/openobserve:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' <<<"$compose_text" \
    || fail "OpenObserve image is not a versioned immutable reference"
grep -Fq 'profiles: ["openobserve"]' <<<"$compose_text" \
    || fail "OpenObserve service is not isolated behind its own profile"
grep -Fq '"${OBS_OPENOBSERVE_BIND:-127.0.0.1}:${OBS_OPENOBSERVE_PORT:-5080}:5080"' <<<"$compose_text" \
    || fail "OpenObserve host bind/port defaults are not loopback-only and configurable"
grep -Fq 'OBS_OPENOBSERVE_ENV_FILE:-observability/openobserve.env' <<<"$compose_text" \
    || fail "OpenObserve credentials file is not operator-selectable"
grep -Fq 'ZO_ROOT_USER_EMAIL' <<<"$credentials_text" \
    || fail "native OpenObserve root email is missing from the env example"
grep -Fq 'ZO_ROOT_USER_PASSWORD' <<<"$credentials_text" \
    || fail "native OpenObserve root password is missing from the env example"
grep -Fq 'OPENOBSERVE_TENANT_OTLP_TOKEN=replace-with-a-random-otlp-token' <<<"$credentials_text" \
    || fail "deployment OTLP token is missing from the protected env example"
grep -Fxq 'dashboard/observability/openobserve.env' <<<"$gitignore_text" \
    || fail "OpenObserve credentials file is not ignored"
pass "native credentials use an ignored operator env file"

grep -Fq 'openobserve-data:/data' <<<"$compose_text" \
    || fail "OpenObserve data volume is not mounted at /data"
grep -Fq 'name: ifritah-observability-openobserve-data' <<<"$compose_text" \
    || fail "OpenObserve data volume does not have a stable persistent name"
grep -Fq 'name: ifritah-observability-openobserve' <<<"$compose_text" \
    || fail "OpenObserve network does not have a stable name"
grep -Fq 'internal: true' <<<"$compose_text" \
    || fail "OpenObserve network is not internal-only"
grep -Fq 'networks: [openobserve]' <<<"$compose_text" \
    || fail "OpenObserve service is not attached to its private network"
pass "OpenObserve storage and network boundaries are explicit"

grep -Fq 'healthcheck:' <<<"$compose_text" \
    || fail "OpenObserve healthcheck is missing"
grep -Fq 'test: ["CMD", "/openobserve", "node", "status"]' <<<"$compose_text" \
    || fail "OpenObserve healthcheck does not use the native distroless-safe probe"
grep -Fq 'ZO_COMPACT_DATA_RETENTION_DAYS' <<<"$compose_text" \
    || fail "OpenObserve retention setting is missing"
grep -Fq 'ZO_COMPACT_EXTENDED_DATA_RETENTION_DAYS' <<<"$compose_text" \
    || fail "OpenObserve extended retention setting is missing"
grep -Fq 'mem_limit:' <<<"$compose_text" \
    || fail "OpenObserve memory limit is missing"
grep -Fq 'cpus:' <<<"$compose_text" \
    || fail "OpenObserve CPU limit is missing"
grep -Fq 'pids_limit:' <<<"$compose_text" \
    || fail "OpenObserve PID limit is missing"
pass "OpenObserve health, retention, and resource limits are configured"

for service in \
    docker-socket-proxy-openobserve \
    docker-api-filter-openobserve \
    openobserve-gateway \
    alloy-openobserve \
    node-exporter-openobserve \
    resource-exporter-openobserve; do
    grep -Eq "^[[:space:]]{2}${service}:" <<<"$compose_text" \
        || fail "OpenObserve collector service is missing: ${service}"
done
grep -Fq 'openobserve-gateway-data:/var/lib/openobserve-gateway' <<<"$compose_text" \
    || fail "OpenObserve gateway durable queue volume is missing"
grep -Fq 'openobserve-alloy-data:/var/lib/alloy' <<<"$compose_text" \
    || fail "OpenObserve Alloy storage volume is missing"
grep -Fq './observability/openobserve/config.alloy:/etc/alloy/config.alloy:ro' <<<"$compose_text" \
    || fail "OpenObserve Alloy configuration is not mounted read-only"
grep -Fq -- '--stability.level=public-preview' <<<"$compose_text" \
    || fail "OpenObserve Alloy public-preview components are not enabled explicitly"
if sed -n '/^    ports:/,/^    expose:/p' <<<"$compose_text" | grep -Fq '5081'; then
    fail "OpenObserve gRPC/OTLP port is host-published"
fi
if grep -Eq '^[[:space:]]+-[[:space:]]*"?[0-9.]*:(2375|4317|4318|8080|9100):' <<<"$compose_text"; then
    fail "OpenObserve Docker/collector/resource ports are host-published"
fi
pass "collector wiring is private and all telemetry/resource ports remain unbound"

echo
echo "=== OpenObserve Compose config ==="
compose_config="$(
    cd dashboard
    OBS_OPENOBSERVE_ENV_FILE=observability/openobserve.env.example \
        "$compose_cli" compose --env-file observability/openobserve.env.example \
        -f docker-compose.openobserve.yml --profile openobserve config </dev/null
)" || fail "OpenObserve Compose config failed"
printf '%s\n' "$compose_config" | grep -Fq 'name: ifritah-observability-openobserve-data' \
    || fail "Compose config omitted the persistent OpenObserve volume"
if [[ "$compose_config" != *'127.0.0.1:5080:5080'* ]]; then
    if [[ "$compose_config" != *'host_ip: 127.0.0.1'* ||
          "$compose_config" != *'published: "5080"'* ]]; then
        fail "Compose config did not resolve loopback defaults"
    fi
fi
if [[ "$compose_config" == *'0.0.0.0:5080:5080'* ||
      "$compose_config" == *'host_ip: 0.0.0.0'* ]]; then
    fail "Compose config resolved a public OpenObserve bind by default"
fi
pass "OpenObserve Compose config resolves with loopback defaults"

echo
echo "ALL OPENOBSERVE PROFILE TESTS PASSED"
