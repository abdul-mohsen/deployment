#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

contains() {
    local file="$1"
    local text="$2"
    local description="$3"
    grep -Fq -- "$text" "$file" || fail "$description"
    pass "$description"
}

not_contains_regex() {
    local file="$1"
    local pattern="$2"
    local description="$3"
    if grep -Eiq -- "$pattern" "$file"; then
        fail "$description"
    fi
    pass "$description"
}

runbook="docs/runbooks/openobserve-pilot.md"
contract="docs/observability-openobserve-contract.md"
compose="dashboard/docker-compose.openobserve.yml"
config_example="config.env.example"
manifest="dashboard/observability/openobserve/manifest.json"
notifications="dashboard/observability/openobserve/notifications.example.json"
apply="dashboard/observability/openobserve/apply-openobserve.sh"

for path in \
    "$runbook" \
    "$contract" \
    "$compose" \
    "$config_example" \
    "$manifest" \
    "$notifications" \
    "$apply"; do
    [ -f "$path" ] || fail "missing OpenObserve runbook contract file: $path"
done
pass "OpenObserve runbook and supporting contract files are present"

echo "=== runbook sections and contract link ==="
for heading in \
    "## Pilot safety gates" \
    "## Validate and start" \
    "## Opt in tenant applications" \
    "## Disable, rollback, and remove wiring" \
    "## Provision the operator UI" \
    "### External notification wiring" \
    "## Verify provisioning" \
    "## Storage, retention, and backups" \
    "## Restart, upgrade, and stop" \
    "## Rollback and removal" \
    "## Scope boundary"; do
    contains "$runbook" "$heading" "runbook documents $heading"
done
contains "$runbook" "docs/observability-openobserve-contract.md" \
    "runbook links the normative OpenObserve contract"

echo
echo "=== import and apply contract ==="
for text in \
    "dashboard/observability/openobserve/" \
    "dashboards/ifritah-operator.json" \
    "streams.json" \
    "saved-views.json" \
    "alerts.json" \
    "notifications.example.json" \
    "apply-openobserve.sh" \
    "OPENOBSERVE_ENDPOINT=" \
    "OPENOBSERVE_ORG=" \
    "OPENOBSERVE_USER=" \
    "OPENOBSERVE_PASSWORD=" \
    "dashboard import action" \
    "apply streams and saved views" \
    "OPENOBSERVE_REPLACE_DASHBOARD=false" \
    "OPENOBSERVE_APPLY_ALERTS=true" \
    "OPENOBSERVE_ENABLE_ALERTS=false" \
    "OPENOBSERVE_ALERT_NAMES=" \
    "OPENOBSERVE_TENANT_OTLP_TOKEN" \
    "/v1/traces" \
    "ifritah-tenant" \
    "existing saved views and alerts" \
    "heartbeat"; do
    contains "$runbook" "$text" "runbook covers apply/import value: $text"
done
contains "$apply" "OPENOBSERVE_REPLACE_DASHBOARD" \
    "apply script exposes an explicit dashboard replacement guard"
contains "$apply" "OPENOBSERVE_APPLY_ALERTS" \
    "apply script gates alert provisioning"
contains "$apply" "OPENOBSERVE_ALERT_NAMES" \
    "apply script requires explicit alert selection when enabling"

echo
echo "=== external notification contract ==="
for text in \
    "external notification destination" \
    "operator-managed destination" \
    "secret store" \
    "never" \
    "remove the external notification binding" \
    "controlled test notification" \
    "exact name"; do
    contains "$runbook" "$text" "runbook covers notification safety: $text"
done
contains "$notifications" '"destination_name": "REPLACE_WITH_OPERATOR_DESTINATION_NAME"' \
    "notification example keeps destination name as a placeholder"
contains "$notifications" '"endpoint_reference": "REPLACE_WITH_EXTERNAL_SECRET_STORE_REFERENCE"' \
    "notification example keeps secret reference external"
contains "$notifications" '"secret_policy":' \
    "notification example documents external secret policy"
not_contains_regex "$notifications" 'https?://|[[:space:]](password|token|secret)[[:space:]]*=' \
    "notification example contains no endpoint or credential value"
not_contains_regex "$apply" 'webhook|smtp|pagerduty|authorization:|bearer ' \
    "apply script contains no notification delivery credentials"

echo
echo "=== rollback and removal contract ==="
for text in \
    "OPENOBSERVE_TENANT_TELEMETRY_ENABLED=false" \
    "scripts/update-tenant.sh acme --routing-only" \
    "scripts/rollback-tenant.sh" \
    "remove the external notification binding" \
    "Stop or reroute the collector before deleting any contract stream." \
    "docker network inspect ifritah-observability-openobserve" \
    "docker network rm ifritah-observability-openobserve" \
    "without \`--volumes\`" \
    "Never remove the named data, gateway, or Alloy volumes"; do
    contains "$runbook" "$text" "runbook covers rollback/removal guard: $text"
done
if awk '
    /^```/ { in_code = !in_code; next }
    in_code && /docker compose/ && /down/ && /--volumes/ { found = 1 }
    END { exit(found ? 0 : 1) }
' "$runbook"; then
    fail "runbook has a destructive compose-down command"
fi
pass "runbook has no destructive compose-down command"

echo
echo "=== safe pilot operation contract ==="
for text in \
    "parallel to the existing Loki/Grafana profile" \
    "loopback-only" \
    "Internal=true" \
    "absence of host-published OTLP/collector ports" \
    "do not start Docker services" \
    "No image registry or production rollout" \
    "application request calls OpenObserve synchronously" \
    "operator-only"; do
    contains "$runbook" "$text" "runbook covers safe pilot boundary: $text"
done
contains "$config_example" "OPENOBSERVE_TENANT_TELEMETRY_ENABLED=false" \
    "tenant telemetry remains opt-in in the config example"
contains "$compose" 'profiles: ["openobserve"]' \
    "OpenObserve services remain profile-gated"
contains "$compose" '127.0.0.1}:${OBS_OPENOBSERVE_PORT:-5080}:5080' \
    "OpenObserve host publication remains loopback-only"
contains "$compose" 'name: ifritah-observability-openobserve' \
    "OpenObserve network has the approved stable name"
contains "$compose" "internal: true" \
    "OpenObserve network is internal-only"
not_contains_regex "$compose" '^[[:space:]]+-[[:space:]]*"?[^"]*:(4317|4318):' \
    "OpenObserve OTLP ports are not host-published"

echo
echo "ALL OPENOBSERVE RUNBOOK CONTRACT TESTS PASSED"
