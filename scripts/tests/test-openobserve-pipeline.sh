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
if [ "$(grep -c 'target_label  = "tenant_id"' "$alloy")" -lt 2 ]; then
    fail "tenant identity is not derived from backend/frontend container names"
fi
if [ "$(grep -c 'template = `{{ .tenant_id | default .tenant_input }}`' "$alloy")" -lt 2 ]; then
    fail "backend/frontend log pipelines do not use trusted container tenant identity"
fi
if [ "$(grep -c 'stage.label_drop' "$alloy")" -lt 2 ]; then
    fail "tenant identity remains exposed as a stream label"
fi
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
grep -Fq 'otelcol.auth.basic "tenant"' "$alloy" \
    || fail "shared OTLP receiver does not require deployment authentication"
grep -Fq 'password = sys.env("OPENOBSERVE_TENANT_OTLP_TOKEN")' "$alloy" \
    || fail "shared OTLP receiver token is not deployment-provided"
grep -Fq 'auth                  = otelcol.auth.basic.tenant.handler' "$alloy" \
    || fail "OTLP HTTP receiver is not protected by the deployment token"
grep -Fq 'set(attributes["service.name"], "ifritah-tenant")' "$alloy" \
    || fail "shared OTLP receiver does not overwrite caller service identity"
if grep -Fq 'set(attributes["tenant_id"], attributes["tenant.id"])' "$alloy"; then
    fail "shared OTLP receiver trusts caller-supplied tenant.id"
fi
grep -Fq 'timestamp_input              = "time"' "$alloy" \
    || fail "slog time field is not mapped into canonical event time"
grep -Fq 'message_input                = "msg"' "$alloy" \
    || fail "slog msg field is not mapped into canonical event type"
grep -Fq 'status_input                 = "status"' "$alloy" \
    || fail "slog status field is not mapped into canonical status code"
grep -Fq 'source   = "outcome_candidate"' "$alloy" \
    || fail "status-derived outcome mapping is missing"
grep -Fq 'set(attributes["method"], attributes["http.request.method"])' "$alloy" \
    || fail "native trace method is not mapped to canonical method"
grep -Fq 'set(attributes["route"], attributes["http.route"])' "$alloy" \
    || fail "native trace route is not mapped to canonical route"
grep -Fq 'set(attributes["status_code"], attributes["http.response.status_code"])' "$alloy" \
    || fail "native trace status is not mapped to canonical status code"
grep -Fq 'set(attributes["duration_ms"], (end_time_unix_nano - start_time_unix_nano) / 1000000)' "$alloy" \
    || fail "native trace duration is not converted from span timestamps"
pass "producer field mapping and trace canonicalization are configured"
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
grep -Fq 'forward_to = [otelcol.receiver.prometheus.health.receiver]' "$alloy" \
    || fail "collector health does not use the dedicated receiver"
grep -Fq 'otelcol.processor.batch "health"' "$alloy" \
    || fail "collector health does not use the dedicated batch"
grep -Fq 'metrics_endpoint = "http://openobserve-gateway:4318/v1/health"' "$alloy" \
    || fail "collector health does not use the dedicated exporter"
if grep -Fq 'health_direct' "$alloy"; then
    fail "obsolete collector health receiver remains"
fi
pass "bounded queues, retries, and pipeline health signals are configured"

grep -Fq 'containers/json' "$docker_filter" \
    || fail "filtered Docker API does not allow discovery"
grep -Fq 'containers/[A-Za-z0-9_.-]+/logs' "$docker_filter" \
    || fail "filtered Docker API does not allow logs"
grep -Fq 'containers/[A-Za-z0-9_.-]+/(?:json|stats)' "$docker_filter" \
    || fail "filtered Docker API does not allow inspect/stats"
grep -Fq 'networks(?:/[A-Za-z0-9_.-]+)?' "$docker_filter" \
    || fail "filtered Docker API does not allow read-only network discovery"
grep -Fq 'if ($request_method != GET)' "$docker_filter" \
    || fail "filtered Docker API is not read-only"
grep -Fq 'NETWORKS: "1"' "$compose" \
    || fail "Docker socket proxy does not allow read-only network discovery"
grep -Fq 'docker.sock:/var/run/docker.sock:ro' "$compose" \
    || fail "Docker socket is not mounted read-only at the proxy boundary"
grep -Fq 'The image entrypoint generates HAProxy config' "$compose" \
    || fail "Docker socket proxy writable config boundary is undocumented"
grep -Fq 'openobserve-gateway:4318/v1/logs' "$alloy" \
    || fail "logs do not use the single gateway egress"
grep -Fq 'openobserve-gateway:4318/v1/metrics' "$alloy" \
    || fail "metrics do not use the single gateway egress"
grep -Fq 'openobserve-gateway:4318/v1/traces' "$alloy" \
    || fail "traces do not use the single gateway egress"
grep -Fq 'prometheus.scrape "backend_http"' "$alloy" \
    || fail "backend HTTP metrics are not scraped"
grep -Fq 'forward_to = [otelcol.receiver.prometheus.application.receiver]' "$alloy" \
    || fail "backend metrics do not feed the OTel Prometheus receiver directly"
grep -Fq 'prometheus.scrape "container_resources"' "$alloy" \
    || fail "container resource metrics are not scraped"
grep -Fq 'forward_to = [otelcol.receiver.prometheus.direct.receiver]' "$alloy" \
    || fail "resource metrics do not feed the OTel Prometheus receiver directly"
if grep -Fq 'prometheus.relabel "container_resources"' "$alloy"; then
    fail "resource metrics still use the incompatible relabel-to-OTel fan-in path"
fi
grep -Fq 'type        = "Bearer"' "$alloy" \
    || fail "backend metrics scrape is not authenticated"
grep -Fq 'OPENOBSERVE_TENANT_OTLP_TOKEN: ${OPENOBSERVE_TENANT_OTLP_TOKEN:?set OPENOBSERVE_TENANT_OTLP_TOKEN in observability/openobserve.env}' "$compose" \
    || fail "Alloy token is not sourced from a protected operator environment"
grep -Fq 'ZO_ROOT_USER_PASSWORD: ${ZO_ROOT_USER_PASSWORD:?set ZO_ROOT_USER_PASSWORD in observability/openobserve.env}' "$compose" \
    || fail "Alloy OpenObserve exporter password is not sourced from a protected operator environment"
grep -Fq 'cap_add: [CHOWN, SETGID, SETUID]' "$compose" \
    || fail "Nginx filter lacks the least privilege needed to initialize its cache"
grep -Fq 'name: ifritah-observability-openobserve-core' "$compose" \
    || fail "core network is not declared"
grep -Fq 'name: ifritah-observability-openobserve-ingest' "$compose" \
    || fail "ingest network is not declared"
grep -Fq 'name: ifritah-observability-openobserve-ui' "$compose" \
    || fail "UI publish network is not declared"
grep -Fq './observability/openobserve-ui/nginx.conf:/etc/nginx/nginx.conf:ro' "$compose" \
    || fail "OpenObserve UI edge configuration is not mounted read-only"
grep -Fq 'networks: [openobserve-core, openobserve-ingest]' "$compose" \
    || fail "Alloy is not the only core/ingest bridge"
if grep -Fq 'openobserve:5080' "$alloy"; then
    fail "Alloy has a direct OpenObserve egress"
fi
for image in \
    'tecnativa/docker-socket-proxy:0.1.2@sha256:' \
    'nginx:1.27.1-alpine@sha256:' \
    'grafana/alloy:v1.19.2@sha256:' \
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
