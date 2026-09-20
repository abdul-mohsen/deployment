#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

alloy="dashboard/observability/openobserve/config.alloy"
gateway="dashboard/observability/openobserve-gateway/main.go"
gateway_test="dashboard/observability/openobserve-gateway/main_test.go"
streams="dashboard/observability/openobserve/streams.json"
manifest="dashboard/observability/openobserve/manifest.json"
dashboard="dashboard/observability/openobserve/dashboards/ifritah-operator.json"
views="dashboard/observability/openobserve/saved-views.json"
alerts="dashboard/observability/openobserve/alerts.json"
apply="dashboard/observability/openobserve/apply-openobserve.sh"

for path in "$alloy" "$gateway" "$gateway_test" "$streams" "$manifest" \
    "$dashboard" "$views" "$alerts" "$apply"; do
    [ -f "$path" ] || fail "missing health-routing file: $path"
done

grep -Fq 'prometheus.scrape "collector_health"' "$alloy" \
    || fail "collector health scrape is missing"
grep -Fq 'forward_to = [otelcol.receiver.prometheus.health.receiver]' "$alloy" \
    || fail "collector health scrape does not use the dedicated receiver"
grep -Fq 'otelcol.receiver.prometheus "health"' "$alloy" \
    || fail "dedicated health receiver is missing"
grep -Fq 'otelcol.processor.memory_limiter "health"' "$alloy" \
    || fail "dedicated health memory bound is missing"
grep -Fq 'otelcol.processor.transform "health"' "$alloy" \
    || fail "dedicated health sanitization is missing"
grep -Fq 'otelcol.processor.batch "health"' "$alloy" \
    || fail "dedicated health batch is missing"
grep -Fq 'otelcol.exporter.otlphttp "health"' "$alloy" \
    || fail "dedicated health exporter is missing"
grep -Fq 'metrics_endpoint = "http://openobserve-gateway:4318/v1/health"' "$alloy" \
    || fail "dedicated health exporter does not use the health ingress"
if grep -Fq 'health_direct' "$alloy"; then
    fail "obsolete health_direct receiver remains"
fi
if grep -A25 'prometheus.scrape "collector_health"' "$alloy" \
    | grep -Fq 'otelcol.receiver.prometheus.application.receiver'; then
    fail "collector health still routes through the ordinary application receiver"
fi
pass "Alloy uses one dedicated health pipeline without ordinary-metrics duplication"

grep -Fq 'if signal.name == "health"' "$gateway" \
    || fail "gateway health path mapping is missing"
grep -Fq 'return "/v1/metrics"' "$gateway" \
    || fail "gateway health path does not map to native metrics ingestion"
grep -Fq 'health.stream != ""' "$gateway_test" \
    || fail "gateway test does not protect against a health stream override"
grep -Fq 'TestHealthUsesDedicatedNativeMetricsIngress' "$gateway_test" \
    || fail "gateway health ingress test is missing"
pass "Gateway maps health ingress to native metrics without a stream override"

python3 - "$streams" "$manifest" "$dashboard" "$views" "$alerts" <<'PY'
import json
import sys

streams_path, manifest_path, dashboard_path, views_path, alerts_path = sys.argv[1:]

def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

streams = load(streams_path)
manifest = load(manifest_path)
dashboard = load(dashboard_path)
views = load(views_path)
alerts = load(alerts_path)

for document in (streams, manifest):
    health = document["health_signal"]
    assert health["ingress_path"] == "/v1/health"
    assert health["signal_type"] == "metrics"
    assert health["query_mode"] == "promql"
    assert health["retention_days"] == 15
    assert "ifritah_gateway_" in health["metric_name_prefixes"]
    assert "otelcol_" in health["metric_name_prefixes"]

encoded = json.dumps([streams, manifest, dashboard, views, alerts])
assert "ifritah_telemetry_health_v1" not in encoded

health_panels = [
    panel for panel in dashboard["tabs"][0]["panels"]
    if panel["id"] in {"telemetry-pipeline", "openobserve-health"}
]
assert len(health_panels) == 2
assert all(panel["queryType"] == "promql" for panel in health_panels)
assert all(query["fields"]["stream_type"] == "metrics"
           for panel in health_panels for query in panel["queries"])

health_views = [
    view for view in views["views"]
    if "health" in view["view_name"].lower() or "queue pressure" in view["view_name"].lower()
]
assert len(health_views) >= 2
assert all(view.get("query_type") == "promql" for view in health_views)

health_alerts = [
    alert for alert in alerts["alerts"]
    if "health path" in alert["name"].lower() or "collector drops" in alert["name"].lower()
]
assert len(health_alerts) == 1
assert all(alert["query_condition"]["type"] == "promql" for alert in health_alerts)
assert all(alert["stream_type"] == "metrics" for alert in health_alerts)
assert all(alert["enabled"] is False for alert in health_alerts)
print("health schema, dashboard, saved-view, and alert contracts are native PromQL")
PY
pass "Health provisioning has one native metric contract"

grep -Fq '/api/$ORG_PATH/streams?type=metrics' "$apply" \
    || fail "provisioning does not discover native metric streams"
grep -Fq 'allowed_name_prefixes' "$apply" \
    || fail "provisioning does not bound health metric retention"
pass "Provisioning retains health metrics through the native metric policy"

echo
echo "ALL OPENOBSERVE HEALTH ROUTING TESTS PASSED"
