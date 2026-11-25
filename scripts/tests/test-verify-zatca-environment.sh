#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

VERIFY_SCRIPT="scripts/verify-zatca-environment.sh"
COMPOSE_FILE="dashboard/docker-compose.zatca.yml"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
not_contains() { ! grep -Fq -- "$2" "$1" || fail "$3"; }

[ -f "$COMPOSE_FILE" ] || fail "$COMPOSE_FILE is missing"

echo "=== isolated verification Compose profile ==="
grep -qF 'x-zatca-daemon-environment: &zatca-daemon-environment' "$COMPOSE_FILE" \
    || fail "shared daemon environment anchor is missing"
[ "$(grep -Fc 'environment: *zatca-daemon-environment' "$COMPOSE_FILE")" -ge 2 ] \
    || fail "daemon and check services do not share the same environment mapping"
grep -qF 'zatca-check:' "$COMPOSE_FILE" || fail "one-shot check service is missing"
check_service="$(awk '
    /^  zatca-check:$/ { capture = 1; print; next }
    capture && /^  [[:alnum:]_-]+:$/ { exit }
    capture { print }
' "$COMPOSE_FILE")"
[ -n "$check_service" ] || fail "could not locate the check service in Compose"
if printf '%s\n' "$check_service" | grep -Eq '^[[:space:]]+(ports|volumes|depends_on):'; then
    fail "check service publishes ports, persists volumes, or depends on NATS"
fi
printf '%s\n' "$check_service" | grep -qF 'profiles: ["zatca-check"]' \
    || fail "check service is not isolated behind the zatca-check profile"
printf '%s\n' "$check_service" | grep -qF 'environment: *zatca-daemon-environment' \
    || fail "check service does not reuse the daemon environment"
printf '%s\n' "$check_service" | grep -qF -- '- "--verify-db"' \
    || fail "check service does not use the flag-based verification mode"
printf '%s\n' "$check_service" | grep -qF -- '- "--json"' \
    || fail "check service does not request the JSON protocol"
pass "check service shares configuration and is isolated from runtime side effects"

[ -f "$VERIFY_SCRIPT" ] || fail "$VERIFY_SCRIPT has not been implemented"

TEST_REPO="$TEST_ROOT/repo"
BIN="$TEST_ROOT/bin"
OUTPUT="$TEST_ROOT/output"
DOCKER_LOG="$TEST_ROOT/docker.log"
COMPOSE_JSON_FILE="$TEST_ROOT/compose.json"
RUNNING_ENV_FILE="$TEST_ROOT/running-env.json"
DAEMON_REPORT_FILE="$TEST_ROOT/daemon-report.json"
mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/dashboard" "$BIN"
cp "$VERIFY_SCRIPT" "$TEST_REPO/scripts/"
cp scripts/setup-zatca-daemon.sh scripts/health-zatca-daemon.sh scripts/lib.sh "$TEST_REPO/scripts/"
cp "$COMPOSE_FILE" "$TEST_REPO/dashboard/"

write_config() {
    cat > "$1" <<'CONFIG'
ZATCA_DAEMON_ENABLED=1
ZATCA_DAEMON_IMAGE=local/zatca-daemon:verify-test
ZATCA_DAEMON_CONTAINER=zatca-daemon-verify-test
ZATCA_NATS_DATA_ROOT=/tmp/zatca-verify-test
ZATCA_DB_USER=runtime-user
ZATCA_DB_PASSWORD=DB_PASSWORD_FIXTURE
MYSQL_HOST=db.test.internal
MYSQL_PORT=3307
MYSQL_MASTER_DB=zatca_master
ZATCA_ADMIN_DB_USER=onboarding-user
ZATCA_ADMIN_DB_PASSWORD=ADMIN_PASSWORD_FIXTURE
ZATCA_ADMIN_DB_HOST=admin-db.test.internal
ZATCA_ENCRYPT_KEY=ENCRYPTION_KEY_FIXTURE
ZATCA_MONITOR_PASSWORD=MONITOR_PASSWORD_FIXTURE
NATS_USER=daemon-user
NATS_PASSWORD=NATS_PASSWORD_FIXTURE
NATS_PRIVATE_NETWORK_ONLY=true
NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED=true
NATS_SHARED_CREDENTIALS_ACKNOWLEDGED=true
NATS_SHARED_CREDENTIALS_APPROVAL_ID=VERIFY-TEST-APPROVAL
NATS_SHARED_CREDENTIALS_EXPIRES=2099-12-31
ZATCA_SMTP_HOST=smtp.test.internal
ZATCA_SMTP_PORT=2525
ZATCA_SMTP_USER=smtp-user
ZATCA_SMTP_PASSWORD=SMTP_PASSWORD_FIXTURE
ZATCA_SMTP_FROM=zatca-test@example.invalid
CONFIG
}

write_compose_json() {
    cat > "$COMPOSE_JSON_FILE" <<'JSON'
{"services":{"zatca-daemon":{"environment":{
  "DB_USER":"runtime-user",
  "DB_PASS":"DB_PASSWORD_FIXTURE",
  "DB_HOST":"db.test.internal",
  "DB_PORT":"3307",
  "MASTER_DB":"zatca_master",
  "ADMIN_DB_USER":"onboarding-user",
  "ADMIN_DB_PASS":"ADMIN_PASSWORD_FIXTURE",
  "ADMIN_DB_HOST":"admin-db.test.internal",
  "ENCRYPT_KEY":"ENCRYPTION_KEY_FIXTURE",
  "NATS_USER":"daemon-user",
  "NATS_PASSWORD":"NATS_PASSWORD_FIXTURE",
  "NATS_ALLOW_UNAUTHENTICATED":"false",
  "NATS_LOCAL_TEST_MODE":"false",
  "NATS_PRIVATE_NETWORK_ONLY":"true",
  "NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED":"true",
  "NATS_SHARED_CREDENTIALS_ACKNOWLEDGED":"true",
  "NATS_SHARED_CREDENTIALS_APPROVAL_ID":"VERIFY-TEST-APPROVAL",
  "NATS_SHARED_CREDENTIALS_EXPIRES":"2099-12-31",
  "MONITOR_PASS":"MONITOR_PASSWORD_FIXTURE",
  "NATS_MONITOR_PRIVATE_NETWORK_ONLY":"true",
  "NATS_MONITOR_LOCAL_TEST_MODE":"false",
  "SMTP_HOST":"smtp.test.internal",
  "SMTP_PORT":"2525",
  "SMTP_USER":"smtp-user",
  "SMTP_PASS":"SMTP_PASSWORD_FIXTURE",
  "SMTP_FROM":"zatca-test@example.invalid"
}}}}
JSON
}

write_running_env() {
    cat > "$RUNNING_ENV_FILE" <<'JSON'
[
  "DB_USER=runtime-user",
  "DB_PASS=DB_PASSWORD_FIXTURE",
  "DB_HOST=db.test.internal",
  "DB_PORT=3307",
  "MASTER_DB=zatca_master",
  "ADMIN_DB_USER=onboarding-user",
  "ADMIN_DB_PASS=ADMIN_PASSWORD_FIXTURE",
  "ADMIN_DB_HOST=admin-db.test.internal",
  "ENCRYPT_KEY=ENCRYPTION_KEY_FIXTURE",
  "NATS_USER=daemon-user",
  "NATS_PASSWORD=NATS_PASSWORD_FIXTURE",
  "NATS_ALLOW_UNAUTHENTICATED=false",
  "NATS_LOCAL_TEST_MODE=false",
  "NATS_PRIVATE_NETWORK_ONLY=true",
  "NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED=true",
  "NATS_SHARED_CREDENTIALS_ACKNOWLEDGED=true",
  "NATS_SHARED_CREDENTIALS_APPROVAL_ID=VERIFY-TEST-APPROVAL",
  "NATS_SHARED_CREDENTIALS_EXPIRES=2099-12-31",
  "MONITOR_PASS=MONITOR_PASSWORD_FIXTURE",
  "NATS_MONITOR_PRIVATE_NETWORK_ONLY=true",
  "NATS_MONITOR_LOCAL_TEST_MODE=false",
  "SMTP_HOST=smtp.test.internal",
  "SMTP_PORT=2525",
  "SMTP_USER=smtp-user",
  "SMTP_PASS=SMTP_PASSWORD_FIXTURE",
  "SMTP_FROM=zatca-test@example.invalid"
]
JSON
}

write_pass_report() {
    cat > "$DAEMON_REPORT_FILE" <<'JSON'
{"schema_version":1,"overall_status":"PASS","checks":[{"id":"master.connection","status":"PASS","target":{"account_role":"runtime","database":"zatca_master","operation":"connect"}},{"id":"master.registry","status":"PASS","target":{"account_role":"runtime","database":"zatca_master","operation":"load_enabled_tenants"}},{"id":"tenant.1.runtime.connection","status":"PASS","target":{"account_role":"runtime","tenant_id":"1","database":"tenant_one","operation":"connect"}},{"id":"tenant.1.schema","status":"PASS","target":{"account_role":"runtime","tenant_id":"1","database":"tenant_one","operation":"schema_preflight"}},{"id":"tenant.1.active_branches","status":"PASS","target":{"account_role":"runtime","tenant_id":"1","database":"tenant_one","operation":"discover_active_branches"}},{"id":"tenant.1.branch.11.config","status":"PASS","target":{"account_role":"runtime","tenant_id":"1","database":"tenant_one","branch_id":11,"operation":"load_and_decrypt_branch_config"}},{"id":"tenant.1.runtime.read_bill","status":"PASS","target":{"account_role":"runtime","tenant_id":"1","database":"tenant_one","operation":"runtime.read_bill"}},{"id":"tenant.1.runtime.write_submission","status":"PASS","target":{"account_role":"runtime","tenant_id":"1","database":"tenant_one","operation":"runtime.write_submission"}},{"id":"tenant.1.runtime.onboarding.read_branch","status":"PASS","target":{"account_role":"runtime","tenant_id":"1","database":"tenant_one","operation":"runtime.onboarding.read_branch"}},{"id":"tenant.1.runtime.onboarding.write_config","status":"PASS","target":{"account_role":"runtime","tenant_id":"1","database":"tenant_one","operation":"runtime.onboarding.write_config"}}]}
JSON
}

cat > "$BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${DOCKER_LOG:?}"
printf '\n' >> "$DOCKER_LOG"

case "${1:-}" in
    compose)
        case " $* " in
            *" config --quiet "*)
                [ "${COMPOSE_VALIDATE_FAIL:-0}" = "0" ]
                ;;
            *" config --format json "*)
                cat "$COMPOSE_JSON_FILE"
                ;;
            *" run "*)
                if [ "${DAEMON_VERIFIER_MISSING:-0}" = "1" ]; then
                    printf '%s\n' 'unknown flag --verify-db' >&2
                    exit 125
                fi
                cat "$DAEMON_REPORT_FILE"
                exit "${DAEMON_EXIT_CODE:-0}"
                ;;
            *" ps -q "*)
                printf '%s\n' "container-id"
                ;;
        esac
        ;;
    inspect)
        [ "${INSPECT_FAIL:-0}" = "0" ] || exit 31
        format="${3:-}"
        case "$format" in
            *".Config.Env"*)
                cat "$RUNNING_ENV_FILE"
                ;;
            *".State.Running"*)
                printf '%s\n' "${RUNNING_STATE:-true}"
                ;;
            *".Image"*)
                printf '%s\n' "${MOCK_RUNNING_IMAGE_ID:-sha256:verify-image}"
                ;;
            *)
                exit 32
                ;;
        esac
        ;;
    image)
        if [ "${2:-}" = "inspect" ]; then
            [ "${IMAGE_INSPECT_FAIL:-0}" = "0" ] || exit 35
            format="${4:-}"
            case "$format" in
                *".Id"*)
                printf '%s\n' "${MOCK_CONFIGURED_IMAGE_ID:-sha256:verify-image}"
                    ;;
                *)
                    exit 33
                    ;;
            esac
        fi
        ;;
esac
DOCKER

cat > "$BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
request="$(cat)"
case "$request" in
    *"/healthz"*)
        if [ "${CURL_HEALTH_FAIL:-0}" = "1" ]; then
            printf '%s\n' '{"error":"missing durable consumer","secret":"MONITOR_PASSWORD_FIXTURE raw response"}'
            exit 22
        fi
        printf '%s\n' '{"status":"ok"}'
        ;;
    *"/jsz?"*)
        if [ "${CURL_JSZ_FAIL:-0}" = "1" ]; then
            printf '%s\n' '{"error":"MONITOR_PASSWORD_FIXTURE raw response"}'
            exit 22
        fi
        case "${CURL_JSZ_MODE:-healthy}" in
            malformed)
                printf '%s\n' 'not-json'
                ;;
            backlog)
                printf '%s\n' '{"data":{"account_details":[{"stream_detail":[{"name":"ZATCA","state":{"messages":0},"consumer_detail":[{"num_pending":1001,"num_ack_pending":0,"num_redelivered":0}]}]}]}}'
                ;;
            *)
                printf '%s\n' '{"data":{"account_details":[{"stream_detail":[{"name":"ZATCA","state":{"messages":0},"consumer_detail":[{"num_pending":0,"num_ack_pending":0,"num_redelivered":0}]}]}]}}'
                ;;
        esac
        ;;
    *)
        exit 34
        ;;
esac
CURL

chmod +x "$BIN/docker" "$BIN/curl"
write_config "$TEST_REPO/config.env"
write_config "$TEST_ROOT/alternate.env"
write_config "$TEST_REPO/.env"
write_compose_json
write_running_env
write_pass_report

reset_mocks() {
    : > "$DOCKER_LOG"
    write_compose_json
    write_running_env
    write_pass_report
    cp scripts/health-zatca-daemon.sh "$TEST_REPO/scripts/health-zatca-daemon.sh"
    COMPOSE_VALIDATE_FAIL=0
    INSPECT_FAIL=0
    RUNNING_STATE=true
    MOCK_RUNNING_IMAGE_ID=sha256:verify-image
    MOCK_CONFIGURED_IMAGE_ID=sha256:verify-image
    IMAGE_INSPECT_FAIL=0
    DAEMON_VERIFIER_MISSING=0
    DAEMON_EXIT_CODE=0
    CURL_HEALTH_FAIL=0
    CURL_JSZ_FAIL=0
    CURL_JSZ_MODE=healthy
}

write_report() {
    printf '%s\n' "$1" > "$DAEMON_REPORT_FILE"
}

run_verify() {
    if (
        cd "$TEST_REPO"
        env -i \
            PATH="$BIN:$PATH" \
            HOME="${HOME:-/tmp}" \
            DOCKER_LOG="$DOCKER_LOG" \
            COMPOSE_JSON_FILE="$COMPOSE_JSON_FILE" \
            RUNNING_ENV_FILE="$RUNNING_ENV_FILE" \
            DAEMON_REPORT_FILE="$DAEMON_REPORT_FILE" \
            COMPOSE_VALIDATE_FAIL="${COMPOSE_VALIDATE_FAIL:-0}" \
            INSPECT_FAIL="${INSPECT_FAIL:-0}" \
            RUNNING_STATE="${RUNNING_STATE:-true}" \
            MOCK_RUNNING_IMAGE_ID="${MOCK_RUNNING_IMAGE_ID:-sha256:verify-image}" \
            MOCK_CONFIGURED_IMAGE_ID="${MOCK_CONFIGURED_IMAGE_ID:-sha256:verify-image}" \
            IMAGE_INSPECT_FAIL="${IMAGE_INSPECT_FAIL:-0}" \
            DAEMON_VERIFIER_MISSING="${DAEMON_VERIFIER_MISSING:-0}" \
            DAEMON_EXIT_CODE="${DAEMON_EXIT_CODE:-0}" \
            CURL_HEALTH_FAIL="${CURL_HEALTH_FAIL:-0}" \
            CURL_JSZ_FAIL="${CURL_JSZ_FAIL:-0}" \
            CURL_JSZ_MODE="${CURL_JSZ_MODE:-healthy}" \
            bash "$TEST_REPO/$VERIFY_SCRIPT" "$@"
    ) >"$OUTPUT" 2>&1; then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}

assert_no_secret_fixtures() {
    local marker
    for marker in \
        DB_PASSWORD_FIXTURE \
        ADMIN_PASSWORD_FIXTURE \
        ENCRYPTION_KEY_FIXTURE \
        MONITOR_PASSWORD_FIXTURE \
        NATS_PASSWORD_FIXTURE \
        SMTP_PASSWORD_FIXTURE; do
        not_contains "$OUTPUT" "$marker" "operator output exposed a secret fixture"
        not_contains "$DOCKER_LOG" "$marker" "Docker arguments exposed a secret fixture"
    done
}

echo
echo "=== exact configuration selection and redaction ==="
reset_mocks
run_verify
[ "$RUN_STATUS" -ne 2 ] || { cat "$OUTPUT" >&2; fail "valid default config.env was rejected"; }
contains "$DOCKER_LOG" "--env-file $TEST_REPO/config.env" \
    "default verification did not select config.env"
contains "$OUTPUT" 'PASS | config.validation' "valid default config did not pass validation"
contains "$OUTPUT" 'PASS | env.parity' "matching running environment did not pass parity"
assert_no_secret_fixtures
pass "default config.env is selected without printing credentials"

reset_mocks
run_verify --env-file "$TEST_ROOT/alternate.env"
[ "$RUN_STATUS" -ne 2 ] || { cat "$OUTPUT" >&2; fail "valid explicit env-file was rejected"; }
contains "$DOCKER_LOG" "--env-file $TEST_ROOT/alternate.env" \
    "explicit --env-file was not used for Compose"
contains "$OUTPUT" 'PASS | env.parity' "explicit matching environment did not pass parity"
assert_no_secret_fixtures
pass "explicit --env-file is honored"

reset_mocks
rm "$TEST_REPO/config.env"
write_config "$TEST_REPO/.env"
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "missing config.env incorrectly fell back to .env"
not_contains "$OUTPUT" 'overall PASS' "missing config.env produced an overall PASS"
assert_no_secret_fixtures
pass "missing selected config does not fall back to .env"
write_config "$TEST_REPO/config.env"

echo
echo "=== invalid configuration and Compose failures ==="
reset_mocks
sed '/^ZATCA_DB_PASSWORD=/d' "$TEST_REPO/config.env" > "$TEST_ROOT/missing-db-password.env"
run_verify --env-file "$TEST_ROOT/missing-db-password.env"
[ "$RUN_STATUS" -ne 0 ] || fail "missing required DB password was accepted"
not_contains "$OUTPUT" 'overall PASS' "invalid config produced an overall PASS"
assert_no_secret_fixtures
pass "missing required settings fail closed"

reset_mocks
sed '/^ZATCA_ADMIN_DB_PASSWORD=/d' "$TEST_REPO/config.env" > "$TEST_ROOT/partial-admin.env"
run_verify --env-file "$TEST_ROOT/partial-admin.env"
[ "$RUN_STATUS" -ne 0 ] || fail "partial onboarding credential pair was accepted"
not_contains "$OUTPUT" 'overall PASS' "partial account pair produced an overall PASS"
assert_no_secret_fixtures
pass "optional account pairs are validated"

reset_mocks
COMPOSE_VALIDATE_FAIL=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "Compose validation failure was accepted"
not_contains "$OUTPUT" 'overall PASS' "Compose validation failure produced an overall PASS"
assert_no_secret_fixtures
pass "Compose validation errors fail without forwarding raw output"

echo
echo "=== running container environment parity ==="
reset_mocks
python3 - "$RUNNING_ENV_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    environment = json.load(source)
environment = [
    "DB_PASS=DIFFERENT_DB_PASSWORD_FIXTURE" if item.startswith("DB_PASS=") else item
    for item in environment
]
with open(path, "w", encoding="utf-8") as target:
    json.dump(environment, target)
PY
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "running-container environment mismatch was accepted"
contains "$OUTPUT" 'DB_PASS' "mismatch did not name the failing environment key"
not_contains "$OUTPUT" 'DB_PASSWORD_FIXTURE' "mismatch output exposed the selected secret"
not_contains "$OUTPUT" 'DIFFERENT_DB_PASSWORD_FIXTURE' "mismatch output exposed the running secret"
not_contains "$OUTPUT" 'overall PASS' "environment mismatch produced an overall PASS"
pass "environment mismatches name keys only"

reset_mocks
INSPECT_FAIL=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "container inspection failure was accepted"
not_contains "$OUTPUT" 'overall PASS' "container inspection failure produced an overall PASS"
assert_no_secret_fixtures
pass "unavailable running-container evidence is not verified"

echo
echo "=== daemon report and running image validation ==="
reset_mocks
run_verify
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "complete verification evidence was rejected"; }
contains "$DOCKER_LOG" "--profile zatca-check run --rm --no-deps zatca-check" \
    "one-shot verifier was not run in isolation"
contains "$DOCKER_LOG" "--env-file $TEST_REPO/config.env" \
    "one-shot verifier did not use the selected configuration"
contains "$DOCKER_LOG" "inspect --format" "running daemon evidence was not inspected"
contains "$OUTPUT" 'OVERALL PASS' "complete verified evidence did not produce an overall PASS"
contains "$OUTPUT" 'external invoice submission was not tested' \
    "overall PASS did not state the external-invoice boundary"
assert_no_secret_fixtures
pass "complete DB, image, environment, and live-health evidence is required for PASS"

reset_mocks
MOCK_RUNNING_IMAGE_ID=sha256:stale-image
run_verify
[ "$RUN_STATUS" -ne 0 ] || {
    grep -E '^(PASS|FAIL|NOT VERIFIED) \| daemon\.image \||^OVERALL ' "$OUTPUT" >&2 || true
    fail "stale running daemon image was accepted"
}
not_contains "$OUTPUT" 'OVERALL PASS' "running image mismatch produced an overall PASS"
assert_no_secret_fixtures
pass "configured and running daemon image identities must match"

reset_mocks
IMAGE_INSPECT_FAIL=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "missing configured daemon image was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "missing verifier image produced an overall PASS"
assert_no_secret_fixtures
pass "missing configured image is not verified"

reset_mocks
DAEMON_VERIFIER_MISSING=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "image without verification mode was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "missing verifier mode produced an overall PASS"
not_contains "$OUTPUT" 'unknown flag --verify-db' "raw daemon invocation error was forwarded"
contains "$OUTPUT" 'NOT VERIFIED | database.report' \
    "missing verifier report was not explicitly marked NOT VERIFIED"
assert_no_secret_fixtures
pass "missing verifier mode cannot produce a successful database check"

echo
echo "=== strict daemon report validation ==="
for malformed_report in \
    '{invalid-json' \
    '{"schema_version":2,"overall_status":"PASS","checks":[]}' \
    '{"schema_version":1,"overall_status":"PASS","checks":[],"debug":"DB_PASSWORD_FIXTURE"}' \
    '{"schema_version":1,"overall_status":"PASS","checks":[{"id":"x","status":"MAYBE","target":{}}]}' \
    '{"schema_version":1,"overall_status":"PASS","checks":[{"id":"x","status":[],"target":{}}]}' \
    '{"schema_version":1,"overall_status":"PASS","checks":[{"id":"x","status":"PASS","target":{"account_role":[]}}]}' \
    '{"schema_version":1,"overall_status":"PASS","checks":[{"id":"x","status":"PASS","target":{},"error_category":[]}]}'; do
    reset_mocks
    write_report "$malformed_report"
    run_verify
    [ "$RUN_STATUS" -ne 0 ] || fail "malformed or unknown daemon report was accepted"
    not_contains "$OUTPUT" 'OVERALL PASS' "invalid daemon report produced an overall PASS"
    contains "$OUTPUT" 'NOT VERIFIED | database.report' \
        "invalid daemon report was not rejected by the protocol validator"
    not_contains "$OUTPUT" 'Traceback' "invalid daemon report emitted a parser traceback"
    assert_no_secret_fixtures
done
pass "malformed, unknown, and secret-bearing daemon reports fail closed"

reset_mocks
write_report '{"schema_version":1,"overall_status":"FAIL","checks":[{"id":"master.connection","status":"FAIL","target":{"account_role":"runtime","database":"zatca_master","operation":"connect"},"error_category":"connection","mysql_code":1045}]}'
DAEMON_EXIT_CODE=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || {
    grep -E '^(PASS|FAIL|NOT VERIFIED) \| (database\.master\.connection|database\.report) \||^OVERALL ' "$OUTPUT" >&2 || true
    fail "daemon failure report was accepted"
}
not_contains "$OUTPUT" 'OVERALL PASS' "daemon failure report produced an overall PASS"
contains "$OUTPUT" 'FAIL | database.master.connection' "daemon failure check was not surfaced"
assert_no_secret_fixtures
pass "a valid nonzero daemon report is parsed and remains a failure"

echo
echo "=== authenticated daemon health and backlog gates ==="
reset_mocks
CURL_HEALTH_FAIL=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "missing durable consumer readiness failure was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "unhealthy /healthz produced an overall PASS"
contains "$OUTPUT" 'daemon.health' "failed /healthz check was not surfaced"
not_contains "$OUTPUT" 'missing durable consumer' "raw /healthz response was forwarded"
assert_no_secret_fixtures
pass "branch-consumer readiness failure is sanitized"

reset_mocks
CURL_JSZ_FAIL=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "monitor authentication failure was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "monitor authentication failure produced an overall PASS"
contains "$OUTPUT" 'daemon.health' "monitor authentication failure was not surfaced"
assert_no_secret_fixtures
pass "authenticated monitor failures are sanitized"

reset_mocks
CURL_JSZ_MODE=backlog
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "exceeded JetStream backlog was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "exceeded backlog produced an overall PASS"
assert_no_secret_fixtures
pass "JetStream backlog thresholds are enforced"

reset_mocks
CURL_JSZ_MODE=malformed
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "malformed JetStream health JSON was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "malformed JetStream JSON produced an overall PASS"
assert_no_secret_fixtures
pass "malformed JetStream health evidence is not verified"

reset_mocks
cat > "$TEST_REPO/scripts/health-zatca-daemon.sh" <<'HEALTH'
#!/usr/bin/env bash
printf '%s\n' '{"status":[],"limits_ok":true}'
HEALTH
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "unhashable daemon health status was accepted"
contains "$OUTPUT" 'NOT VERIFIED | daemon.health' "malformed daemon health was not rejected"
not_contains "$OUTPUT" 'Traceback' "malformed daemon health emitted a parser traceback"
assert_no_secret_fixtures
pass "malformed daemon health is rejected without parser diagnostics"

reset_mocks
cat > "$TEST_REPO/scripts/health-zatca-daemon.sh" <<'HEALTH'
#!/usr/bin/env bash
printf '%s\n' '{"status":"disabled","limits_ok":true}'
HEALTH
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "disabled daemon health response was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "disabled daemon response produced an overall PASS"
contains "$OUTPUT" 'daemon.health' "disabled daemon response was not rejected"
assert_no_secret_fixtures
pass "disabled daemon health response cannot pass the live gate"

reset_mocks
sed 's/^ZATCA_DAEMON_ENABLED=1$/ZATCA_DAEMON_ENABLED=0/' \
    "$TEST_REPO/config.env" > "$TEST_ROOT/disabled-daemon.env"
run_verify --env-file "$TEST_ROOT/disabled-daemon.env"
[ "$RUN_STATUS" -ne 0 ] || fail "disabled daemon configuration was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "disabled configuration produced an overall PASS"
not_contains "$DOCKER_LOG" ' run ' "disabled configuration started a verifier container"
assert_no_secret_fixtures
pass "disabled daemon configuration blocks the verifier before Compose execution"

printf '\nAll environment-verifier wrapper tests passed.\n'
