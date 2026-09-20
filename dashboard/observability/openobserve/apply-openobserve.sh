#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENDPOINT="${OPENOBSERVE_ENDPOINT:-}"
ORG="${OPENOBSERVE_ORG:-}"
USER_NAME="${OPENOBSERVE_USER:-}"
PASSWORD="${OPENOBSERVE_PASSWORD:-}"
PASSWORD_FILE="${OPENOBSERVE_PASSWORD_FILE:-}"
DESTINATION="${OPENOBSERVE_ALERT_DESTINATION_NAME:-}"
APPLY_ALERTS="${OPENOBSERVE_APPLY_ALERTS:-false}"
ENABLE_ALERTS="${OPENOBSERVE_ENABLE_ALERTS:-false}"
ALERT_NAMES="${OPENOBSERVE_ALERT_NAMES:-}"
REPLACE_DASHBOARD="${OPENOBSERVE_REPLACE_DASHBOARD:-false}"

usage() {
    cat <<'EOF'
Usage:
  OPENOBSERVE_ENDPOINT=... OPENOBSERVE_ORG=... \
  OPENOBSERVE_USER=... OPENOBSERVE_PASSWORD=... \
  ./apply-openobserve.sh

  # Or read the password from an operator-managed file:
  OPENOBSERVE_PASSWORD_FILE=/run/secrets/openobserve-password \
  ./apply-openobserve.sh

Optional alert variables:
  OPENOBSERVE_APPLY_ALERTS=true
  OPENOBSERVE_ENABLE_ALERTS=true
  OPENOBSERVE_ALERT_DESTINATION_NAME=operator-configured-destination
  OPENOBSERVE_ALERT_NAMES="Ifritah - Elevated 5xx responses"

The script never creates notification destinations. It only references the
destination name supplied by the operator after external notification wiring
has been completed.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

for command in curl python3; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "required command is missing: $command" >&2
        exit 1
    }
done

if [[ -n "$PASSWORD_FILE" ]]; then
    if [[ ! -r "$PASSWORD_FILE" ]]; then
        echo "OpenObserve password file is not readable: $PASSWORD_FILE" >&2
        exit 1
    fi
    PASSWORD="$(<"$PASSWORD_FILE")"
fi

if [[ -z "$ENDPOINT" || -z "$ORG" || -z "$USER_NAME" || -z "$PASSWORD" ]]; then
    usage >&2
    exit 1
fi

if [[ "$ENABLE_ALERTS" == "true" && -z "$ALERT_NAMES" ]]; then
    echo "OPENOBSERVE_ALERT_NAMES is required when enabling alerts" >&2
    exit 1
fi

ENDPOINT="${ENDPOINT%/}"
ORG_PATH="$(python3 -c 'from urllib.parse import quote; import sys; print(quote(sys.argv[1], safe=""))' "$ORG")"
AUTH=(-u "$USER_NAME:$PASSWORD")
STREAMS_FILE="$SCRIPT_DIR/streams.json"
DASHBOARD_FILE="$SCRIPT_DIR/dashboards/ifritah-operator.json"
SAVED_VIEWS_FILE="$SCRIPT_DIR/saved-views.json"
ALERTS_FILE="$SCRIPT_DIR/alerts.json"

urlencode() {
    python3 -c 'from urllib.parse import quote; import sys; print(quote(sys.argv[1], safe=""))' "$1"
}

api_status() {
    local method="$1"
    local path="$2"
    curl "${AUTH[@]}" --silent --show-error --output /dev/null \
        --write-out '%{http_code}' -X "$method" "$ENDPOINT$path"
}

api_get() {
    local path="$1"
    curl "${AUTH[@]}" --fail --silent --show-error "$ENDPOINT$path"
}

api_post() {
    local path="$1"
    local body="$2"
    curl "${AUTH[@]}" --fail --silent --show-error \
        -H 'Content-Type: application/json' -X POST \
        --data "$body" "$ENDPOINT$path"
}

api_put() {
    local path="$1"
    local body="$2"
    curl "${AUTH[@]}" --fail --silent --show-error \
        -H 'Content-Type: application/json' -X PUT \
        --data "$body" "$ENDPOINT$path"
}

api_delete() {
    local path="$1"
    curl "${AUTH[@]}" --fail --silent --show-error -X DELETE "$ENDPOINT$path"
}

wait_for_status() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local attempts="${4:-10}"
    local delay_seconds="${5:-2}"
    local status=""

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        status="$(api_status "$method" "$path" || true)"
        if [[ "$status" == "$expected" ]]; then
            return 0
        fi
        if (( attempt < attempts )); then
            sleep "$delay_seconds"
        fi
    done
    echo "timed out waiting for HTTP $expected on $path (last status: $status)" >&2
    return 1
}

echo "checking OpenObserve endpoint: $ENDPOINT"
health_status="$(api_status GET "/healthz")"
[[ "$health_status" == "200" ]] || {
    echo "OpenObserve health check returned HTTP $health_status" >&2
    exit 1
}

echo "provisioning streams"
while IFS=$'\t' read -r stream_name stream_type; do
    encoded_stream="$(urlencode "$stream_name")"
    stream_path="/api/$ORG_PATH/streams/$encoded_stream?type=$stream_type"
    schema_path="/api/$ORG_PATH/streams/$encoded_stream/schema?type=$stream_type"
    settings_path="/api/$ORG_PATH/streams/$encoded_stream/settings?type=$stream_type"
    create_body="$(python3 - "$STREAMS_FILE" "$stream_name" <<'PY'
import json
import sys

path, name = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
entry = next(item for item in document["streams"] if item["name"] == name)
print(json.dumps(entry["create"], separators=(",", ":")))
PY
)"
    settings_body="$(python3 - "$STREAMS_FILE" "$stream_name" <<'PY'
import json
import sys

path, name = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
entry = next(item for item in document["streams"] if item["name"] == name)
print(json.dumps(entry["settings"], separators=(",", ":")))
PY
)"
    if [[ "$(api_status GET "$schema_path")" == "200" ]]; then
        echo "  exists: $stream_name"
    else
        api_post "$stream_path" "$create_body" >/dev/null
        wait_for_status GET "$schema_path" 200 10 2
        echo "  created: $stream_name"
    fi
    api_put "$settings_path" "$settings_body" >/dev/null
    echo "  retention applied: $stream_name"
done < <(python3 - "$STREAMS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
for item in document["streams"]:
    print(f'{item["name"]}\t{item["type"]}')
PY
)

metric_policy="$(python3 - "$STREAMS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    policy = json.load(handle).get("metric_stream_policy", {})
print(json.dumps(policy, separators=(",", ":")))
PY
)"
metric_streams="$(api_get "/api/$ORG_PATH/streams?type=metrics")"
while IFS= read -r metric_name; do
    [[ -n "$metric_name" ]] || continue
    encoded_metric="$(urlencode "$metric_name")"
    metric_settings="$(python3 - "$metric_policy" <<'PY'
import json
import sys

policy = json.loads(sys.argv[1])
print(json.dumps({
    "data_retention": policy["retention_days"],
    "max_query_range": policy.get("max_query_range", 24),
}, separators=(",", ":")))
PY
)"
    api_put "/api/$ORG_PATH/streams/$encoded_metric/settings?type=metrics" "$metric_settings" >/dev/null
    echo "  metric retention applied: $metric_name"
done < <(python3 - "$metric_streams" "$metric_policy" <<'PY'
import json
import sys

raw, policy_raw = sys.argv[1:]
value = json.loads(raw)
if isinstance(value, str):
    value = json.loads(value)
policy = json.loads(policy_raw)
approved = {
    name
    for families in policy.get("approved_metric_families", {}).values()
    for name in families
}
items = value.get("list", value if isinstance(value, list) else [])
for item in items:
    name = item.get("name", "") if isinstance(item, dict) else str(item)
    if name in approved:
        print(name)
PY
)

dashboard_title="$(python3 - "$DASHBOARD_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["title"])
PY
)"
dashboard_payload="$(cat "$DASHBOARD_FILE")"
dashboard_query_title="$(urlencode "$dashboard_title")"
dashboard_list="$(api_get "/api/$ORG_PATH/dashboards?folder=default&title=$dashboard_query_title" || true)"
dashboard_id="$(printf '%s' "$dashboard_list" | python3 -c '
import json, sys
title = sys.argv[1]
try:
    value = json.load(sys.stdin)
except Exception:
    value = {}
items = value.get("dashboards", value if isinstance(value, list) else [])
for item in items:
    if item.get("title") == title:
        print(item.get("dashboard_id", ""))
        break
' "$dashboard_title")"
dashboard_hash="$(printf '%s' "$dashboard_list" | python3 -c '
import json, sys
title = sys.argv[1]
try:
    value = json.load(sys.stdin)
except Exception:
    value = {}
items = value.get("dashboards", value if isinstance(value, list) else [])
for item in items:
    if item.get("title") == title:
        print(item.get("hash", ""))
        break
' "$dashboard_title")"

if [[ -n "$dashboard_id" && "$REPLACE_DASHBOARD" == "true" ]]; then
    api_delete "/api/$ORG_PATH/dashboards/$(urlencode "$dashboard_id")?folder=default" >/dev/null
    dashboard_id=""
    dashboard_hash=""
    echo "replaced dashboard: $dashboard_title"
fi

if [[ -n "$dashboard_id" && -n "$dashboard_hash" ]]; then
    api_put "/api/$ORG_PATH/dashboards/$(urlencode "$dashboard_id")?folder=default&hash=$(urlencode "$dashboard_hash")" "$dashboard_payload" >/dev/null
    echo "updated dashboard: $dashboard_title"
else
    api_post "/api/$ORG_PATH/dashboards?folder=default" "$dashboard_payload" >/dev/null
    echo "created dashboard: $dashboard_title"
fi

if ! saved_views="$(api_get "/api/$ORG_PATH/savedviews")"; then
    echo "could not list OpenObserve saved views; refusing to create duplicate state" >&2
    exit 1
fi
echo "provisioning saved views"
while IFS= read -r view_body; do
    view_name="$(printf '%s' "$view_body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["view_name"])')"
    view_id="$(printf '%s' "$saved_views" | python3 -c '
import json, sys
name = sys.argv[1]
try:
    value = json.load(sys.stdin)
except Exception:
    value = {}
def walk(item):
    if isinstance(item, dict):
        if item.get("view_name") == name:
            return item.get("view_id") or item.get("id") or item.get("uuid") or "__MISSING_ID__"
        for child in item.values():
            found = walk(child)
            if found:
                return found
    if isinstance(item, list):
        for child in item:
            found = walk(child)
            if found:
                return found
    return ""
print(walk(value))
' "$view_name")"
    if [[ "$view_id" == "__MISSING_ID__" ]]; then
        echo "saved view '$view_name' exists but has no update ID" >&2
        exit 1
    elif [[ -n "$view_id" ]]; then
        api_put "/api/$ORG_PATH/savedviews/$(urlencode "$view_id")" "$view_body" >/dev/null
        echo "  updated: $view_name"
    else
        api_post "/api/$ORG_PATH/savedviews" "$view_body" >/dev/null
        echo "  created: $view_name"
    fi
done < <(python3 - "$SAVED_VIEWS_FILE" "$ORG" <<'PY'
import json
import sys

path, org = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
for view in document["views"]:
    search_state = {
        "data": {
            "transforms": [],
            "actions": [],
            "transformType": "function",
            "selectedTransform": None,
            "stream": {
                "selectedStream": [view["stream"]],
                "selectedStreamFields": [],
                "interestingFieldList": [],
                "streamType": view["stream_type"],
                "streamLists": [],
                "functions": [],
                "addToFilter": ""
            },
            "query": view["query"],
            "editorValue": view["query"],
            "tempFunctionContent": "",
            "tempFunctionName": "",
            "savedViews": [],
            "queryResults": {},
            "customDownloadQueryObj": {"query": {"from": 0, "size": 200}},
            "histogram": {"xData": [], "yData": [], "chartParams": {}},
            "datetime": {
                "startTime": None,
                "endTime": None,
                "relativeTimePeriod": view["relative_time"],
                "type": "relative",
                "queryRangeRestrictionInHour": 0
            },
            "timezone": "UTC"
        },
        "meta": {
            "refreshInterval": 0,
            "showHistogram": True,
            "showTransformEditor": False,
            "sqlMode": view.get("query_type", "sql") != "promql",
            "quickMode": False,
            "logsVisualizeToggle": "metrics" if view.get("query_type", "sql") == "promql" else "logs",
            "showSearchScheduler": False,
            "jobId": "",
            "jobRecords": 200,
            "regions": [],
            "functionEditorPlaceholderFlag": True,
            "queryEditorPlaceholderFlag": False,
            "logsVisualizeDirtyFlag": False,
            "refreshHistogram": False,
            "toggleFunction": True
        },
        "config": {
            "refreshTimes": [
                {"label": "Off", "value": 0},
                {"label": "1m", "value": 60}
            ],
            "fnSplitterModel": 99.5
        },
        "loading": False,
        "runQuery": False,
        "shouldIgnoreWatcher": False,
        "loadingHistogram": False,
        "organizationIdentifier": org
    }
    print(json.dumps({"data": search_state, "view_name": view["view_name"]}, separators=(",", ":")))
PY
)

if [[ "$APPLY_ALERTS" == "true" && -n "$DESTINATION" ]]; then
    echo "provisioning alert templates"
    if ! existing_alerts="$(api_get "/api/v2/$ORG_PATH/alerts")"; then
        echo "could not list OpenObserve alerts; refusing to create duplicate state" >&2
        exit 1
    fi
    while IFS= read -r alert_body; do
        alert_name="$(printf '%s' "$alert_body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
        alert_result="$(printf '%s' "$existing_alerts" | python3 -c '
import json, sys
name, template, destination, enable_alerts, selected_names = sys.argv[1:]
try:
    value = json.load(sys.stdin)
except Exception:
    value = {}
selected = {item.strip() for item in selected_names.split(",") if item.strip()}
def walk(item):
    if isinstance(item, dict):
        if item.get("name") == name:
            return item
        for child in item.values():
            found = walk(child)
            if found is not None:
                return found
    if isinstance(item, list):
        for child in item:
            found = walk(child)
            if found is not None:
                return found
    return None
existing = walk(value)
payload = json.loads(template)
payload["destinations"] = [destination]
if existing is None:
    payload["enabled"] = enable_alerts.lower() == "true" and name in selected
    alert_id = ""
else:
    alert_id = existing.get("id") or existing.get("alert_id") or existing.get("alertId") or ""
    if not alert_id:
        print("__MISSING_ID__")
        raise SystemExit(0)
    # Updating a definition must not silently disable an operator-enabled
    # alert. Enabling is opt-in and applies only to explicitly selected names.
    if enable_alerts.lower() == "true" and name in selected:
        payload["enabled"] = True
    else:
        current_enabled = existing.get("enabled", payload.get("enabled", False))
        if isinstance(current_enabled, str):
            current_enabled = current_enabled.lower() == "true"
        payload["enabled"] = bool(current_enabled)
    for key in ("folder_id", "owner"):
        if key in existing and key not in payload:
            payload[key] = existing[key]
print(json.dumps({"id": alert_id, "body": payload}, separators=(",", ":")))
' "$alert_name" "$alert_body" "$DESTINATION" "$ENABLE_ALERTS" "$ALERT_NAMES")"
        if [[ "$alert_result" == "__MISSING_ID__" ]]; then
            echo "alert '$alert_name' exists but has no update ID" >&2
            exit 1
        fi
        alert_id="$(printf '%s' "$alert_result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
        alert_body="$(printf '%s' "$alert_result" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["body"], separators=(",", ":")))')"
        if [[ -n "$alert_id" ]]; then
            api_put "/api/v2/$ORG_PATH/alerts/$(urlencode "$alert_id")" "$alert_body" >/dev/null
            echo "  updated alert: $alert_name"
        else
            api_post "/api/v2/$ORG_PATH/alerts" "$alert_body" >/dev/null
            echo "  created alert template: $alert_name"
        fi
    done < <(python3 - "$ALERTS_FILE" "$DESTINATION" "$ENABLE_ALERTS" "$ALERT_NAMES" <<'PY'
import json
import sys

path, destination, enabled, selected_names = sys.argv[1:]
selected = {name.strip() for name in selected_names.split(",") if name.strip()}
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
for alert in document["alerts"]:
    payload = dict(alert)
    payload["destinations"] = [destination]
    payload["enabled"] = enabled.lower() == "true" and alert["name"] in selected
    print(json.dumps(payload, separators=(",", ":")))
PY
)
else
    echo "skipping alerts: set OPENOBSERVE_APPLY_ALERTS=true and configure an external destination name"
fi

echo "OpenObserve UI provisioning complete"
