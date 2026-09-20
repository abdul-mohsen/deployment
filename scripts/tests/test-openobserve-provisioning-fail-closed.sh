#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "$description"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"
    [[ "$haystack" != *"$needle"* ]] || fail "$description"
}

apply="${OPENOBSERVE_APPLY_SCRIPT:-dashboard/observability/openobserve/apply-openobserve.sh}"
test_root="$REPO_DIR/.openobserve-provisioning-fail-closed-test.$$"
rm -rf "$test_root"
mkdir -p "$test_root/bin"
trap 'rm -rf "$test_root"' EXIT

cat > "$test_root/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
status_only=false
previous=""
url=""
for argument in "$@"; do
    [[ "$previous" == "-X" ]] && method="$argument"
    [[ "$argument" == "--write-out" ]] && status_only=true
    previous="$argument"
    url="$argument"
done

scenario="${OPENOBSERVE_TEST_SCENARIO:-valid-empty}"
log_file="${OPENOBSERVE_TEST_LOG:?}"
printf '%s %s\n' "$method" "$url" >>"$log_file"

if [[ "$status_only" == true ]]; then
    printf '200'
    exit 0
fi

if [[ "$method" == "GET" && "$url" == *"/dashboards?folder="* ]]; then
    case "$scenario" in
        dashboard-list-failure)
            exit 22
            ;;
        dashboard-malformed)
            printf '{not-json'
            ;;
        dashboard-invalid-shape)
            printf '{"dashboards":{}}'
            ;;
        valid-existing)
            printf '{"dashboards":[{"title":"Ifritah OpenObserve Operations","dashboard_id":"dashboard-1","hash":"hash-1"}]}'
            ;;
        *)
            printf '{"dashboards":[]}'
            ;;
    esac
    exit 0
fi

if [[ "$method" == "GET" && "$url" == *"/savedviews" ]]; then
    case "$scenario" in
        saved-view-list-failure)
            exit 22
            ;;
        saved-view-malformed)
            printf 'not-json'
            ;;
        saved-view-invalid-shape)
            printf '{"views":{}}'
            ;;
        *)
            printf '{"views":[]}'
            ;;
    esac
    exit 0
fi

if [[ "$method" == "GET" && "$url" == *"/alerts" ]]; then
    case "$scenario" in
        alert-list-failure)
            exit 22
            ;;
        alert-malformed)
            printf 'not-json'
            ;;
        alert-invalid-shape)
            printf '{"alerts":null}'
            ;;
        *)
            printf '{"alerts":[]}'
            ;;
    esac
    exit 0
fi

if [[ "$method" == "GET" && "$url" == *"/streams?type=metrics" ]]; then
    printf '{"list":[]}'
    exit 0
fi

printf '{}'
STUB
chmod +x "$test_root/bin/curl"

run_failure_case() {
    local description="$1"
    local scenario="$2"
    local expected_message="$3"
    local forbidden_post="$4"
    local output

    : > "$test_root/commands.log"
    export OPENOBSERVE_TEST_SCENARIO="$scenario"
    export OPENOBSERVE_TEST_LOG="$test_root/commands.log"
    export OPENOBSERVE_ENDPOINT="http://fake-openobserve"
    export OPENOBSERVE_ORG="default"
    export OPENOBSERVE_USER="operator"
    export OPENOBSERVE_PASSWORD="password"
    export OPENOBSERVE_APPLY_ALERTS="false"
    unset OPENOBSERVE_ALERT_DESTINATION_NAME

    if [[ "$scenario" == alert-* ]]; then
        export OPENOBSERVE_APPLY_ALERTS="true"
        export OPENOBSERVE_ALERT_DESTINATION_NAME="operator-destination"
    fi

    if output="$(PATH="$test_root/bin:$PATH" bash "$apply" 2>&1)"; then
        fail "$description unexpectedly succeeded"
    fi
    assert_contains "$output" "$expected_message" "$description did not fail closed"
    assert_not_contains "$(cat "$test_root/commands.log")" "$forbidden_post" \
        "$description attempted to create state after discovery failure"
    pass "$description"
}

run_failure_case \
    "malformed dashboard JSON" \
    "dashboard-malformed" \
    "could not validate OpenObserve dashboard list response" \
    "POST http://fake-openobserve/api/default/dashboards?folder=default"
run_failure_case \
    "schema-invalid dashboard list" \
    "dashboard-invalid-shape" \
    "could not validate OpenObserve dashboard list response" \
    "POST http://fake-openobserve/api/default/dashboards?folder=default"
run_failure_case \
    "dashboard list failure" \
    "dashboard-list-failure" \
    "could not list OpenObserve dashboards" \
    "POST http://fake-openobserve/api/default/dashboards?folder=default"
run_failure_case \
    "schema-invalid saved-view list" \
    "saved-view-invalid-shape" \
    "could not validate OpenObserve saved view list response" \
    "POST http://fake-openobserve/api/default/savedviews"
run_failure_case \
    "malformed saved-view JSON" \
    "saved-view-malformed" \
    "could not validate OpenObserve saved view list response" \
    "POST http://fake-openobserve/api/default/savedviews"
run_failure_case \
    "saved-view list failure" \
    "saved-view-list-failure" \
    "could not list OpenObserve saved views" \
    "POST http://fake-openobserve/api/default/savedviews"
run_failure_case \
    "malformed alert JSON" \
    "alert-malformed" \
    "could not validate OpenObserve alert list response" \
    "POST http://fake-openobserve/api/v2/default/alerts"
run_failure_case \
    "schema-invalid alert list" \
    "alert-invalid-shape" \
    "could not validate OpenObserve alert list response" \
    "POST http://fake-openobserve/api/v2/default/alerts"
run_failure_case \
    "alert list failure" \
    "alert-list-failure" \
    "could not list OpenObserve alerts" \
    "POST http://fake-openobserve/api/v2/default/alerts"

: > "$test_root/commands.log"
export OPENOBSERVE_TEST_SCENARIO="valid-existing"
export OPENOBSERVE_TEST_LOG="$test_root/commands.log"
export OPENOBSERVE_ENDPOINT="http://fake-openobserve"
export OPENOBSERVE_ORG="default"
export OPENOBSERVE_USER="operator"
export OPENOBSERVE_PASSWORD="password"
export OPENOBSERVE_APPLY_ALERTS="true"
export OPENOBSERVE_ALERT_DESTINATION_NAME="operator-destination"
output="$(PATH="$test_root/bin:$PATH" bash "$apply" 2>&1)" \
    || fail "valid discovery responses did not preserve reconciliation"
assert_contains "$output" "updated dashboard: Ifritah OpenObserve Operations" \
    "valid dashboard discovery did not preserve update behavior"
assert_contains "$output" "created alert template:" \
    "valid alert discovery did not preserve create behavior"
assert_contains "$(cat "$test_root/commands.log")" \
    "PUT http://fake-openobserve/api/default/dashboards/dashboard-1" \
    "valid dashboard discovery did not issue an update"
assert_contains "$(cat "$test_root/commands.log")" \
    "POST http://fake-openobserve/api/v2/default/alerts" \
    "valid alert discovery did not issue creates"
pass "valid discovery responses preserve update/create behavior"

echo
echo "ALL OPENOBSERVE FAIL-CLOSED PROVISIONING TESTS PASSED"
