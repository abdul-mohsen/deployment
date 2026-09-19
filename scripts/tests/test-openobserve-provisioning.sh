#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

root="dashboard/observability/openobserve"
manifest="$root/manifest.json"
streams="$root/streams.json"
dashboard="$root/dashboards/ifritah-operator.json"
views="$root/saved-views.json"
alerts="$root/alerts.json"
notifications="$root/notifications.example.json"
apply="$root/apply-openobserve.sh"

for path in "$manifest" "$streams" "$dashboard" "$views" "$alerts" "$notifications" "$apply"; do
    [ -f "$path" ] || fail "missing OpenObserve provisioning file: $path"
done
pass "OpenObserve provisioning inventory is present"

python3 - "$manifest" "$streams" "$dashboard" "$views" "$alerts" "$notifications" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path, streams_path, dashboard_path, views_path, alerts_path, notifications_path = sys.argv[1:]

def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

manifest = load(manifest_path)
stream_doc = load(streams_path)
dashboard = load(dashboard_path)
views = load(views_path)
alerts = load(alerts_path)
notifications = load(notifications_path)

assert manifest["schema_version"] == 1
assert manifest["endpoint"]["placeholder"] == "${OPENOBSERVE_ENDPOINT}"
assert manifest["endpoint"]["organization_placeholder"] == "${OPENOBSERVE_ORG}"
assert manifest["access"]["audience"] == "operators"
assert manifest["access"]["dashboard_proxying"] is False
assert manifest["retention"]["mode"] == "per_stream"
assert manifest["retention"]["requires_operator_setting"] == "OBS_OPENOBSERVE_IGNORE_STREAM_RETENTION=false"
for reference in (
    manifest["streams_file"],
    manifest["dashboard_file"],
    manifest["saved_views_file"],
    manifest["alerts_file"],
    manifest["notification_example_file"],
    manifest["apply_script"],
):
    assert Path(manifest_path).parent.joinpath(reference).exists(), reference

expected = {
    "ifritah_logs_v1": ("logs", 14),
    "ifritah_traces_v1": ("traces", 7),
    "ifritah_metrics_v1": ("metrics", 15),
    "ifritah_telemetry_health_v1": ("logs", 14),
}
actual = {}
for stream in stream_doc["streams"]:
    name = stream["name"]
    assert name not in actual
    actual[name] = (stream["type"], stream["retention_days"])
    assert stream["create"]["fields"] == []
    assert stream["create"]["settings"]["data_retention"] == stream["retention_days"]
    assert stream["settings"]["data_retention"] == stream["retention_days"]
    assert stream["create"]["settings"]["store_original_data"] is False
    assert stream["create"]["settings"]["max_query_range"] >= 24
    assert not stream["create"]["settings"].get("partition_keys")
    assert not any(
        key.lower() in {"labels", "label_names", "resource_labels"}
        for key in stream["create"]["settings"]
    )
assert actual == expected

assert dashboard["version"] == 5
assert dashboard["title"] == "Ifritah OpenObserve Operations"
assert dashboard["dashboardId"] == ""
panels = dashboard["tabs"][0]["panels"]
assert len(panels) >= 8
for panel in panels:
    assert panel["id"] and panel["title"] and panel["queryType"] == "sql"
    layout = panel["layout"]
    assert isinstance(layout["i"], int)
    assert 0 <= layout["x"] <= 47
    assert 1 <= layout["w"] <= 48
    assert layout["x"] + layout["w"] <= 48
    assert layout["h"] > 0
    for query in panel["queries"]:
        assert query["customQuery"] is True
        assert query["fields"]["stream"] in expected
        assert isinstance(query["fields"]["x"], list)
        assert isinstance(query["fields"]["y"], list)
        assert query["fields"]["z"] == []
        assert query["fields"]["filter"] == {
            "filterType": "group",
            "logicalOperator": "AND",
            "conditions": [],
        }

assert len(views["views"]) >= 8
for view in views["views"]:
    assert view["stream"] in expected
    assert view["relative_time"] in {"1h", "24h", "7d"}
    assert "_timestamp >= now() - INTERVAL" in view["query"]
    assert "LIMIT " in view["query"]

assert len(alerts["alerts"]) >= 15
assert alerts["destination_placeholder"] == "${OPENOBSERVE_ALERT_DESTINATION_NAME}"
for alert in alerts["alerts"]:
    assert alert["stream_name"] in expected
    assert alert["query_condition"]["type"] == "sql"
    assert "_timestamp >= now() - INTERVAL" in alert["query_condition"]["sql"]
    assert {
        "period",
        "operator",
        "threshold",
        "frequency",
        "frequency_type",
        "silence",
    } <= set(alert["trigger_condition"])
    assert alert["destinations"] == ["${OPENOBSERVE_ALERT_DESTINATION_NAME}"]
    assert alert["enabled"] is False

required_alerts = {
    "Ifritah - Container memory pressure": "ifritah_container_memory_working_set_bytes",
    "Ifritah - Filesystem or disk pressure": "node_filesystem_avail_bytes",
    "Ifritah - Container restart loop": "ifritah_container_restarts_total",
    "Ifritah - Host memory pressure": "node_memory_MemAvailable_bytes",
    "Ifritah - Host resource metrics health": "node_cpu_seconds_total",
    "Ifritah - Resource exporter health": "ifritah_resource_exporter_up",
    "Ifritah - Resource exporter scrape errors": "ifritah_resource_exporter_scrape_errors_total",
    "Ifritah - Telemetry gateway heartbeat missing": "ifritah_gateway_up",
    "Ifritah - Telemetry gateway health": "ifritah_gateway_forward_failures_total",
    "Ifritah - Telemetry gateway authentication blocked": "ifritah_gateway_auth_blocked",
}
alerts_by_name = {alert["name"]: alert for alert in alerts["alerts"]}
missing_alerts = sorted(set(required_alerts) - set(alerts_by_name))
assert not missing_alerts, f"resource alert templates missing: {missing_alerts}"
for name, metric_name in required_alerts.items():
    alert = alerts_by_name[name]
    query = alert["query_condition"]["sql"]
    assert metric_name in query, f"{name} does not use {metric_name}"
    assert alert["stream_name"] == "ifritah_metrics_v1"
    assert alert["destinations"] == ["${OPENOBSERVE_ALERT_DESTINATION_NAME}"]
    assert alert["enabled"] is False

for name in (
    "Ifritah - Container restart loop",
    "Ifritah - Resource exporter scrape errors",
    "Ifritah - Telemetry gateway health",
):
    assert "MAX(value) - MIN(value)" in alerts_by_name[name]["query_condition"]["sql"], name

assert "GROUP BY container_role" in alerts_by_name["Ifritah - Container restart loop"]["query_condition"]["sql"]
assert "GROUP BY metric_name, signal" in alerts_by_name["Ifritah - Telemetry gateway health"]["query_condition"]["sql"]

for name in (
    "Ifritah - Resource exporter health",
    "Ifritah - Telemetry gateway heartbeat missing",
):
    alert = alerts_by_name[name]
    assert alert["trigger_condition"]["operator"] == "<", name
    assert "COUNT(*)" in alert["query_condition"]["sql"], name

for name, counter in {
    "Ifritah - Resource exporter scrape errors": "ifritah_resource_exporter_scrape_errors_total",
    "Ifritah - Telemetry gateway health": "ifritah_gateway_forward_failures_total",
}.items():
    query = alerts_by_name[name]["query_condition"]["sql"]
    assert counter in query
    assert not re.search(rf"{re.escape(counter)}[^\"']*value\s*>\s*0", query, re.I), name

all_json = json.dumps([manifest, stream_doc, dashboard, views, alerts, notifications])
terms = [
    "request_id",
    "trace_id",
    "5xx",
    "error rate",
    "panic",
    "exception",
    "migration",
    "deployment",
    "auth",
    "duration_ms",
    "cpu",
    "memory",
    "disk",
    "restart",
    "dropped",
    "lag",
    "collector",
    "openobserve",
]
lowered = all_json.lower()
missing = [term for term in terms if term not in lowered]
assert not missing, f"required investigation terms missing: {missing}"

def strings(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)
    elif isinstance(value, str):
        yield value

for query in (value for value in strings([manifest, stream_doc, dashboard, views, alerts, notifications])
              if value.lstrip().upper().startswith("SELECT")):
    assert "now() - interval" in query.lower()
    assert not re.search(r"group\s+by\s+(request_id|trace_id|tenant_id|actor_id|operation_id)\b", query, re.I)

for key in re.findall(r'"([^"]+)"\s*:', all_json):
    assert key.lower() not in {"authorization", "cookie", "password", "token", "raw_body", "request_body", "response_body"}

assert "https://" not in all_json
assert "http://" not in all_json
assert notifications["destination_name"].startswith("REPLACE_WITH_")
assert notifications["endpoint_reference"].startswith("REPLACE_WITH_")

print("valid JSON, bounded queries, stream retention, operator boundary, and investigation coverage")
PY
pass "OpenObserve JSON contracts are valid"

grep -Fq 'OPENOBSERVE_ENDPOINT' "$apply" \
    || fail "apply script does not require an explicit endpoint"
grep -Fq 'OPENOBSERVE_ORG' "$apply" \
    || fail "apply script does not require an explicit organization"
grep -Fq 'OPENOBSERVE_ALERT_DESTINATION_NAME' "$apply" \
    || fail "apply script does not externalize alert destinations"
grep -Fq 'OPENOBSERVE_ALERT_NAMES' "$apply" \
    || fail "apply script does not require explicit alert selection"
grep -Fq '/api/v2/$ORG_PATH/alerts' "$apply" \
    || fail "apply script does not use the OpenObserve v2 alert endpoint"
grep -Fq 'schema_path="/api/$ORG_PATH/streams/$encoded_stream/schema?type=$stream_type"' "$apply" \
    || fail "apply script does not use the supported stream schema existence check"
grep -Fq 'api_status GET "$schema_path"' "$apply" \
    || fail "apply script does not use the schema existence check before stream creation"
grep -Fq 'streams/$encoded_stream/settings?type=$stream_type' "$apply" \
    || fail "apply script does not use the stream settings endpoint"
grep -Fq '/savedviews' "$apply" \
    || fail "apply script does not provision saved views"
grep -Fq 'api_put "/api/$ORG_PATH/savedviews/$(urlencode "$view_id")"' "$apply" \
    || fail "apply script does not update existing saved views"
grep -Fq 'api_put "/api/v2/$ORG_PATH/alerts/$(urlencode "$alert_id")"' "$apply" \
    || fail "apply script does not update existing alerts"
grep -Fq 'refusing to create duplicate state' "$apply" \
    || fail "apply script does not fail closed when existing-resource listing fails"
if grep -Fq 'exists: $view_name' "$apply" || grep -Fq 'exists: $alert_name' "$apply"; then
    fail "apply script silently skips stale saved views or alerts"
fi
if grep -Eiq 'webhook|smtp|pagerduty|authorization:|bearer ' "$apply"; then
    fail "apply script contains notification credential or delivery configuration"
fi
pass "apply script keeps endpoint, credentials, and notification wiring external"

echo
echo "ALL OPENOBSERVE PROVISIONING TESTS PASSED"
