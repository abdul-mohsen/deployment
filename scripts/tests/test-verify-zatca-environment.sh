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
MYSQL_LOG="$TEST_ROOT/mysql.log"
MOCK_HOME_DEFAULT="$TEST_ROOT/home"
COMPOSE_JSON_FILE="$TEST_ROOT/compose.json"
RUNNING_ENV_FILE="$TEST_ROOT/running-env.json"
DAEMON_REPORT_FILE="$TEST_ROOT/daemon-report.json"
MOCK_VALID_IMAGE_ID="sha256:$(printf '%064d' 0 | tr '0' 'a')"
MOCK_STALE_IMAGE_ID="sha256:$(printf '%064d' 0 | tr '0' 'b')"
MOCK_DAEMON_REVISION="f5459d21579e3d08420371353d88ab0216e50b58"
mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/dashboard" "$BIN" "$MOCK_HOME_DEFAULT"
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
  "NATS_MONITOR_HOST":"0.0.0.0",
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

write_database_target() {
    local host="$1" port="$2"
    python3 - "$COMPOSE_JSON_FILE" "$RUNNING_ENV_FILE" "$host" "$port" <<'PY'
import json
import sys

compose_path, running_path, host, port = sys.argv[1:]
with open(compose_path, encoding="utf-8") as source:
    compose = json.load(source)
compose["services"]["zatca-daemon"]["environment"]["DB_HOST"] = host
compose["services"]["zatca-daemon"]["environment"]["DB_PORT"] = port
with open(compose_path, "w", encoding="utf-8") as target:
    json.dump(compose, target)

with open(running_path, encoding="utf-8") as source:
    environment = json.load(source)
environment = [
    "DB_HOST=" + host if item.startswith("DB_HOST=") else
    "DB_PORT=" + port if item.startswith("DB_PORT=") else item
    for item in environment
]
with open(running_path, "w", encoding="utf-8") as target:
    json.dump(environment, target)
PY
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
  "NATS_MONITOR_HOST=0.0.0.0",
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
                    printf '%s\n' 'unknown flag --verify-db; secret=DB_PASSWORD_FIXTURE' >&2
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
    ps)
        if [ -n "${MOCK_DOCKER_PS:-}" ]; then
            printf '%s\n' "$MOCK_DOCKER_PS"
        fi
        ;;
    port)
        if [ "${2:-}" = "nats" ] && [ -n "${MOCK_LEGACY_NATS_PORT:-}" ]; then
            printf '0.0.0.0:%s\n' "$MOCK_LEGACY_NATS_PORT"
        fi
        ;;
    logs)
        if [ -n "${MOCK_CONTAINER_LOGS:-}" ]; then
            printf '%b\n' "$MOCK_CONTAINER_LOGS"
        fi
        ;;
    exec)
        if [ "${2:-}" = "dokku" ]; then
            case "${4:-}" in
                apps:list)
                    printf '%s\n' "=====> My Apps" "acme-backend" "acme-frontend"
                    ;;
                config)
                    printf '%s\n' \
                        "=====> acme-backend env vars" \
                        "HOST: ${MOCK_TENANT_HOST:-db.test.internal}" \
                        "NATS_URL: ${MOCK_TENANT_NATS_URL:-nats://host.docker.internal:4222}" \
                        "NATS_USER: ${MOCK_TENANT_NATS_USER:-daemon-user}" \
                        "NATS_PASSWORD: ${MOCK_TENANT_NATS_PASSWORD:-NATS_PASSWORD_FIXTURE}"
                    [ -z "${MOCK_TENANT_DB_HOST:-}" ] || printf 'DB_HOST: %s\n' "$MOCK_TENANT_DB_HOST"
                    [ -z "${MOCK_TENANT_DB_PORT:-}" ] || printf 'DB_PORT: %s\n' "$MOCK_TENANT_DB_PORT"
                    ;;
                docker-options:report)
                    printf '%s\n' "${MOCK_TENANT_DOCKER_OPTS---add-host=host.docker.internal:host-gateway}"
                    ;;
            esac
        fi
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
                printf '%s\n' "${MOCK_RUNNING_IMAGE_ID:-sha256:$(printf '%064d' 0 | tr '0' 'a')}"
                ;;
            *".NetworkSettings.Networks"*)
                printf '%s\n' '{"zatca_net":{"IPAddress":"172.22.0.5"}}'
                ;;
            *".State"*)
                printf '%s\n' '{"Status":"running","Health":{"Status":"healthy"},"OOMKilled":false}'
                ;;
            *".HostConfig.ExtraHosts"*)
                printf '%s\n' '["host.docker.internal:host-gateway"]'
                ;;
            *".RestartCount"*)
                printf '%s\n' '0'
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
                    printf '%s\n' "${MOCK_CONFIGURED_IMAGE_ID:-sha256:$(printf '%064d' 0 | tr '0' 'a')}"
                    ;;
                *"org.opencontainers.image.revision"*)
                    case "${5:-}" in
                        "${MOCK_CONFIGURED_IMAGE_ID:-}")
                            printf '%s\n' "${MOCK_CONFIGURED_IMAGE_REVISION:-f5459d21579e3d08420371353d88ab0216e50b58}"
                            ;;
                        "${MOCK_RUNNING_IMAGE_ID:-}")
                            printf '%s\n' "${MOCK_RUNNING_IMAGE_REVISION:-f5459d21579e3d08420371353d88ab0216e50b58}"
                            ;;
                        *)
                            exit 36
                            ;;
                    esac
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
        if [ "${CURL_HEALTH_CURL_CODE:-0}" != "0" ]; then
            printf 'curl: (%s) Failed to connect to %s port %s; secret=MONITOR_PASSWORD_FIXTURE\n' \
                "$CURL_HEALTH_CURL_CODE" \
                "${ZATCA_NATS_MONITOR_HOST:-127.0.0.1}" \
                "${ZATCA_NATS_MONITOR_PORT:-8222}" >&2
            exit "$CURL_HEALTH_CURL_CODE"
        fi
        if [ "${CURL_HEALTH_FAIL:-0}" = "1" ]; then
            printf '%s\n' 'curl: (22) The requested URL returned error: 503' >&2
            printf '%s\n' '{"error":"missing durable consumer","secret":"MONITOR_PASSWORD_FIXTURE raw response"}'
            exit 22
        fi
        printf '%s\n' '{"status":"ok"}'
        ;;
    *"/jsz?"*)
        if [ "${CURL_JSZ_FAIL:-0}" = "1" ]; then
            printf '%s\n' 'curl: (22) The requested URL returned error: 401' >&2
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

cat > "$BIN/mysql" <<'MYSQL'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${MYSQL_LOG:?}"
printf '\n' >> "$MYSQL_LOG"

if [ "${1:-}" = "--help" ]; then
    case "${MOCK_MYSQL_HELP_MODE:-ssl-mode}" in
        ssl-mode)
            printf '%s\n' '  --ssl-mode=name     Desired security state of the connection to the server.'
            printf '%s\n' '  --get-server-public-key  Get public key from server.'
            ;;
        skip-ssl) printf '%s\n' '  --skip-ssl          Disable SSL for connection.' ;;
        none)     printf '%s\n' '  --protocol=name     The protocol to use for connection.' ;;
    esac
    exit 0
fi

no_defaults=false
protocol=""
host=""
port=""
user=""
sql=""
plaintext=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-defaults) no_defaults=true; shift ;;
        --protocol=*) protocol="${1#*=}"; shift ;;
        --ssl-mode=DISABLED|--skip-ssl|--ssl=0) plaintext=true; shift ;;
        --get-server-public-key) shift ;;
        -h) host="$2"; shift 2 ;;
        -P) port="$2"; shift 2 ;;
        -u) user="$2"; shift 2 ;;
        -e) sql="$2"; shift 2 ;;
        --connect-timeout=*|-N|-B) shift ;;
        *) shift ;;
    esac
done

pass="${MYSQL_PWD:-}"

auth_ok=false
if [ "$no_defaults" = false ] && [ -z "${MYSQL_PWD+x}" ] && [ "${MOCK_MYSQL_MYCNF_OK:-0}" = "1" ]; then
    auth_ok=true
elif [ "$protocol" = "SOCKET" ]; then
    if [ "${MOCK_MYSQL_SOCKET_OK:-0}" = "1" ] && [ "$user" = "${MOCK_MYSQL_RUNTIME_USER:-runtime-user}" ] && [ "$pass" = "${MOCK_MYSQL_VALID_RUNTIME_PASS:-DB_PASSWORD_FIXTURE}" ]; then
        auth_ok=true
    fi
else
    if [ "${MOCK_MYSQL_TCP_MODE:-pass}" = "deny_host_1045" ] && [ "$user" = "${MOCK_MYSQL_RUNTIME_USER:-runtime-user}" ]; then
        auth_ok=false
    elif [ "${MOCK_MYSQL_TCP_MODE:-pass}" = "socket_only" ] && [ "$user" = "${MOCK_MYSQL_RUNTIME_USER:-runtime-user}" ]; then
        auth_ok=false
    else
        if [ "$user" = "${MOCK_MYSQL_RUNTIME_USER:-runtime-user}" ] && [ "$pass" = "${MOCK_MYSQL_VALID_RUNTIME_PASS:-DB_PASSWORD_FIXTURE}" ]; then
            auth_ok=true
        elif [ "$user" = "${MOCK_MYSQL_ONBOARD_USER:-onboarding-user}" ] && [ "$pass" = "${MOCK_MYSQL_VALID_ONBOARD_PASS:-ADMIN_PASSWORD_FIXTURE}" ]; then
            auth_ok=true
        elif [ -n "${MOCK_MYSQL_DEPLOY_ADMIN_USER:-}" ] && [ "$user" = "$MOCK_MYSQL_DEPLOY_ADMIN_USER" ] && [ "$pass" = "${MOCK_MYSQL_DEPLOY_ADMIN_PASS:-}" ]; then
            auth_ok=true
        fi
    fi
fi

if [ "$auth_ok" != true ]; then
    printf "ERROR 1045 (28000): Access denied for user '%s'@'%s' (using password: %s)\n" \
        "$user" "${host:-localhost}" "$( [ -n "$pass" ] && printf YES || printf NO )" >&2
    exit 1
fi

if [ "$plaintext" = true ] && [ "${MOCK_MYSQL_PLAINTEXT_FAIL:-0}" = "1" ]; then
    printf "ERROR 3159 (HY000): Connections using insecure transport are prohibited while --require_secure_transport=ON.\n" >&2
    exit 1
fi

case "$sql" in
    "SELECT CURRENT_USER(), USER(), @@version;")
        if [ "$protocol" = "SOCKET" ]; then
            printf '%s@localhost\t%s@localhost\t8.0.39-mock\n' "$user" "$user"
        else
            printf '%s@%%\t%s@%s\t8.0.39-mock\n' "$user" "$user" "${host:-127.0.0.1}"
        fi
        ;;
    "SELECT CURRENT_USER(), USER();")
        if [ "$protocol" = "SOCKET" ]; then
            printf '%s@localhost\t%s@localhost\n' "$user" "$user"
        else
            printf '%s@%%\t%s@%s\n' "$user" "$user" "${host:-127.0.0.1}"
        fi
        ;;
    "SELECT 1;")
        printf '1\n'
        ;;
    "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA"*)
        if [ "${MOCK_MYSQL_MASTER_MISSING:-0}" != "1" ]; then
            printf '%s\n' "${MOCK_MYSQL_MASTER_DB:-zatca_master}"
        fi
        ;;
    "SHOW GRANTS FOR CURRENT_USER();"|"SHOW GRANTS FOR "*)
        if [ -n "${MOCK_MYSQL_GRANTS:-}" ]; then
            printf '%b\n' "$MOCK_MYSQL_GRANTS"
        else
            printf "GRANT USAGE ON *.* TO '%s'@'%%' IDENTIFIED BY PASSWORD 'DB_PASSWORD_FIXTURE'\nGRANT SELECT, INSERT, UPDATE ON \`zatca_master\`.* TO '%s'@'%%'\n" "$user" "$user"
        fi
        ;;
    "SHOW VARIABLES WHERE Variable_name IN"*)
        if [ -n "${MOCK_MYSQL_SERVER_VARS:-}" ]; then
            printf '%b\n' "$MOCK_MYSQL_SERVER_VARS"
        else
            printf 'bind_address\t0.0.0.0\nport\t3306\nrequire_secure_transport\tOFF\ndefault_authentication_plugin\tcaching_sha2_password\n'
        fi
        ;;
    "SELECT user, host, plugin, account_locked, ssl_type FROM mysql.user"*)
        if [ "${MOCK_MYSQL_USER_DENIED:-0}" = "1" ]; then
            printf "ERROR 1142 (42000) at line 1: SELECT command denied to user '%s'@'127.0.0.1' for table 'user'\n" "$user" >&2
            exit 1
        fi
        if [ -n "${MOCK_MYSQL_USER_ROWS:-}" ]; then
            printf '%b\n' "$MOCK_MYSQL_USER_ROWS"
        else
            printf '%s\t%%\tcaching_sha2_password\tN\t\n' "${MOCK_MYSQL_RUNTIME_USER:-runtime-user}"
        fi
        ;;
    *)
        printf 'ok\n'
        ;;
esac
MYSQL

chmod +x "$BIN/docker" "$BIN/curl" "$BIN/mysql"
write_config "$TEST_REPO/config.env"
write_config "$TEST_ROOT/alternate.env"
write_config "$TEST_REPO/.env"
write_compose_json
write_running_env
write_pass_report

reset_mocks() {
    : > "$DOCKER_LOG"
    : > "$MYSQL_LOG"
    write_compose_json
    write_running_env
    write_pass_report
    cp scripts/health-zatca-daemon.sh "$TEST_REPO/scripts/health-zatca-daemon.sh"
    COMPOSE_VALIDATE_FAIL=0
    INSPECT_FAIL=0
    RUNNING_STATE=true
    MOCK_RUNNING_IMAGE_ID="$MOCK_VALID_IMAGE_ID"
    MOCK_CONFIGURED_IMAGE_ID="$MOCK_VALID_IMAGE_ID"
    MOCK_CONFIGURED_IMAGE_REVISION="$MOCK_DAEMON_REVISION"
    MOCK_RUNNING_IMAGE_REVISION="$MOCK_DAEMON_REVISION"
    IMAGE_INSPECT_FAIL=0
    DAEMON_VERIFIER_MISSING=0
    DAEMON_EXIT_CODE=0
    CURL_HEALTH_FAIL=0
    CURL_HEALTH_CURL_CODE=0
    CURL_JSZ_FAIL=0
    CURL_JSZ_MODE=healthy
    MOCK_DOCKER_PS=""
    MOCK_LEGACY_NATS_PORT=""
    MOCK_CONTAINER_LOGS=""
    MOCK_TENANT_HOST="db.test.internal"
    MOCK_TENANT_DB_HOST=""
    MOCK_TENANT_DB_PORT=""
    MOCK_TENANT_NATS_URL="nats://host.docker.internal:4222"
    MOCK_TENANT_NATS_USER="daemon-user"
    MOCK_TENANT_NATS_PASSWORD="NATS_PASSWORD_FIXTURE"
    MOCK_TENANT_DOCKER_OPTS="--add-host=host.docker.internal:host-gateway"
    MOCK_HOME="$MOCK_HOME_DEFAULT"
    MOCK_MYSQL_HELP_MODE="ssl-mode"
    MOCK_MYSQL_TCP_MODE="pass"
    MOCK_MYSQL_SOCKET_OK=0
    MOCK_MYSQL_MYCNF_OK=0
    MOCK_MYSQL_PLAINTEXT_FAIL=0
    MOCK_MYSQL_MASTER_MISSING=0
    MOCK_MYSQL_MASTER_DB="zatca_master"
    MOCK_MYSQL_RUNTIME_USER="runtime-user"
    MOCK_MYSQL_VALID_RUNTIME_PASS="DB_PASSWORD_FIXTURE"
    MOCK_MYSQL_ONBOARD_USER="onboarding-user"
    MOCK_MYSQL_VALID_ONBOARD_PASS="ADMIN_PASSWORD_FIXTURE"
    MOCK_MYSQL_DEPLOY_ADMIN_USER=""
    MOCK_MYSQL_DEPLOY_ADMIN_PASS=""
    MOCK_MYSQL_GRANTS=""
    MOCK_MYSQL_SERVER_VARS=""
    MOCK_MYSQL_USER_DENIED=0
    MOCK_MYSQL_USER_ROWS=""
}

write_report() {
    printf '%s\n' "$1" > "$DAEMON_REPORT_FILE"
}

run_verify() {
    if (
        cd "$TEST_REPO"
        env -i \
            PATH="$BIN:$PATH" \
            HOME="${MOCK_HOME:-$MOCK_HOME_DEFAULT}" \
            DOCKER_LOG="$DOCKER_LOG" \
            MYSQL_LOG="$MYSQL_LOG" \
            COMPOSE_JSON_FILE="$COMPOSE_JSON_FILE" \
            RUNNING_ENV_FILE="$RUNNING_ENV_FILE" \
            DAEMON_REPORT_FILE="$DAEMON_REPORT_FILE" \
            COMPOSE_VALIDATE_FAIL="${COMPOSE_VALIDATE_FAIL:-0}" \
            INSPECT_FAIL="${INSPECT_FAIL:-0}" \
            RUNNING_STATE="${RUNNING_STATE:-true}" \
            MOCK_RUNNING_IMAGE_ID="${MOCK_RUNNING_IMAGE_ID-$MOCK_VALID_IMAGE_ID}" \
            MOCK_CONFIGURED_IMAGE_ID="${MOCK_CONFIGURED_IMAGE_ID-$MOCK_VALID_IMAGE_ID}" \
            MOCK_CONFIGURED_IMAGE_REVISION="${MOCK_CONFIGURED_IMAGE_REVISION-$MOCK_DAEMON_REVISION}" \
            MOCK_RUNNING_IMAGE_REVISION="${MOCK_RUNNING_IMAGE_REVISION-$MOCK_DAEMON_REVISION}" \
            IMAGE_INSPECT_FAIL="${IMAGE_INSPECT_FAIL:-0}" \
            DAEMON_VERIFIER_MISSING="${DAEMON_VERIFIER_MISSING:-0}" \
            DAEMON_EXIT_CODE="${DAEMON_EXIT_CODE:-0}" \
            CURL_HEALTH_FAIL="${CURL_HEALTH_FAIL:-0}" \
            CURL_HEALTH_CURL_CODE="${CURL_HEALTH_CURL_CODE:-0}" \
            CURL_JSZ_FAIL="${CURL_JSZ_FAIL:-0}" \
            CURL_JSZ_MODE="${CURL_JSZ_MODE:-healthy}" \
            MOCK_DOCKER_PS="${MOCK_DOCKER_PS:-}" \
            MOCK_LEGACY_NATS_PORT="${MOCK_LEGACY_NATS_PORT:-}" \
            MOCK_CONTAINER_LOGS="${MOCK_CONTAINER_LOGS:-}" \
            MOCK_TENANT_HOST="${MOCK_TENANT_HOST:-db.test.internal}" \
            MOCK_TENANT_DB_HOST="${MOCK_TENANT_DB_HOST:-}" \
            MOCK_TENANT_DB_PORT="${MOCK_TENANT_DB_PORT:-}" \
            MOCK_TENANT_NATS_URL="${MOCK_TENANT_NATS_URL:-nats://host.docker.internal:4222}" \
            MOCK_TENANT_NATS_USER="${MOCK_TENANT_NATS_USER:-daemon-user}" \
            MOCK_TENANT_NATS_PASSWORD="${MOCK_TENANT_NATS_PASSWORD:-NATS_PASSWORD_FIXTURE}" \
            MOCK_TENANT_DOCKER_OPTS="${MOCK_TENANT_DOCKER_OPTS---add-host=host.docker.internal:host-gateway}" \
            MOCK_MYSQL_HELP_MODE="${MOCK_MYSQL_HELP_MODE:-ssl-mode}" \
            MOCK_MYSQL_TCP_MODE="${MOCK_MYSQL_TCP_MODE:-pass}" \
            MOCK_MYSQL_SOCKET_OK="${MOCK_MYSQL_SOCKET_OK:-0}" \
            MOCK_MYSQL_MYCNF_OK="${MOCK_MYSQL_MYCNF_OK:-0}" \
            MOCK_MYSQL_PLAINTEXT_FAIL="${MOCK_MYSQL_PLAINTEXT_FAIL:-0}" \
            MOCK_MYSQL_MASTER_MISSING="${MOCK_MYSQL_MASTER_MISSING:-0}" \
            MOCK_MYSQL_MASTER_DB="${MOCK_MYSQL_MASTER_DB:-zatca_master}" \
            MOCK_MYSQL_RUNTIME_USER="${MOCK_MYSQL_RUNTIME_USER:-runtime-user}" \
            MOCK_MYSQL_VALID_RUNTIME_PASS="${MOCK_MYSQL_VALID_RUNTIME_PASS:-DB_PASSWORD_FIXTURE}" \
            MOCK_MYSQL_ONBOARD_USER="${MOCK_MYSQL_ONBOARD_USER:-onboarding-user}" \
            MOCK_MYSQL_VALID_ONBOARD_PASS="${MOCK_MYSQL_VALID_ONBOARD_PASS:-ADMIN_PASSWORD_FIXTURE}" \
            MOCK_MYSQL_DEPLOY_ADMIN_USER="${MOCK_MYSQL_DEPLOY_ADMIN_USER:-}" \
            MOCK_MYSQL_DEPLOY_ADMIN_PASS="${MOCK_MYSQL_DEPLOY_ADMIN_PASS:-}" \
            MOCK_MYSQL_GRANTS="${MOCK_MYSQL_GRANTS:-}" \
            MOCK_MYSQL_SERVER_VARS="${MOCK_MYSQL_SERVER_VARS:-}" \
            MOCK_MYSQL_USER_DENIED="${MOCK_MYSQL_USER_DENIED:-0}" \
            MOCK_MYSQL_USER_ROWS="${MOCK_MYSQL_USER_ROWS:-}" \
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
        not_contains "$MYSQL_LOG" "$marker" "mysql CLI arguments exposed a secret fixture"
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
contains "$OUTPUT" "INFO | daemon.image.provenance | configured_id=$MOCK_VALID_IMAGE_ID configured_revision=$MOCK_DAEMON_REVISION running_id=$MOCK_VALID_IMAGE_ID running_revision=$MOCK_DAEMON_REVISION" \
    "safe configured/running image provenance was not reported"
contains "$OUTPUT" 'INFO | daemon.monitor.target | class=loopback port=8222 endpoints=/healthz,/jsz' \
    "safe default monitor target context was not reported"
contains "$OUTPUT" 'INFO | database.target | class=custom_host_redacted port=3307' \
    "safe database target class and port were not reported"
contains "$OUTPUT" 'INFO | database.target.details | user=runtime-user host=db.test.internal port=3307 master_db=zatca_master' \
    "verbose non-secret database target details were not reported"
contains "$OUTPUT" 'INFO | daemon.jetstream | stream=ZATCA messages=0 consumers=1 pending=0/1000 ack_pending=0/100 redelivered=0' \
    "JetStream summary counters were not reported"
contains "$OUTPUT" 'PASS | compose.monitor_bind' "Compose NATS_MONITOR_HOST=0.0.0.0 bind check did not pass"
contains "$OUTPUT" 'PASS | daemon.monitor_bind' "running container NATS_MONITOR_HOST=0.0.0.0 bind check did not pass"
contains "$OUTPUT" 'database=zatca_master' "database check output omitted database name"
contains "$DOCKER_LOG" "--profile zatca-check run --rm --no-deps zatca-check" \
    "one-shot verifier was not run in isolation"
contains "$DOCKER_LOG" "--env-file $TEST_REPO/config.env" \
    "one-shot verifier did not use the selected configuration"
contains "$DOCKER_LOG" "inspect --format" "running daemon evidence was not inspected"
contains "$OUTPUT" 'OVERALL PASS' "complete verified evidence did not produce an overall PASS"
contains "$OUTPUT" 'external invoice submission was not tested' \
    "overall PASS did not state the external-invoice boundary"
assert_no_secret_fixtures
pass "complete DB, image, environment, monitor bind, and live-health evidence is required for PASS"

reset_mocks
write_database_target "host.docker.internal" "3306"
run_verify
contains "$OUTPUT" 'INFO | database.target | class=host_gateway port=3306' \
    "host gateway database target was not classified"
contains "$OUTPUT" 'host=host.docker.internal' "host gateway database target detail was not shown"
assert_no_secret_fixtures
pass "host gateway database targets report safe class, port, and non-secret host"

reset_mocks
write_database_target "127.0.0.2" "3307"
run_verify
contains "$OUTPUT" 'INFO | database.target | class=container_loopback port=3307' \
    "container loopback database target was not classified"
contains "$OUTPUT" 'WARN | database.target.loopback' \
    "container loopback DB_HOST did not emit a loopback warning"
contains "$OUTPUT" 'NEXT STEP' "container loopback DB_HOST did not emit a guided next step"
assert_no_secret_fixtures
pass "container loopback database targets warn and guide toward host.docker.internal"

reset_mocks
write_database_target "private-db.test.invalid" "70000"
run_verify
contains "$OUTPUT" 'INFO | database.target | class=custom_host_redacted port=unavailable' \
    "invalid database port was not withheld"
not_contains "$OUTPUT" '70000' "invalid database port was printed"
assert_no_secret_fixtures
pass "invalid database ports are withheld as unavailable"

reset_mocks
MOCK_RUNNING_IMAGE_ID="$MOCK_STALE_IMAGE_ID"
MOCK_RUNNING_IMAGE_REVISION="$MOCK_DAEMON_REVISION"
run_verify
[ "$RUN_STATUS" -ne 0 ] || {
    grep -E '^(PASS|FAIL|NOT VERIFIED) \| daemon\.image \||^OVERALL ' "$OUTPUT" >&2 || true
    fail "stale running daemon image was accepted"
}
contains "$OUTPUT" "configured_id=$MOCK_VALID_IMAGE_ID configured_revision=$MOCK_DAEMON_REVISION running_id=$MOCK_STALE_IMAGE_ID running_revision=$MOCK_DAEMON_REVISION" \
    "stale daemon provenance was not exposed safely"
contains "$OUTPUT" 'matching source revision labels do not prove identical image artifacts' \
    "same-revision image mismatch did not explain why IDs still differ"
not_contains "$OUTPUT" 'OVERALL PASS' "running image mismatch produced an overall PASS"
assert_no_secret_fixtures
pass "configured and running daemon image identities must match"

reset_mocks
MOCK_CONFIGURED_IMAGE_REVISION=DB_PASSWORD_FIXTURE
MOCK_RUNNING_IMAGE_REVISION=DB_PASSWORD_FIXTURE
run_verify
[ "$RUN_STATUS" -eq 0 ] || fail "unsafe optional revision labels changed the successful image check"
contains "$OUTPUT" "configured_id=$MOCK_VALID_IMAGE_ID configured_revision=unavailable running_id=$MOCK_VALID_IMAGE_ID running_revision=unavailable" \
    "unsafe image revision labels were not replaced with unavailable"
not_contains "$OUTPUT" 'DB_PASSWORD_FIXTURE' "unsafe image revision exposed a database password"
assert_no_secret_fixtures
pass "unsafe optional image labels are withheld without changing the existing gate"

reset_mocks
MOCK_CONFIGURED_IMAGE_ID='sha256:invalid-DB_PASSWORD_FIXTURE'
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "malformed configured image ID was accepted"
contains "$OUTPUT" 'NOT VERIFIED | daemon.image' "malformed image ID did not fail image verification"
contains "$OUTPUT" 'configured_id=unavailable' "malformed image ID was not redacted"
not_contains "$OUTPUT" 'invalid-DB_PASSWORD_FIXTURE' "malformed image ID was printed"
not_contains "$DOCKER_LOG" ' run ' "one-shot verifier ran after image identity became untrusted"
assert_no_secret_fixtures
pass "malformed image identity is withheld and cannot start the one-shot verifier"

reset_mocks
MOCK_RUNNING_IMAGE_ID='sha256:invalid-MONITOR_PASSWORD_FIXTURE'
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "malformed running image ID was accepted"
contains "$OUTPUT" 'NOT VERIFIED | daemon.image' "malformed running image ID did not fail image verification"
contains "$OUTPUT" 'running_id=unavailable' "malformed running image ID was not redacted"
not_contains "$OUTPUT" 'invalid-MONITOR_PASSWORD_FIXTURE' "malformed running image ID was printed"
assert_no_secret_fixtures
pass "malformed running image identity is withheld and cannot pass verification"

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
contains "$OUTPUT" "INFO | daemon.image.provenance | configured_id=$MOCK_VALID_IMAGE_ID configured_revision=$MOCK_DAEMON_REVISION running_id=$MOCK_VALID_IMAGE_ID running_revision=$MOCK_DAEMON_REVISION" \
    "unsupported verifier output omitted safe configured/running image provenance"
not_contains "$OUTPUT" 'unknown flag --verify-db' "raw daemon invocation error was forwarded"
contains "$OUTPUT" 'daemon image rejected --verify-db/--json; database probe was not run' \
    "unsupported verifier flags did not identify why the database probe did not run"
assert_no_secret_fixtures
pass "missing verifier mode explains that the database probe did not run without exposing stderr"

reset_mocks
write_report ""
DAEMON_EXIT_CODE=2
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "a verifier with no report was accepted"
contains "$OUTPUT" 'one-shot verifier exited with status 2 without JSON' \
    "empty verifier output omitted the process exit status"
contains "$OUTPUT" 'database connection and permissions were not verified' \
    "empty verifier output did not state that database access remains unverified"
assert_no_secret_fixtures
pass "empty verifier output reports the exit status without claiming a database failure"

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
contains "$OUTPUT" 'does not prove the password is wrong' \
    "MySQL 1045 was treated as proof of a bad password"
contains "$OUTPUT" 'successful Dokku admin test does not verify the daemon connection' \
    "MySQL 1045 guidance ignored the known working Dokku admin test"
contains "$OUTPUT" 'before changing credentials' \
    "MySQL 1045 guidance did not prioritize diagnosis before credential changes"
contains "$OUTPUT" 'user=runtime-user' "MySQL 1045 guidance did not identify the tested DB user"
contains "$OUTPUT" '172.22.0.5' "MySQL 1045 guidance did not show the container source IP"
assert_no_secret_fixtures
pass "a valid nonzero daemon report is parsed and remains a failure with actionable DB grant context"

echo
echo "=== authenticated daemon health and backlog gates ==="
reset_mocks
cp "$TEST_REPO/config.env" "$TEST_ROOT/custom-monitor.env"
printf '%s\n' \
    'ZATCA_NATS_MONITOR_HOST=monitor.private.invalid' \
    'ZATCA_NATS_MONITOR_PORT=9123' >> "$TEST_ROOT/custom-monitor.env"
for curl_code in 6 7 28 56; do
    reset_mocks
    CURL_HEALTH_CURL_CODE="$curl_code"
    run_verify --env-file "$TEST_ROOT/custom-monitor.env"
    [ "$RUN_STATUS" -ne 0 ] || fail "curl error $curl_code was accepted as healthy"
    contains "$OUTPUT" 'INFO | daemon.monitor.target | class=custom_host_redacted port=9123 endpoints=/healthz,/jsz' \
        "custom monitor target was not safely classified"
    contains "$OUTPUT" "curl error $curl_code" "curl error $curl_code was not reported"
    case "$curl_code" in
        6) contains "$OUTPUT" 'name resolution failure' "curl error 6 was not classified" ;;
        7) contains "$OUTPUT" 'connection failure' "curl error 7 was not classified" ;;
        28) contains "$OUTPUT" 'timeout' "curl error 28 was not classified" ;;
        56)
            contains "$OUTPUT" 'response receive failure' "curl error 56 was not classified"
            contains "$OUTPUT" 'HINT | daemon.health | curl error 56 indicates a response receive failure' \
                "curl error 56 did not include a safe diagnostic hint"
            contains "$OUTPUT" 'does not establish a connection reset or identify the cause' \
                "curl error 56 asserted an unproven transport root cause"
            contains "$OUTPUT" 'If it persists after database access and configured/running image alignment are verified, inspect the daemon container logs and state' \
                "curl error 56 omitted the safe logs/state follow-up after DB and image checks"
            ;;
    esac
    not_contains "$OUTPUT" 'Failed to connect' "raw curl diagnostic was printed"
    not_contains "$OUTPUT" 'secret=' "raw curl diagnostic fixture was printed"
    not_contains "$OUTPUT" 'OVERALL PASS' "curl error $curl_code produced an overall PASS"
    assert_no_secret_fixtures
done
pass "curl resolution, connection, timeout, and response-receive errors include safe target context without leaking secrets"

reset_mocks
cp "$TEST_REPO/config.env" "$TEST_ROOT/invalid-monitor-port.env"
printf '%s\n' \
    'ZATCA_NATS_MONITOR_HOST=monitor.private.invalid' \
    'ZATCA_NATS_MONITOR_PORT=9123-not-a-port' >> "$TEST_ROOT/invalid-monitor-port.env"
CURL_HEALTH_CURL_CODE=3
run_verify --env-file "$TEST_ROOT/invalid-monitor-port.env"
[ "$RUN_STATUS" -ne 0 ] || fail "invalid monitor port was accepted as healthy"
contains "$OUTPUT" 'FAIL | config.port.ZATCA_NATS_MONITOR_PORT' "invalid monitor port was not flagged in Stage 1"
contains "$OUTPUT" 'INFO | daemon.monitor.target | class=custom_host_redacted port=unavailable endpoints=/healthz,/jsz' \
    "invalid monitor port was not withheld"
not_contains "$OUTPUT" '9123-not-a-port' "invalid monitor port was printed"
assert_no_secret_fixtures
pass "invalid monitor ports are flagged and withheld as unavailable"

reset_mocks
CURL_HEALTH_FAIL=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "missing durable consumer readiness failure was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "unhealthy /healthz produced an overall PASS"
contains "$OUTPUT" 'daemon.health' "failed /healthz check was not surfaced"
contains "$OUTPUT" '/healthz returned HTTP 503; daemon readiness failed' \
    "health failure did not identify the failing endpoint and HTTP status"
contains "$OUTPUT" 'INFO | daemon.readiness | error=missing durable consumer' \
    "allow-listed readiness error reason was not surfaced for operator debugging"
not_contains "$OUTPUT" 'raw response' "non-allow-listed secret field from /healthz was exposed"
assert_no_secret_fixtures
pass "readiness failure extracts allow-listed redacted reason while excluding unknown/secret fields"

reset_mocks
CURL_JSZ_FAIL=1
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "monitor authentication failure was accepted"
not_contains "$OUTPUT" 'OVERALL PASS' "monitor authentication failure produced an overall PASS"
contains "$OUTPUT" 'daemon.health' "monitor authentication failure was not surfaced"
contains "$OUTPUT" '/jsz rejected monitor authentication (HTTP 401)' \
    "monitor authentication failure did not identify its endpoint and HTTP status"
assert_no_secret_fixtures
pass "monitor authentication failure is identified without exposing its response"

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

echo
echo "=== new verbose guided checks: monitor bind, single-pass scan, drift, interpolation, logs, dokku ==="

# 1. --config alias and --verbose full mapped env table with secrets strictly redacted
reset_mocks
run_verify --config "$TEST_ROOT/alternate.env" --verbose
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "--config --verbose valid run failed"; }
contains "$OUTPUT" 'INFO | compose.env | DB_PASS=[REDACTED]' "--verbose did not redact DB_PASS"
contains "$OUTPUT" 'INFO | compose.env | NATS_MONITOR_HOST=0.0.0.0' "--verbose did not print NATS_MONITOR_HOST"
contains "$OUTPUT" 'INFO | summary |' "summary counts were not printed"
assert_no_secret_fixtures
pass "--config alias and --verbose mapped environment table redact all secrets"

# 2. Missing/loopback NATS_MONITOR_HOST in Compose & running container + curl 56 cross-link
reset_mocks
python3 - "$COMPOSE_JSON_FILE" "$RUNNING_ENV_FILE" <<'PY'
import json, sys
c_path, r_path = sys.argv[1:3]
with open(c_path, encoding="utf-8") as fh:
    c = json.load(fh)
c["services"]["zatca-daemon"]["environment"].pop("NATS_MONITOR_HOST", None)
with open(c_path, "w", encoding="utf-8") as fh:
    json.dump(c, fh)
with open(r_path, encoding="utf-8") as fh:
    r = [x for x in json.load(fh) if not x.startswith("NATS_MONITOR_HOST=")]
with open(r_path, "w", encoding="utf-8") as fh:
    json.dump(r, fh)
PY
CURL_HEALTH_CURL_CODE=56
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "missing NATS_MONITOR_HOST was accepted"
contains "$OUTPUT" 'FAIL | compose.monitor_bind' "missing Compose NATS_MONITOR_HOST was not flagged"
contains "$OUTPUT" 'FAIL | daemon.monitor_bind' "missing running container NATS_MONITOR_HOST was not flagged"
contains "$OUTPUT" 'curl error 56 correlates directly with NATS_MONITOR_HOST' \
    "curl 56 did not cross-link to the Stage 3 NATS_MONITOR_HOST root cause"
contains "$OUTPUT" 'NEXT STEP 1 |' "guided next steps were not emitted"
assert_no_secret_fixtures
pass "missing NATS_MONITOR_HOST is flagged in Stage 3 and correlated with curl error 56"

# 3. Single-pass multi-error config scan (does NOT abort on the first missing key)
reset_mocks
cat > "$TEST_ROOT/multi-broken.env" <<'BROKEN'
ZATCA_DAEMON_ENABLED=1
ZATCA_DAEMON_IMAGE=local/zatca-daemon:verify-test
ZATCA_DB_USER=runtime-user
MYSQL_PORT=3307
ZATCA_NATS_PORT=4333
NATS_URL=nats://host.docker.internal:4222
NATS_PRIVATE_NETWORK_ONLY=false
NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED=false
NATS_SHARED_CREDENTIALS_ACKNOWLEDGED=false
NATS_SHARED_CREDENTIALS_APPROVAL_ID=
NATS_SHARED_CREDENTIALS_EXPIRES=2020-01-01
BROKEN
python3 - "$TEST_ROOT/multi-broken.env" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read().replace(b"\n", b"\r\n")
open(p, "wb").write(data)
PY
run_verify --env-file "$TEST_ROOT/multi-broken.env"
[ "$RUN_STATUS" -eq 2 ] || fail "multi-error config did not exit with code 2 (got $RUN_STATUS)"
contains "$OUTPUT" 'FAIL | config.format.crlf' "CRLF endings were not detected"
contains "$OUTPUT" 'ZATCA_DB_PASSWORD' "missing ZATCA_DB_PASSWORD was not listed"
contains "$OUTPUT" 'ZATCA_ENCRYPT_KEY' "missing ZATCA_ENCRYPT_KEY was not listed in the same pass"
contains "$OUTPUT" 'NATS_PASSWORD' "missing NATS_PASSWORD was not listed in the same pass"
contains "$OUTPUT" 'NATS_PRIVATE_NETWORK_ONLY must be true' "NATS_PRIVATE_NETWORK_ONLY gate failure was skipped"
contains "$OUTPUT" 'NATS_SHARED_CREDENTIALS_EXPIRES (2020-01-01) is expired' "expired approval gate was skipped"
contains "$OUTPUT" 'FAIL | config.nats_url' "NATS_URL port mismatch was skipped"
contains "$OUTPUT" 'NEXT STEP 1 |' "multi-error config did not produce guided next steps"
assert_no_secret_fixtures
pass "multi-error config scan reports CRLF, all missing keys, all security gates, and NATS_URL mismatch in one pass"

# 4. Sibling install.env & .env drift checks (boolean-only password compare, zero secret leakage)
reset_mocks
mkdir -p "$TEST_ROOT/drift-dir"
write_config "$TEST_ROOT/drift-dir/config.env"
cat > "$TEST_ROOT/drift-dir/install.env" <<'INST'
MYSQL_PORT=3306
MYSQL_ADMIN_USER=runtime-user
MYSQL_ADMIN_PASSWORD=INSTALL_SECRET_DRIFT_FIXTURE
INST
sed 's/^ZATCA_DB_PASSWORD=.*/ZATCA_DB_PASSWORD=DOTENV_SECRET_DRIFT_FIXTURE/' \
    "$TEST_ROOT/drift-dir/config.env" > "$TEST_ROOT/drift-dir/.env"
run_verify --env-file "$TEST_ROOT/drift-dir/config.env"
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "advisory drift warnings unexpectedly failed verification"; }
contains "$OUTPUT" 'WARN | config.drift.install_env | MYSQL_PORT differs' "install.env port drift not detected"
contains "$OUTPUT" 'ZATCA_DB_PASSWORD differs from MYSQL_ADMIN_PASSWORD' "same-user password drift not detected"
contains "$OUTPUT" 'WARN | config.drift.dotenv' "sibling .env drift not detected"
not_contains "$OUTPUT" 'INSTALL_SECRET_DRIFT_FIXTURE' "install.env secret leaked"
not_contains "$OUTPUT" 'DOTENV_SECRET_DRIFT_FIXTURE' "sibling .env secret leaked"
assert_no_secret_fixtures
pass "sibling install.env and .env drift are reported without leaking secrets"

# 5. Bash-vs-Compose interpolation mismatch ($ in password) without leaking values
reset_mocks
cp "$TEST_REPO/config.env" "$TEST_ROOT/dollar-secret.env"
sed -i "s/^ZATCA_DB_PASSWORD=.*/ZATCA_DB_PASSWORD='PASS\$DOLLAR_FIXTURE'/" "$TEST_ROOT/dollar-secret.env"
# Compose mock resolves DB_PASS differently from Bash's literal single-quoted value
run_verify --env-file "$TEST_ROOT/dollar-secret.env"
[ "$RUN_STATUS" -ne 0 ] || fail "Bash-vs-Compose interpolation mismatch was accepted"
contains "$OUTPUT" 'FAIL | config.interpolation' "Bash-vs-Compose interpolation mismatch was not caught"
contains "$OUTPUT" 'DB_PASS(ZATCA_DB_PASSWORD)' "interpolation failure did not name the affected key"
not_contains "$OUTPUT" 'DOLLAR_FIXTURE' "interpolation diagnostic leaked secret value"
assert_no_secret_fixtures
pass "Bash-vs-Compose interpolation drift is detected without exposing values"

# 6. ZATCA_ENCRYPT_KEY valid 64-char hex vs malformed length warning
reset_mocks
cp "$TEST_REPO/config.env" "$TEST_ROOT/hex-key.env"
HEX64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
sed -i "s/^ZATCA_ENCRYPT_KEY=.*/ZATCA_ENCRYPT_KEY=${HEX64}/" "$TEST_ROOT/hex-key.env"
python3 - "$COMPOSE_JSON_FILE" "$RUNNING_ENV_FILE" "$HEX64" <<'PY'
import json, sys
c_path, r_path, key = sys.argv[1:4]
c = json.load(open(c_path, encoding="utf-8"))
c["services"]["zatca-daemon"]["environment"]["ENCRYPT_KEY"] = key
json.dump(c, open(c_path, "w", encoding="utf-8"))
r = [("ENCRYPT_KEY=" + key if x.startswith("ENCRYPT_KEY=") else x) for x in json.load(open(r_path, encoding="utf-8"))]
json.dump(r, open(r_path, "w", encoding="utf-8"))
PY
run_verify --env-file "$TEST_ROOT/hex-key.env"
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "valid 64-char hex key run failed"; }
contains "$OUTPUT" 'PASS | config.encrypt_key | ZATCA_ENCRYPT_KEY format valid (32-byte hex AES-256 key)' \
    "valid 64-char hex encryption key did not pass"
not_contains "$OUTPUT" "$HEX64" "hex encryption key was leaked"
pass "32-byte AES-256 encryption key format is validated without leaking key material"

# 7. Legacy standalone NATS container port conflict
reset_mocks
MOCK_DOCKER_PS="nats"
MOCK_LEGACY_NATS_PORT="4222"
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "legacy NATS port conflict was accepted"
contains "$OUTPUT" 'FAIL | host.nats_port_conflict' "legacy NATS port conflict was not flagged"
assert_no_secret_fixtures
pass "legacy standalone NATS port conflicts fail with guided remediation"

# 8. Non-secret env parity diff shows expected/actual while secret env parity diff withholds values
reset_mocks
python3 - "$RUNNING_ENV_FILE" <<'PY'
import json, sys
path = sys.argv[1]
env = json.load(open(path, encoding="utf-8"))
env = [
    "DB_HOST=old-db.test.internal" if x.startswith("DB_HOST=") else
    "DB_PASS=OTHER_SECRET_FIXTURE" if x.startswith("DB_PASS=") else x
    for x in env
]
json.dump(env, open(path, "w", encoding="utf-8"))
PY
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "env parity mismatch was accepted"
contains "$OUTPUT" 'INFO | env.parity.diff | DB_HOST: expected=db.test.internal actual=old-db.test.internal' \
    "non-secret env parity diff did not show expected vs actual"
contains "$OUTPUT" 'INFO | env.parity.diff | DB_PASS: secret value differs' \
    "secret env parity diff did not report redacted diff"
not_contains "$OUTPUT" 'OTHER_SECRET_FIXTURE' "secret env parity diff exposed running container secret"
assert_no_secret_fixtures
pass "env parity shows non-secret expected/actual diffs while strictly redacting secret diffs"

# 9. Bounded redacted container logs on health failure
reset_mocks
CURL_HEALTH_FAIL=1
MOCK_CONTAINER_LOGS='level=error msg="connect failed user:DB_PASSWORD_FIXTURE@tcp(db:3306)/m"\nlevel=error msg="monitor_pass=MONITOR_PASSWORD_FIXTURE auth failed"'
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "health failure with container logs was accepted"
contains "$OUTPUT" 'INFO | daemon.logs.header' "bounded container log header was not printed on health failure"
contains "$OUTPUT" '[REDACTED]' "container logs were not redacted"
not_contains "$OUTPUT" 'DB_PASSWORD_FIXTURE' "container logs leaked DB password"
not_contains "$OUTPUT" 'MONITOR_PASSWORD_FIXTURE' "container logs leaked monitor password"
assert_no_secret_fixtures
pass "container logs printed on health failure strictly redact secrets and DSNs"

# 10. Dokku tenant backend wiring check when dokku container is running
reset_mocks
MOCK_DOCKER_PS="dokku"
MOCK_TENANT_NATS_URL="nats://host.docker.internal:9999"
MOCK_TENANT_NATS_PASSWORD="WRONG_TENANT_NATS_PASSWORD_FIXTURE"
MOCK_TENANT_DOCKER_OPTS=""
run_verify
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "advisory tenant wiring warning unexpectedly failed daemon check"; }
contains "$OUTPUT" 'WARN | tenants.wiring.acme-backend' "mismatched Dokku tenant wiring was not flagged"
contains "$OUTPUT" 'missing host.docker.internal:host-gateway' "missing host-gateway was not flagged"
contains "$OUTPUT" 'NATS_PASSWORD does not match selected config' "tenant NATS_PASSWORD mismatch was not flagged"
not_contains "$OUTPUT" 'WRONG_TENANT_NATS_PASSWORD_FIXTURE' "tenant NATS_PASSWORD leaked"
assert_no_secret_fixtures
pass "Dokku tenant wiring checks host-gateway, NATS_URL, and boolean NATS_PASSWORD safely"

echo
echo "=== direct host-Bash MySQL verification & verifier fixes ==="

# 11. --db-only direct host-Bash pass with zero Docker calls and --config=PATH syntax
reset_mocks
cat > "$TEST_ROOT/db-only.env" <<'DBONLY'
ZATCA_DAEMON_ENABLED=0
ZATCA_DB_USER=runtime-user
ZATCA_DB_PASSWORD=DB_PASSWORD_FIXTURE
MYSQL_HOST=host.docker.internal
MYSQL_PORT=3306
MYSQL_MASTER_DB=zatca_master
DBONLY
chmod 600 "$TEST_ROOT/db-only.env"
run_verify "--config=$TEST_ROOT/db-only.env" --db-only --verbose
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "--db-only direct host-Bash check failed unexpectedly (status=$RUN_STATUS)"; }
[ ! -s "$DOCKER_LOG" ] || { cat "$DOCKER_LOG" >&2; fail "--db-only invoked Docker unexpectedly"; }
contains "$OUTPUT" 'PASS | database.host.runtime_tcp' "--db-only did not run direct host TCP probe"
contains "$OUTPUT" 'PASS | database.host.master_db' "--db-only did not verify master DB visibility"
contains "$OUTPUT" 'PASS | database.host.runtime_plaintext' "--db-only did not run plaintext TCP probe"
contains "$MYSQL_LOG" '--get-server-public-key' "MySQL 8 TCP probes did not pass --get-server-public-key"
contains "$OUTPUT" "IDENTIFIED BY '[REDACTED]'" "SHOW GRANTS did not scrub IDENTIFIED BY hash"
contains "$OUTPUT" 'OVERALL PASS | selected configuration and direct host-Bash MySQL database access verified without Docker' \
    "--db-only OVERALL PASS summary did not reflect non-Docker scope"
assert_no_secret_fixtures
pass "--db-only verifies MySQL directly from host Bash with zero Docker calls and scrubs SHOW GRANTS"

# 12. Duplicate ZATCA_DB_PASSWORD with differing values + shadowed earlier line proof
reset_mocks
cat > "$TEST_ROOT/dup-pass.env" <<'DUP'
ZATCA_DB_USER=runtime-user
ZATCA_DB_PASSWORD=DB_PASSWORD_FIXTURE
MYSQL_HOST=host.docker.internal
MYSQL_PORT=3306
MYSQL_MASTER_DB=zatca_master
ZATCA_DB_PASSWORD=SHADOWED_WRONG_PASSWORD_FIXTURE
DUP
chmod 600 "$TEST_ROOT/dup-pass.env"
run_verify "--env-file=$TEST_ROOT/dup-pass.env" --db-only
[ "$RUN_STATUS" -eq 1 ] || { cat "$OUTPUT" >&2; fail "shadowed duplicate password did not fail effective login (status=$RUN_STATUS)"; }
contains "$OUTPUT" 'WARN | config.duplicate_keys |' "duplicate key warning missing"
contains "$OUTPUT" 'ZATCA_DB_PASSWORD (lines 2, 6; values DIFFER' "duplicate key warning did not include line numbers and value diff"
contains "$OUTPUT" 'FAIL | database.host.runtime_tcp' "effective wrong password did not fail runtime_tcp"
contains "$OUTPUT" '(using password: YES)' "redactor corrupted (using password: YES) diagnostic"
contains "$OUTPUT" 'WARN | database.host.shadowed_password | EARLIER shadowed ZATCA_DB_PASSWORD on line 2' \
    "shadowed earlier line probe did not prove line 2 authenticates"
contains "$OUTPUT" 'HINT | database.diagnosis | Duplicate ZATCA_DB_PASSWORD' "diagnosis did not pinpoint duplicate override"
not_contains "$OUTPUT" 'SHADOWED_WRONG_PASSWORD_FIXTURE' "wrong shadowed password leaked"
assert_no_secret_fixtures
pass "duplicate ZATCA_DB_PASSWORD reports line numbers, proves earlier working line via host TCP, and leaks no secrets"

# 13. Same-user ZATCA_DB_USER == ZATCA_ADMIN_DB_USER password mismatch
reset_mocks
cat > "$TEST_ROOT/same-user-mismatch.env" <<'SAMEU'
ZATCA_DB_USER=runtime-user
ZATCA_DB_PASSWORD=WRONG_RUNTIME_SECRET_FIXTURE
ZATCA_ADMIN_DB_USER=runtime-user
ZATCA_ADMIN_DB_PASSWORD=DB_PASSWORD_FIXTURE
MYSQL_HOST=host.docker.internal
MYSQL_PORT=3306
MYSQL_MASTER_DB=zatca_master
SAMEU
chmod 600 "$TEST_ROOT/same-user-mismatch.env"
run_verify --config "$TEST_ROOT/same-user-mismatch.env" --db-only
[ "$RUN_STATUS" -eq 1 ] || fail "same-user password mismatch did not fail runtime check"
contains "$OUTPUT" 'WARN | config.db_password_mismatch' "same-user password mismatch inside config.env was not flagged"
contains "$OUTPUT" 'FAIL | database.host.runtime_tcp' "wrong runtime password did not fail"
contains "$OUTPUT" 'PASS | database.host.onboarding_tcp' "working admin password for same user did not succeed"
contains "$OUTPUT" 'HINT | database.diagnosis | ZATCA_DB_USER and ZATCA_ADMIN_DB_USER both use' \
    "diagnosis did not pinpoint same-user onboarding vs runtime password mismatch"
not_contains "$OUTPUT" 'WRONG_RUNTIME_SECRET_FIXTURE' "mismatched runtime password leaked"
assert_no_secret_fixtures
pass "same-user password mismatch inside config.env is flagged and proved via host TCP"

# 14. Plaintext TLS mismatch (require_secure_transport=ON / --skip-ssl client)
reset_mocks
MOCK_MYSQL_HELP_MODE="skip-ssl"
MOCK_MYSQL_PLAINTEXT_FAIL=1
MOCK_MYSQL_SERVER_VARS='bind_address\t0.0.0.0\nport\t3306\nrequire_secure_transport\tON\ndefault_authentication_plugin\tcaching_sha2_password'
run_verify --config "$TEST_ROOT/db-only.env" --db-only
[ "$RUN_STATUS" -eq 1 ] || fail "plaintext TLS rejection did not fail --db-only verification"
contains "$OUTPUT" 'PASS | database.host.runtime_tcp' "TLS TCP probe should have passed"
contains "$OUTPUT" 'FAIL | database.host.runtime_plaintext' "plaintext TCP probe (--skip-ssl) did not fail"
contains "$OUTPUT" 'FAIL | database.host.tls_policy' "require_secure_transport=ON was not flagged"
contains "$OUTPUT" 'HINT | database.diagnosis | Credentials for' "diagnosis did not explain TLS-only vs Go plaintext mismatch"
assert_no_secret_fixtures
pass "TLS-required MySQL server is detected by plaintext probe and require_secure_transport check"

# 15. Unix socket-only grant ('user'@'localhost')
reset_mocks
MOCK_MYSQL_TCP_MODE="socket_only"
MOCK_MYSQL_SOCKET_OK=1
MOCK_MYSQL_USER_ROWS='runtime-user\tlocalhost\tcaching_sha2_password\tN\t'
run_verify --config "$TEST_ROOT/db-only.env" --db-only
[ "$RUN_STATUS" -eq 1 ] || fail "socket-only grant did not fail TCP check"
contains "$OUTPUT" 'FAIL | database.host.runtime_tcp' "TCP check should fail for socket-only grant"
contains "$OUTPUT" 'WARN | database.host.runtime_socket' "Unix socket fallback did not succeed and warn"
contains "$OUTPUT" 'WARN | database.host.localhost_only' "localhost-only mysql.user row was not flagged"
contains "$OUTPUT" 'HINT | database.diagnosis | Direct host-Bash TCP' "diagnosis did not identify socket-only access"
assert_no_secret_fixtures
pass "Unix socket fallback distinguishes socket-only localhost grants from TCP failures"

# 16. ~/.my.cnf option-file precedence masking check
reset_mocks
mkdir -p "$TEST_ROOT/mycnf-home"
printf '[client]\npassword=MYCNF_SECRET_FIXTURE\n' > "$TEST_ROOT/mycnf-home/.my.cnf"
chmod 600 "$TEST_ROOT/mycnf-home/.my.cnf"
MOCK_HOME="$TEST_ROOT/mycnf-home"
MOCK_MYSQL_MYCNF_OK=1
cat > "$TEST_ROOT/mycnf-test.env" <<'MYCNF'
ZATCA_DB_USER=runtime-user
ZATCA_DB_PASSWORD=CONFIG_WRONG_SECRET_FIXTURE
MYSQL_HOST=host.docker.internal
MYSQL_PORT=3306
MYSQL_MASTER_DB=zatca_master
MYCNF
chmod 600 "$TEST_ROOT/mycnf-test.env"
run_verify --config "$TEST_ROOT/mycnf-test.env" --db-only
[ "$RUN_STATUS" -eq 1 ] || fail "config.env wrong password should still fail when ~/.my.cnf succeeds"
contains "$OUTPUT" 'WARN | database.host.my_cnf' "~/.my.cnf masking was not detected"
contains "$OUTPUT" 'HINT | database.diagnosis | Direct host-Bash TCP with --no-defaults' "diagnosis did not mention ~/.my.cnf masking"
not_contains "$OUTPUT" 'CONFIG_WRONG_SECRET_FIXTURE' "wrong config password leaked"
not_contains "$OUTPUT" 'MYCNF_SECRET_FIXTURE' "~/.my.cnf password leaked"
assert_no_secret_fixtures
pass "~/.my.cnf option-file masking is detected without leaking credentials"

# 17. Docker-only grant safety: Docker zatca-check PASSES while host 127.0.0.1 returns 1045 -> INFO + OVERALL PASS
reset_mocks
MOCK_MYSQL_TCP_MODE="deny_host_1045"
run_verify
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "Docker-only grant caused false failure when Docker zatca-check PASSED"; }
contains "$OUTPUT" 'INFO | database.host.runtime_tcp' "Docker-only grant did not downgrade host 1045 to INFO"
not_contains "$OUTPUT" 'FAIL | database.host.runtime_tcp' "Docker-only grant emitted FAIL despite Docker PASS"
contains "$OUTPUT" 'OVERALL PASS |' "Docker-only grant did not reach OVERALL PASS"
assert_no_secret_fixtures
pass "Docker-subnet-only MySQL grants do not cause false failures when Docker zatca-check passes"

# 18. Deploy admin succeeds + mysql.user traps (host precedence, anonymous user, locked, ssl_type) + redacted admin grants
reset_mocks
mkdir -p "$TEST_ROOT/admin-diag-dir"
cat > "$TEST_ROOT/admin-diag-dir/config.env" <<'ADMCFG'
ZATCA_DB_USER=runtime-user
ZATCA_DB_PASSWORD=WRONG_RT_ADMTEST_FIXTURE
MYSQL_HOST=host.docker.internal
MYSQL_PORT=3306
MYSQL_MASTER_DB=zatca_master
ADMCFG
cat > "$TEST_ROOT/admin-diag-dir/install.env" <<'ADMINST'
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_ADMIN_USER=deploy-admin
MYSQL_ADMIN_PASSWORD=DEPLOY_ADMIN_SECRET_FIXTURE
ADMINST
chmod 600 "$TEST_ROOT/admin-diag-dir/config.env" "$TEST_ROOT/admin-diag-dir/install.env"
MOCK_MYSQL_DEPLOY_ADMIN_USER="deploy-admin"
MOCK_MYSQL_DEPLOY_ADMIN_PASS="DEPLOY_ADMIN_SECRET_FIXTURE"
MOCK_MYSQL_USER_ROWS='runtime-user\t%\tcaching_sha2_password\tN\t\nruntime-user\t172.%\tcaching_sha2_password\tY\tANY\n\tlocalhost\tmysql_native_password\tN\t'
MOCK_MYSQL_GRANTS="GRANT USAGE ON *.* TO 'runtime-user'@'%' IDENTIFIED WITH 'caching_sha2_password' AS '\$A\$005\$ab\\'SECRET_HASH_TOKEN_FIXTURE'\nGRANT USAGE ON *.* TO 'runtime-user'@'172.%' IDENTIFIED VIA unix_socket OR caching_sha2_password USING '\$A\$005\$ab;cd\\'MARIADB_HASH_TOKEN_FIXTURE'"
run_verify --config "$TEST_ROOT/admin-diag-dir/config.env" --db-only
[ "$RUN_STATUS" -eq 1 ] || fail "admin-diagnosed broken runtime should exit 1"
contains "$OUTPUT" 'INFO | config.drift.install_env | MYSQL_HOST uses compatible local aliases' \
    "compatible host.docker.internal vs 127.0.0.1 was not treated as INFO"
not_contains "$OUTPUT" 'WARN | config.drift.install_env | MYSQL_HOST differs' \
    "compatible local MYSQL_HOST aliases falsely warned"
contains "$OUTPUT" 'PASS | database.host.deploy_admin' "deployment admin account from install.env did not authenticate"
contains "$OUTPUT" 'WARN | database.host.host_precedence' "multiple host rows (172.% + %) did not warn on host precedence"
contains "$OUTPUT" 'WARN | database.host.anonymous_user' "anonymous user row was not flagged"
contains "$OUTPUT" 'FAIL | database.host.account_locked' "account_locked=Y was not flagged"
contains "$OUTPUT" 'FAIL | database.host.account_ssl' "ssl_type=ANY was not flagged"
contains "$OUTPUT" 'INFO | database.host.account_grants' "admin SHOW GRANTS for runtime account was not reported"
contains "$OUTPUT" 'IDENTIFIED WITH [REDACTED]' "IDENTIFIED WITH hash was not scrubbed from SHOW GRANTS"
contains "$OUTPUT" "USING '[REDACTED]'" "IDENTIFIED VIA USING hash was not scrubbed from SHOW GRANTS"
not_contains "$OUTPUT" 'DEPLOY_ADMIN_SECRET_FIXTURE' "deploy admin password leaked"
not_contains "$OUTPUT" 'WRONG_RT_ADMTEST_FIXTURE' "wrong runtime password leaked"
not_contains "$OUTPUT" 'SECRET_HASH_TOKEN_FIXTURE' "IDENTIFIED WITH hash leaked"
not_contains "$OUTPUT" 'MARIADB_HASH_TOKEN_FIXTURE' "MariaDB IDENTIFIED VIA USING hash leaked"
assert_no_secret_fixtures
pass "deploy admin probes mysql.user traps and redacted grants while treating local MYSQL_HOST aliases as compatible"

# 19. Stage 6 accepts HOST=host.docker.internal:3306 + DB_HOST + DB_PORT and flags DB_PORT mismatch
reset_mocks
cp "$TEST_REPO/config.env" "$TEST_ROOT/stage6-local.env"
sed -i 's/^MYSQL_HOST=.*/MYSQL_HOST=127.0.0.1/; s/^MYSQL_PORT=.*/MYSQL_PORT=3306/' "$TEST_ROOT/stage6-local.env"
write_database_target "127.0.0.1" "3306"
MOCK_DOCKER_PS="dokku"
MOCK_TENANT_HOST="host.docker.internal:3306"
MOCK_TENANT_DB_HOST="host.docker.internal"
MOCK_TENANT_DB_PORT="3306"
run_verify --config "$TEST_ROOT/stage6-local.env"
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "Stage 6 HOST=host.docker.internal:3306 check failed"; }
contains "$OUTPUT" 'PASS | tenants.wiring.acme-backend' "Stage 6 falsely warned on HOST=host.docker.internal:3306"
MOCK_TENANT_DB_PORT="3307"
run_verify --config "$TEST_ROOT/stage6-local.env"
contains "$OUTPUT" 'WARN | tenants.wiring.acme-backend' "Stage 6 did not flag DB_PORT mismatch"
contains "$OUTPUT" 'DB_PORT=3307 differs from expected 3306' "Stage 6 did not report exact DB_PORT mismatch"
pass "Stage 6 accepts HOST=host.docker.internal:3306 and validates DB_HOST/DB_PORT"

# 20. Stage 3 consolidates multiple recreate triggers into a single --recreate NEXT STEP
reset_mocks
RUNNING_STATE=false
python3 - "$RUNNING_ENV_FILE" <<'PY'
import json, sys
p = sys.argv[1]
env = [x for x in json.load(open(p, encoding="utf-8")) if not x.startswith("NATS_MONITOR_HOST=")]
env = ["DB_HOST=stale-db.test.internal" if x.startswith("DB_HOST=") else x for x in env]
json.dump(env, open(p, "w", encoding="utf-8"))
PY
run_verify
[ "$RUN_STATUS" -ne 0 ] || fail "stopped/drifted container unexpectedly passed"
recreate_count="$(grep -Fc 'setup-zatca-daemon.sh --config' "$OUTPUT" | tr -d '[:space:]')"
[ "$recreate_count" -eq 1 ] || { cat "$OUTPUT" >&2; fail "expected 1 consolidated --recreate NEXT STEP, got $recreate_count"; }
contains "$OUTPUT" 'start stopped container; apply NATS_MONITOR_HOST=0.0.0.0; sync running container env' \
    "consolidated --recreate NEXT STEP did not combine all Stage 3 reasons"
assert_no_secret_fixtures
pass "Stage 3 deduplicates multiple recreate triggers into one consolidated NEXT STEP"

# 21. --db-only passes when active CURRENT_USER() works and secondary host row is locked/SSL, and skips different-target install.env admin
reset_mocks
mkdir -p "$TEST_ROOT/secondary-row-dir"
cat > "$TEST_ROOT/secondary-row-dir/config.env" <<'SECROW'
ZATCA_DB_USER=runtime-user
ZATCA_DB_PASSWORD=DB_PASSWORD_FIXTURE
MYSQL_HOST=host.docker.internal
MYSQL_PORT=3306
MYSQL_MASTER_DB=zatca_master
SECROW
cat > "$TEST_ROOT/secondary-row-dir/install.env" <<'SECDRIFT'
MYSQL_HOST=10.9.9.9
MYSQL_PORT=3307
MYSQL_ADMIN_USER=other-server-admin
MYSQL_ADMIN_PASSWORD=OTHER_SERVER_SECRET_FIXTURE
SECDRIFT
chmod 600 "$TEST_ROOT/secondary-row-dir/config.env" "$TEST_ROOT/secondary-row-dir/install.env"
MOCK_MYSQL_USER_ROWS='runtime-user\t%\tcaching_sha2_password\tN\t\nruntime-user\t172.%\tcaching_sha2_password\tY\tANY'
run_verify --config "$TEST_ROOT/secondary-row-dir/config.env" --db-only
[ "$RUN_STATUS" -eq 0 ] || { cat "$OUTPUT" >&2; fail "healthy --db-only with locked secondary host row should exit 0 (status=$RUN_STATUS)"; }
contains "$OUTPUT" 'WARN | database.host.account_locked' "secondary locked row did not downgrade to WARN"
contains "$OUTPUT" 'WARN | database.host.account_ssl' "secondary SSL row did not downgrade to WARN"
contains "$OUTPUT" 'skipped deployment control-plane account from install.env' "different-target install.env admin was not skipped"
not_contains "$OUTPUT" 'OTHER_SERVER_SECRET_FIXTURE' "other-server deploy admin password leaked"
assert_no_secret_fixtures
pass "healthy --db-only downgrades inactive secondary locked/SSL rows to WARN and skips different-target install.env admin"

printf '\nAll environment-verifier wrapper tests passed.\n'
