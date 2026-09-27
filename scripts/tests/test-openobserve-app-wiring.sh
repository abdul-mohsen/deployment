#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-.}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

for script in \
    scripts/lib.sh \
    scripts/create-tenant.sh \
    scripts/update-tenant.sh \
    scripts/deploy-all.sh \
    scripts/post-merge-cleanup.sh \
    scripts/rollback-tenant.sh; do
    tr -d '\r' < "$script" | bash -n || fail "syntax: $script"
done
pass "tenant lifecycle scripts pass bash syntax"

tr -d '\r' < config.env.example | grep -Fx 'OPENOBSERVE_TENANT_TELEMETRY_ENABLED=false' >/dev/null \
    || fail "OpenObserve tenant telemetry is not opt-in by default"
tr -d '\r' < config.env.example | grep -Fx 'OPENOBSERVE_NETWORK_NAME=ifritah-observability-openobserve-ingest' >/dev/null \
    || fail "approved OpenObserve network name is missing from config example"
grep -Fq 'OPENOBSERVE_TENANT_OTLP_TOKEN=replace-with-a-random-otlp-token' config.env.example \
    || fail "deployment OTLP token contract is missing from config example"
grep -Fq 'openobserve_reconcile_tenant_apps "$TENANT_NAME"' scripts/create-tenant.sh \
    || fail "create path does not reconcile OpenObserve wiring"
grep -Fq 'optional,' scripts/update-tenant.sh \
    || fail "update path does not document shared OpenObserve reconciliation"
grep -Fq 'openobserve_reconcile_tenant_apps "$t"' scripts/post-merge-cleanup.sh \
    || fail "existing-tenant cleanup path does not reconcile OpenObserve wiring"
grep -Fq 'dokku() { dk_dokku "$@"' scripts/post-merge-cleanup.sh \
    || fail "existing-tenant cleanup does not route shared Dokku calls through its container"
grep -Fq 'OPENOBSERVE_TENANT_TELEMETRY_ENABLED+x' scripts/post-merge-cleanup.sh \
    || fail "existing-tenant cleanup can skip telemetry config loading"
grep -Fq 'openobserve_reconcile_tenant_apps "$tenant"' scripts/lib.sh \
    || fail "routing/redeploy path does not reconcile OpenObserve wiring"
pass "create, update/redeploy, and migration paths invoke the shared reconciler"

grep -Fq 'docker network create' scripts/lib.sh \
    || fail "network creation helper is missing"
grep -Fq -- '--internal' scripts/lib.sh \
    || fail "network creation is not explicitly internal"
grep -Fq "docker network inspect \"\$network\" --format '{{.Internal}}'" scripts/lib.sh \
    || fail "existing network internal-state validation is missing"
grep -Fq 'openobserve_set_app_networks "$app" "${networks[@]}"' scripts/lib.sh \
    || fail "persistent Dokku telemetry network hook is missing"
grep -Fq 'openobserve_app_network_value "$app" --network-computed-attach-post-deploy' scripts/lib.sh \
    || fail "existing Dokku network settings are not read before telemetry wiring"
grep -Fq 'docker network connect "$network" "$container_id"' scripts/lib.sh \
    || fail "running tenant containers are not connected to the collector network"
grep -Fq 'readonly OPENOBSERVE_DEFAULT_NETWORK_NAME OPENOBSERVE_CORE_NETWORK_NAME OPENOBSERVE_OTLP_ENDPOINT' scripts/lib.sh \
    || fail "approved network and collector endpoint are not protected constants"
grep -Fq 'name: ifritah-observability-openobserve-core' dashboard/docker-compose.openobserve.yml \
    || fail "core observability network is missing"
grep -Fq 'name: ifritah-observability-openobserve-ingest' dashboard/docker-compose.openobserve.yml \
    || fail "tenant ingest network is missing"
grep -Fq 'networks: [openobserve-core, openobserve-ingest]' dashboard/docker-compose.openobserve.yml \
    || fail "Alloy is not the only service bridging ingest and core networks"
if tr -d "\r" < dashboard/docker-compose.openobserve.yml |
    grep -E '^[[:space:]]+networks: \[[^]]*openobserve-ingest' |
    grep -v -Fx '    networks: [openobserve-core, openobserve-ingest]' >/dev/null; then
    fail "core services must not attach to the tenant ingest network"
fi
pass "network validation, persistence, and live-container connection are present"

grep -Fq 'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=${OPENOBSERVE_OTLP_ENDPOINT}' scripts/lib.sh \
    || fail "private OTLP traces endpoint is missing"
grep -Fq 'OPENOBSERVE_OTLP_ENDPOINT="http://alloy-openobserve:4318/v1/traces"' scripts/lib.sh \
    || fail "tenant OTLP traces endpoint is not signal-specific"
grep -Fq 'OTEL_EXPORTER_OTLP_HEADERS=' scripts/lib.sh \
    || fail "tenant OTLP authentication header is missing"
grep -Fq 'OTEL_TRACES_EXPORTER=otlp' scripts/lib.sh \
    || fail "OTEL_TRACES_EXPORTER is missing"
grep -Fq 'OTEL_EXPORTER_OTLP_TRACES_INSECURE=true' scripts/lib.sh \
    || fail "OTEL_EXPORTER_OTLP_TRACES_INSECURE is missing"
grep -Fq 'OTEL_SERVICE_NAME=ifritah-${component}' scripts/lib.sh \
    || fail "service name wiring is missing"
grep -Fq 'OTEL_BSP_MAX_QUEUE_SIZE=' scripts/lib.sh \
    || fail "bounded OTEL queue default is missing"
if grep -Eq 'ZO_ROOT_USER|OPENOBSERVE_(USER|PASSWORD|AUTH)' scripts/lib.sh; then
    fail "tenant wiring contains direct OpenObserve credentials"
fi
if grep -Fq 'OTEL_LOGS_EXPORTER' scripts/lib.sh; then
    fail "tenant wiring must not configure an OTLP log exporter"
fi
pass "trace environment names, bounded defaults, and credential boundary are present"

if grep -Eq '^[[:space:]]+-[[:space:]]*"?[^"]*:(4317|4318):' \
    dashboard/docker-compose.openobserve.yml; then
    fail "OpenObserve OTLP/collector port is publicly published"
fi
pass "OpenObserve OTLP ports remain unbound on the host"

scratch="$REPO_DIR/.openobserve-app-wiring-test.$$"
rm -rf "$scratch"
mkdir -p "$scratch"
trap 'rm -rf "$scratch"' EXIT
export OPENOBSERVE_TEST_LOG="$scratch/commands.log"
export OPENOBSERVE_NETWORK_STATE="$scratch/network.state"
: > "$OPENOBSERVE_TEST_LOG"
rm -f "$OPENOBSERVE_NETWORK_STATE"

source <(tr -d '\r' < scripts/lib.sh)

unset OPENOBSERVE_TENANT_TELEMETRY_ENABLED
[ "$(openobserve_telemetry_mode)" = "disabled" ] \
    || fail "unset telemetry flag is not disabled"
if openobserve_validate_network_name bridge >/dev/null 2>&1; then
    fail "arbitrary bridge network name was accepted"
fi
openobserve_validate_network_name ifritah-observability-openobserve-ingest \
    || fail "approved network name was rejected"
pass "default mode and network allow-list are enforced"

docker() {
    case "${1:-} ${2:-}" in
        "network inspect")
            if [ ! -f "$OPENOBSERVE_NETWORK_STATE" ]; then
                return 1
            fi
            if [[ "$*" == *"--format"* ]]; then
                printf '%s\n' "${OPENOBSERVE_NETWORK_INTERNAL:-true}"
            fi
            ;;
        "network create")
            printf 'network create %s\n' "$*" >> "$OPENOBSERVE_TEST_LOG"
            : > "$OPENOBSERVE_NETWORK_STATE"
            ;;
        "network connect"|"network disconnect")
            printf '%s\n' "$*" >> "$OPENOBSERVE_TEST_LOG"
            ;;
        "ps -q")
            ;;
        *)
            ;;
    esac
}

if ! openobserve_ensure_network ifritah-observability-openobserve-ingest; then
    fail "internal network creation failed in stubbed validation"
fi
if ! openobserve_ensure_network ifritah-observability-openobserve-ingest; then
    fail "existing internal network validation failed"
fi
[ "$(grep -c '^network create' "$OPENOBSERVE_TEST_LOG")" -eq 1 ] \
    || fail "network creation is not idempotent"
pass "internal network creation and reuse are idempotent"

OPENOBSERVE_NETWORK_INTERNAL=false
if openobserve_ensure_network ifritah-observability-openobserve-ingest; then
    fail "non-internal existing network was accepted"
fi
OPENOBSERVE_NETWORK_INTERNAL=true

declare -A TEST_CONFIG=()
declare -A TEST_NETWORKS=(
    ["acme-backend"]="existing-backend-network"
    ["acme-frontend"]="existing-frontend-network"
)
SET_NETWORK_FAILURE=0
dokku() {
    local command="${1:-}"
    shift || true
    case "$command" in
        apps:exists)
            return 0
            ;;
        network:report)
            local app="${1:-}" report_flag="${2:-}"
            case "$report_flag" in
                --network-attach-post-deploy|--network-computed-attach-post-deploy)
                    printf '%s' "${TEST_NETWORKS["$app"]:-}"
                    ;;
            esac
            return 0
            ;;
        network:set)
            local app="$1" key="$2"
            shift 2
            [ "$SET_NETWORK_FAILURE" -eq 1 ] && return 1
            TEST_NETWORKS["$app"]="$*"
            printf 'network:set %s %s %s\n' "$app" "$key" "$*" >> "$OPENOBSERVE_TEST_LOG"
            return 0
            ;;
        config:get)
            printf '%s' "${TEST_CONFIG["$1:$2"]:-}"
            return 0
            ;;
        config:set)
            printf 'config:set %s\n' "$*" >> "$OPENOBSERVE_TEST_LOG"
            [ "${1:-}" = "--no-restart" ] && shift
            local app="$1" pair key value
            shift
            for pair in "$@"; do
                key="${pair%%=*}"
                value="${pair#*=}"
                TEST_CONFIG["$app:$key"]="$value"
            done
            return 0
            ;;
        config:unset)
            [ "${1:-}" = "--no-restart" ] && shift
            local app="$1" key
            shift
            for key in "$@"; do
                unset "TEST_CONFIG[$app:$key]"
            done
            printf 'config:unset %s\n' "$*" >> "$OPENOBSERVE_TEST_LOG"
            return 0
            ;;
        ps:restart)
            printf 'ps:restart %s\n' "$*" >> "$OPENOBSERVE_TEST_LOG"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

OPENOBSERVE_TENANT_OTLP_TOKEN=deployment-token-123456
OPENOBSERVE_TENANT_TELEMETRY_ENABLED=true
openobserve_reconcile_tenant_apps acme
first_config_sets="$(grep -c '^config:set' "$OPENOBSERVE_TEST_LOG")"
[ "$first_config_sets" -eq 4 ] \
    || fail "enabled reconciliation did not capture and configure backend and frontend"
grep -Fq 'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://alloy-openobserve:4318/v1/traces' \
    "$OPENOBSERVE_TEST_LOG" \
    || fail "private collector endpoint was not passed to Dokku"
grep -Fq 'OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic' \
    "$OPENOBSERVE_TEST_LOG" \
    || fail "deployment-provided OTLP authentication header was not passed to Dokku"
grep -Fq 'METRICS_TOKEN=deployment-token-123456' \
    "$OPENOBSERVE_TEST_LOG" \
    || fail "backend metrics authentication token was not passed to Dokku"
grep -Fq 'network:set acme-backend attach-post-deploy existing-backend-network ifritah-observability-openobserve-ingest' \
    "$OPENOBSERVE_TEST_LOG" \
    || fail "backend Dokku networks were not preserved while adding telemetry"
grep -Fq 'network:set acme-frontend attach-post-deploy existing-frontend-network ifritah-observability-openobserve-ingest' \
    "$OPENOBSERVE_TEST_LOG" \
    || fail "frontend Dokku networks were not preserved while adding telemetry"
openobserve_reconcile_tenant_apps acme
[ "$(grep -c '^config:set' "$OPENOBSERVE_TEST_LOG")" -eq "$first_config_sets" ] \
    || fail "repeated reconciliation rewrote unchanged environment"
pass "enabled wiring is idempotent and uses the private collector endpoint"

# A network added by an operator after enablement must survive disablement.
TEST_NETWORKS["acme-backend"]="existing-backend-network post-enable-backend-network ifritah-observability-openobserve-ingest"
TEST_NETWORKS["acme-frontend"]="existing-frontend-network post-enable-frontend-network ifritah-observability-openobserve-ingest"
OPENOBSERVE_TENANT_TELEMETRY_ENABLED=false
openobserve_reconcile_tenant_apps acme
first_config_unsets="$(grep -c '^config:unset' "$OPENOBSERVE_TEST_LOG")"
[ "$first_config_unsets" -eq 2 ] \
    || fail "disable reconciliation did not remove both app environments"
[ "${TEST_NETWORKS["acme-backend"]}" = "existing-backend-network post-enable-backend-network" ] \
    || fail "disable reconciliation did not preserve the backend post-enable network"
[ "${TEST_NETWORKS["acme-frontend"]}" = "existing-frontend-network post-enable-frontend-network" ] \
    || fail "disable reconciliation did not preserve the frontend post-enable network"
openobserve_reconcile_tenant_apps acme
[ "$(grep -c '^config:unset' "$OPENOBSERVE_TEST_LOG")" -eq "$first_config_unsets" ] \
    || fail "repeated disable reconciliation rewrote unchanged environment"
pass "disable wiring removes only the approved network and is idempotent"

# A setter failure is transactional: the current network and capture marker
# remain so a later retry can restore the app safely.
OPENOBSERVE_TENANT_TELEMETRY_ENABLED=true
openobserve_reconcile_tenant_apps acme
SET_NETWORK_FAILURE=1
OPENOBSERVE_TENANT_TELEMETRY_ENABLED=false
if openobserve_reconcile_tenant_apps acme; then
    fail "network:set failure was swallowed during disablement"
fi
[ "${TEST_NETWORKS["acme-backend"]}" = "existing-backend-network post-enable-backend-network ifritah-observability-openobserve-ingest" ] \
    || fail "failed rollback changed backend networks"
[ "${TEST_CONFIG["acme-backend:IFRITAH_OPENOBSERVE_NETWORK_CAPTURED"]:-}" = "1" ] \
    || fail "failed rollback discarded the backend capture marker"
[ -n "${TEST_CONFIG["acme-backend:OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"]:-}" ] \
    || fail "failed rollback discarded backend OTLP configuration"
SET_NETWORK_FAILURE=0
openobserve_reconcile_tenant_apps acme
[ "${TEST_NETWORKS["acme-backend"]}" = "existing-backend-network post-enable-backend-network" ] \
    || fail "retry did not remove only the approved backend network"
pass "network setter failures retain capture state until restoration succeeds"

echo
echo "ALL OPENOBSERVE APPLICATION WIRING TESTS PASSED"
