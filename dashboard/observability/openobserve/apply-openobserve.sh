#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENDPOINT="${OPENOBSERVE_ENDPOINT:-}"
ORG="${OPENOBSERVE_ORG:-}"
USER_NAME="${OPENOBSERVE_USER:-}"
PASSWORD="${OPENOBSERVE_PASSWORD:-}"
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
        echo "  created: $stream_name"
    fi
    api_put "$settings_path" "$settings_body" >/dev/null
    echo "  retention applied: $stream_name"
done < <(python3 "$STREAMS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
for item in document["streams"]:
    print(f'{item["name"]}\t{item["type"]}')
PY
)

dashboard_title="$(python3 "$DASHBOARD_FILE" <<'PY'
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

saved_views="$(api_get "/api/$ORG_PATH/savedviews" || true)"
echo "provisioning saved views"
while IFS= read -r view_body; do
    view_name="$(printf '%s' "$view_body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["view_name"])')"
    view_exists="$(printf '%s' "$saved_views" | python3 -c '
import json, sys
name = sys.argv[1]
try:
    value = json.load(sys.stdin)
except Exception:
    value = {}
def walk(item):
    if isinstance(item, dict):
        if item.get("view_name") == name:
            return True
        return any(walk(child) for child in item.values())
    if isinstance(item, list):
        return any(walk(child) for child in item)
    return False
print("true" if walk(value) else "false")
' "$view_name")"
    if [[ "$view_exists" == "true" ]]; then
        echo "  exists: $view_name"
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
            "sqlMode": True,
            "quickMode": False,
            "logsVisualizeToggle": "logs",
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
    existing_alerts="$(api_get "/api/v2/$ORG_PATH/alerts" || true)"
    while IFS= read -r alert_body; do
        alert_name="$(printf '%s' "$alert_body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
        alert_exists="$(printf '%s' "$existing_alerts" | python3 -c '
import json, sys
name = sys.argv[1]
try:
    value = json.load(sys.stdin)
except Exception:
    value = {}
def walk(item):
    if isinstance(item, dict):
        if item.get("name") == name:
            return True
        return any(walk(child) for child in item.values())
    if isinstance(item, list):
        return any(walk(child) for child in item)
    return False
print("true" if walk(value) else "false")
' "$alert_name")"
        if [[ "$alert_exists" == "true" ]]; then
            echo "  exists: $alert_name"
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
