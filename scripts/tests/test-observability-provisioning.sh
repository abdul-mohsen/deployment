#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

dashboard_provider="dashboard/observability/grafana/provisioning/dashboards/provider.yml"
datasources="dashboard/observability/grafana/provisioning/datasources/datasources.yml"
alert_rules="dashboard/observability/grafana/provisioning/alerting/alert-rules.yml"
compose="dashboard/docker-compose.observability.yml"
uptime="dashboard/observability/uptime/monitor.example.json"

echo "=== Grafana provisioning inventory ==="
for path in \
    "$dashboard_provider" \
    "$datasources" \
    "$alert_rules" \
    "$uptime" \
    dashboard/observability/grafana/provisioning/dashboards-json/ifritah-operations.json \
    dashboard/observability/grafana/provisioning/dashboards-json/ifritah-log-operations.json \
    dashboard/observability/grafana/alerting-templates/contact-points.yml.example \
    dashboard/observability/grafana/alerting-templates/policies.yml.example; do
    [ -f "$path" ] || fail "missing observability file: $path"
done
pass "dashboard, alerting, notification, and uptime files are present"

echo
echo "=== Dashboard JSON contracts ==="
python3 - \
    dashboard/observability/grafana/provisioning/dashboards-json/ifritah-operations.json \
    dashboard/observability/grafana/provisioning/dashboards-json/ifritah-log-operations.json \
    "$uptime" <<'PY'
import json
import sys

dashboard_uids = {"ifritah-ops", "ifritah-logs"}
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
    if path.endswith("monitor.example.json"):
        monitor = value["monitor"]
        assert monitor["url"].endswith("/healthz")
        assert monitor["expected_status"] == 200
        assert monitor["expected_body"] == "ok"
        assert monitor["verify_tls"] is True
        continue
    assert value["uid"] in dashboard_uids
    assert value["editable"] is False
    assert value["title"].startswith("Ifritah ")
    panels = value["panels"]
    assert any(panel.get("type") == "logs" for panel in panels)
    query_text = json.dumps(value)
    assert "ifritah-loki" in query_text
    if value["uid"] == "ifritah-ops":
        assert "ifritah-prometheus" in query_text
print("valid JSON and datasource references")
PY
pass "dashboard and uptime JSON parses with bounded queries"

echo
echo "=== Provisioning contracts ==="
grep -Fq 'path: /etc/grafana/provisioning/dashboards-json' "$dashboard_provider" \
    || fail "dashboard provider path is not explicit"
grep -Fq 'uid: ifritah-loki' "$datasources" \
    || fail "Loki datasource UID is missing"
grep -Fq 'uid: ifritah-prometheus' "$datasources" \
    || fail "Prometheus datasource UID is missing"
grep -Fq 'uid: ifritah_component_down' "$alert_rules" \
    || fail "component-down alert is missing"
grep -Fq 'uid: ifritah_dashboard_errors' "$alert_rules" \
    || fail "dashboard-error alert is missing"
grep -Fq 'uid: ifritah_dashboard_panics' "$alert_rules" \
    || fail "panic-recovery alert is missing"
grep -Fq 'noDataState: Alerting' "$alert_rules" \
    || fail "component-down alert does not fail closed on missing data"
grep -Fq 'runbook: alert-triage' "$alert_rules" \
    || fail "alerts do not link to the triage runbook"
grep -Fq 'OBS_ALERT_SLACK_WEBHOOK_URL' dashboard/observability/grafana/alerting-templates/contact-points.yml.example \
    || fail "Slack contact-point template is missing"
grep -Fq 'OBS_ALERT_EMAIL_TO' dashboard/observability/grafana/alerting-templates/contact-points.yml.example \
    || fail "email contact-point template is missing"
grep -Fq 'dashboard/observability/grafana/provisioning/alerting/contact-points.yml' .gitignore \
    || fail "contact-point file is not ignored"
grep -Fq 'dashboard/observability/grafana/provisioning/alerting/policies.yml' .gitignore \
    || fail "notification policy file is not ignored"
pass "Grafana resources and optional notification templates are wired"

echo
echo "=== Internal-only notification boundary ==="
grep -Fq 'GF_UNIFIED_ALERTING_ENABLED: "true"' "$compose" \
    || fail "Grafana unified alerting is not enabled"
grep -Fq 'GF_METRICS_ENABLED: "true"' "$compose" \
    || fail "Grafana metrics are not enabled"
grep -Fq 'OBS_ALERT_SLACK_WEBHOOK_URL:' "$compose" \
    || fail "Slack environment handoff is missing"
grep -Fq 'OBS_ALERT_EMAIL_TO:' "$compose" \
    || fail "email environment handoff is missing"
grep -Fq 'observability:' "$compose" \
    || fail "observability network is missing"
for image in \
    'grafana/alloy:v1.5.1@sha256:' \
    'grafana/loki:3.3.2@sha256:' \
    'prom/prometheus:v3.1.0@sha256:' \
    'grafana/grafana:11.5.2@sha256:'; do
    grep -Fq "image: ${image}" "$compose" \
        || fail "rollback observability image is not digest-pinned: ${image}"
done
awk '/^  observability:/{section=1} /^networks:/{if (section) exit} section{print}' "$compose" |
    grep -Fq 'internal: true' \
    || fail "observability network is not internal-only"
if grep -Eq '^[[:space:]]+ports:' "$compose" &&
    ! grep -Fq '"127.0.0.1:${OBS_GRAFANA_PORT:-3000}:3000"' "$compose"; then
    fail "observability profile publishes a non-loopback port"
fi
pass "alert delivery remains opt-in and the observability network stays private"

echo
echo "ALL OBSERVABILITY PROVISIONING TESTS PASSED"
