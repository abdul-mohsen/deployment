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
alloy="$root/config.alloy"

for path in "$manifest" "$streams" "$dashboard" "$views" "$alerts" "$notifications" "$apply" "$alloy"; do
    [ -f "$path" ] || fail "missing OpenObserve provisioning file: $path"
done
pass "OpenObserve provisioning inventory is present"

python3 - "$manifest" "$streams" "$dashboard" "$views" "$alerts" "$notifications" "$apply" "$alloy" <<'PY'
import json
import re
import sys
from pathlib import Path

(
    manifest_path,
    streams_path,
    dashboard_path,
    views_path,
    alerts_path,
    notifications_path,
    apply_path,
    alloy_path,
) = sys.argv[1:]

def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

manifest = load(manifest_path)
stream_doc = load(streams_path)
dashboard = load(dashboard_path)
views = load(views_path)
alerts = load(alerts_path)
notifications = load(notifications_path)
apply_text = Path(apply_path).read_text(encoding="utf-8")
alloy_text = Path(alloy_path).read_text(encoding="utf-8")

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
for document in (stream_doc, manifest):
    health = document["health_signal"]
    assert health["ingress_path"] == "/v1/health"
    assert health["signal_type"] == "metrics"
    assert health["query_mode"] == "promql"
    assert health["retention_days"] == 15
    assert "ifritah_gateway_" in health["metric_name_prefixes"]
    assert "otelcol_" in health["metric_name_prefixes"]
metric_policy = stream_doc["metric_stream_policy"]
assert metric_policy["retention_days"] == 15
assert metric_policy["max_query_range"] == 24
families = metric_policy["approved_metric_families"]
assert set(families) == {"backend", "resource", "health"}
assert "allowed_name_prefixes" not in metric_policy
manifest_policy = manifest["metric_stream_policy"]
assert manifest_policy["retention_days"] == metric_policy["retention_days"]
assert manifest_policy["max_query_range"] == metric_policy["max_query_range"]
assert manifest_policy["approved_metric_families"] == families
approved_metric_names = set()
for source, names in families.items():
    assert names, source
    assert len(names) == len(set(names)), f"duplicate approved metric in {source}"
    approved_metric_names.update(names)

assert "approved_metric_families" in apply_text
assert "allowed_name_prefixes" not in apply_text
assert "if name in approved" in apply_text

for source, names in families.items():
    match = re.search(
        rf'otelcol\.processor\.filter "{source}_metrics".*?'
        r'not IsMatch\(name, "([^"]+)"\)',
        alloy_text,
        re.S,
    )
    assert match, f"missing exact {source} metric-family filter"
    pattern_text = match.group(1)
    pattern = re.compile(pattern_text)
    assert pattern_text.startswith("^") and pattern_text.endswith("$")
    assert pattern_text.startswith("^(") and pattern_text.endswith(")$")
    regex_names = set(pattern_text[2:-2].split("|"))
    assert regex_names == set(names), source
    assert all(pattern.fullmatch(name) for name in names), source

unapproved_by_source = {
    "backend": ["ifritah_http_requests_total_extra"],
    "resource": [
        "node_cpu_seconds_total_extra",
        "ifritah_container_request_id_bytes",
    ],
    "health": [
        "ifritah_gateway_secret_tokens_total",
        "alloy_build_info_extra",
        "otelcol_exporter_sent_metric_points_extra",
    ],
}
for source, candidates in unapproved_by_source.items():
    match = re.search(
        rf'otelcol\.processor\.filter "{source}_metrics".*?'
        r'not IsMatch\(name, "([^"]+)"\)',
        alloy_text,
        re.S,
    )
    for candidate in candidates:
        assert candidate not in families[source], (
            f"unapproved family listed for {source}: {candidate}"
        )
        assert not re.fullmatch(match.group(1), candidate), (
            f"unapproved family accepted by {source} filter: {candidate}"
        )

assert dashboard["version"] == 5
assert dashboard["title"] == "Ifritah OpenObserve Operations"
assert dashboard["dashboardId"] == ""
panels = dashboard["tabs"][0]["panels"]
assert len(panels) >= 8
for panel in panels:
    assert panel["id"] and panel["title"] and panel["queryType"] in {"sql", "promql"}
    layout = panel["layout"]
    assert isinstance(layout["i"], int)
    assert 0 <= layout["x"] <= 47
    assert 1 <= layout["w"] <= 48
    assert layout["x"] + layout["w"] <= 48
    assert layout["h"] > 0
    for query in panel["queries"]:
        assert query["customQuery"] is True
        assert isinstance(query["fields"]["x"], list)
        assert isinstance(query["fields"]["y"], list)
        assert query["fields"]["z"] == []
        assert query["fields"]["filter"] == {
            "filterType": "group",
            "logicalOperator": "AND",
            "conditions": [],
        }
        if panel["queryType"] == "sql":
            assert query["fields"]["stream"] in expected
        else:
            assert query["fields"]["stream"] not in expected
            assert query["fields"]["stream_type"] == "metrics"
            assert query["vrlFunctionQuery"] == ""
            assert isinstance(query["fields"]["promql_labels"], list)
            assert isinstance(query["fields"]["promql_operations"], list)
            assert query["config"]["step_value"] is None
            assert "promql_legend" in query["config"]

assert len(views["views"]) >= 8
for view in views["views"]:
    assert view["relative_time"] in {"1h", "24h", "7d"}
    if view.get("query_type", "sql") == "promql":
        assert view["stream"] not in expected
        assert view["stream_type"] == "metrics"
        assert "_timestamp" not in view["query"]
    else:
        assert view["stream"] in expected
        assert "_timestamp >= now() - INTERVAL" in view["query"]
        assert "LIMIT " in view["query"]

assert len(alerts["alerts"]) >= 15
assert alerts["destination_placeholder"] == "${OPENOBSERVE_ALERT_DESTINATION_NAME}"
for alert in alerts["alerts"]:
    query_condition = alert["query_condition"]
    if query_condition["type"] == "sql":
        assert alert["stream_name"] in expected
        assert "_timestamp >= now() - INTERVAL" in query_condition["sql"]
    else:
        assert query_condition["type"] == "promql"
        assert alert["stream_name"] not in expected
        assert query_condition["promql"]
        assert {
            "column",
            "operator",
            "value",
        } <= set(query_condition["promql_condition"])
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
    query = alert["query_condition"].get("promql", "")
    assert metric_name in query, f"{name} does not use {metric_name}"
    assert metric_name in approved_metric_names, (
        f"{name} uses a metric family outside the approved policy: {metric_name}"
    )
    assert alert["query_condition"]["type"] == "promql"
    assert alert["stream_name"] == metric_name
    assert alert["destinations"] == ["${OPENOBSERVE_ALERT_DESTINATION_NAME}"]
    assert alert["enabled"] is False

for name in (
    "Ifritah - Container restart loop",
    "Ifritah - Resource exporter scrape errors",
    "Ifritah - Telemetry gateway health",
):
    assert "increase(" in alerts_by_name[name]["query_condition"]["promql"], name

for name in (
    "Ifritah - Resource exporter health",
    "Ifritah - Telemetry gateway heartbeat missing",
):
    alert = alerts_by_name[name]
    assert alert["trigger_condition"]["operator"] == "<", name
    assert alert["query_condition"]["promql_condition"]["operator"] == "<", name

for name, counter in {
    "Ifritah - Resource exporter scrape errors": "ifritah_resource_exporter_scrape_errors_total",
    "Ifritah - Telemetry gateway health": "ifritah_gateway_forward_failures_total",
}.items():
    query = alerts_by_name[name]["query_condition"]["promql"]
    assert counter in query

all_json = json.dumps([manifest, stream_doc, dashboard, views, alerts, notifications])
assert "ifritah_telemetry_health_v1" not in all_json
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
grep -Fq 'wait_for_status GET "$schema_path" 200' "$apply" \
    || fail "apply script does not wait for eventual stream schema consistency"
grep -Fq 'streams/$encoded_stream/settings?type=$stream_type' "$apply" \
    || fail "apply script does not use the stream settings endpoint"
grep -Fq '/api/$ORG_PATH/streams?type=metrics' "$apply" \
    || fail "apply script does not discover native metric streams"
grep -Fq 'approved_metric_families' "$apply" \
    || fail "apply script does not use the approved native metric-family policy"
grep -Fq 'if name in approved' "$apply" \
    || fail "apply script does not use exact native metric-family membership"
if grep -Fq 'startswith(prefixes)' "$apply"; then
    fail "apply script still uses broad native metric-family prefix retention"
fi
grep -Fq 'view.get("query_type", "sql")' "$apply" \
    || fail "apply script does not preserve PromQL saved-view mode"
grep -Fq '/savedviews' "$apply" \
    || fail "apply script does not provision saved views"
grep -Fq 'api_put "/api/$ORG_PATH/savedviews/$(urlencode "$view_id")"' "$apply" \
    || fail "apply script does not update existing saved views"
grep -Fq 'api_put "/api/v2/$ORG_PATH/alerts/$(urlencode "$alert_id")"' "$apply" \
    || fail "apply script does not update existing alerts"
grep -Fq 'discover_resource dashboard "$dashboard_title"' "$apply" \
    || fail "apply script does not validate dashboard discovery responses"
grep -Fq 'discover_resource saved_view "$view_name"' "$apply" \
    || fail "apply script does not validate saved-view discovery responses"
grep -Fq 'discover_resource alert "$alert_name"' "$apply" \
    || fail "apply script does not validate alert discovery responses"
grep -Fq 'could not validate OpenObserve dashboard list response' "$apply" \
    || fail "apply script does not fail closed on malformed dashboard responses"
grep -Fq 'could not validate OpenObserve saved view list response' "$apply" \
    || fail "apply script does not fail closed on malformed saved-view responses"
grep -Fq 'could not validate OpenObserve alert list response' "$apply" \
    || fail "apply script does not fail closed on malformed alert responses"
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
