#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

alloy="dashboard/observability/openobserve/config.alloy"
gateway="dashboard/observability/openobserve-gateway/main.go"
resource="dashboard/observability/resource-exporter/main.go"
docker_filter="dashboard/observability/openobserve-docker-api-filter/nginx.conf"
compose="dashboard/docker-compose.openobserve.yml"
gateway_dockerfile="dashboard/observability/openobserve-gateway/Dockerfile"
resource_dockerfile="dashboard/observability/resource-exporter/Dockerfile"

for file in "$alloy" "$gateway" "$resource" "$docker_filter" "$compose" "$gateway_dockerfile" "$resource_dockerfile"; do
    [ -f "$file" ] || fail "missing OpenObserve pipeline file: $file"
done
pass "OpenObserve pipeline files are present"

for source in dashboard backend frontend; do
    grep -Fq "loki.source.docker \"${source}\"" "$alloy" \
        || fail "Docker log source is missing for ${source}"
    grep -Fq "discovery.relabel.${source}_allowlist.output" "$alloy" \
        || fail "Docker source is not connected to the ${source} allow-list"
done
grep -Fq 'com_ifritah_observability' "$alloy" \
    || fail "dashboard label allow-list is missing"
grep -Fq 'values = ["-backend"]' "$alloy" \
    || fail "backend Docker discovery filter is missing"
grep -Fq 'values = ["-frontend"]' "$alloy" \
    || fail "frontend Docker discovery filter is missing"
grep -Fq 'regex         = "^/?[a-z0-9][a-z0-9-]{0,61}-backend' "$alloy" \
    || fail "backend strict relabel allow-list is missing"
grep -Fq 'regex         = "^/?[a-z0-9][a-z0-9-]{0,61}-frontend' "$alloy" \
    || fail "frontend strict relabel allow-list is missing"
grep -Fq 'container_role' "$resource" \
    || fail "resource exporter role aggregation is missing"
grep -Fq 'tenantContainerPattern' "$resource" \
    || fail "resource exporter tenant naming allow-list is missing"
if grep -Eq 'container_id|container_name|tenant_id|request_id|trace_id|span_id|resource_id' "$resource"; then
    fail "resource exporter source contains a forbidden high-cardinality metric label"
fi
pass "Docker log and resource sources are explicitly allow-listed"

grep -Fq 'longer_than         = "64KB"' "$alloy" \
    || fail "Docker log size limit is missing"
grep -Fq 'forbidden_secret_key' "$alloy" \
    || fail "Docker secret-key drop rule is missing"
grep -Fq 'stage.luhn' "$alloy" \
    || fail "Docker Luhn redaction stage is missing"
grep -Fq 'Len(body) > 65536' "$alloy" \
    || fail "OTLP body size limit is missing"
grep -Fq 'delete_matching_keys' "$alloy" \
    || fail "OTLP attribute deny-list is missing"
grep -Fq 'keep_keys(attributes' "$alloy" \
    || fail "OTLP attribute allow-list is missing"
pass "redaction, size, and attribute allow-lists are configured"

grep -Fq 'QUEUE_MAX_BYTES' "$gateway" \
    || fail "gateway queue cap is missing"
grep -Eq 'max_elapsed_time[[:space:]]*=[[:space:]]*"30s"' "$alloy" \
    || fail "collector retry bound is missing"
grep -Fq 'send_batch_max_size = 128' "$alloy" \
    || fail "collector batch bound is missing"
grep -Fq 'ifritah_gateway_queue_bytes' "$gateway" \
    || fail "gateway queue health metric is missing"
grep -Fq 'ifritah_gateway_auth_blocked' "$gateway" \
    || fail "gateway authentication health metric is missing"
grep -Fq 'forwardPath' "$gateway" \
    || fail "gateway health-stream forwarding mapping is missing"
pass "bounded queues, retries, and pipeline health signals are configured"

grep -Fq 'containers/json' "$docker_filter" \
    || fail "filtered Docker API does not allow discovery"
grep -Fq 'containers/[A-Za-z0-9_.-]+/logs' "$docker_filter" \
    || fail "filtered Docker API does not allow logs"
grep -Fq 'containers/[A-Za-z0-9_.-]+/(?:json|stats)' "$docker_filter" \
    || fail "filtered Docker API does not allow inspect/stats"
grep -Fq 'if ($request_method != GET)' "$docker_filter" \
    || fail "filtered Docker API is not read-only"
grep -Fq 'docker.sock:/var/run/docker.sock:ro' "$compose" \
    || fail "Docker socket is not mounted read-only at the proxy boundary"
grep -Fq 'openobserve-gateway:4318/v1/logs' "$alloy" \
    || fail "logs do not use the single gateway egress"
grep -Fq 'openobserve-gateway:4318/v1/metrics' "$alloy" \
    || fail "metrics do not use the single gateway egress"
grep -Fq 'openobserve-gateway:4318/v1/traces' "$alloy" \
    || fail "traces do not use the single gateway egress"
if grep -Fq 'openobserve:5080' "$alloy"; then
    fail "Alloy has a direct OpenObserve egress"
fi
for image in \
    'tecnativa/docker-socket-proxy:0.1.2@sha256:' \
    'nginx:1.27.1-alpine@sha256:' \
    'grafana/alloy:v1.5.1@sha256:' \
    'quay.io/prometheus/node-exporter:v1.8.2@sha256:'; do
    grep -Fq "image: ${image}" "$compose" \
        || fail "OpenObserve image is not pinned immutably: ${image}"
done
for dockerfile in "$gateway_dockerfile" "$resource_dockerfile"; do
    grep -Fq 'golang:1.23.4-alpine@sha256:' "$dockerfile" \
        || fail "custom OpenObserve image builder is not pinned: ${dockerfile}"
done
grep -Fq 'COPY --from=builder --chown=65532:65532 /queue /var/lib/openobserve-gateway' "$gateway_dockerfile" \
    || fail "gateway queue volume does not have a non-root writable seed directory"
if grep -Eiq 'image:.*:latest([[:space:]]|$)' "$compose"; then
    fail "OpenObserve profile uses an unpinned latest image"
fi
pass "Docker API and single-egress boundaries are enforced"

echo
echo "ALL OPENOBSERVE PIPELINE TESTS PASSED"
