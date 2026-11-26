#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup-zatca-daemon.sh"
HEALTH_SCRIPT="${SCRIPT_DIR}/health-zatca-daemon.sh"
CONFIG_FILE="${REPO_DIR}/config.env"
EXPLICIT_CONFIG=false
VERIFICATION_OK=true
DATABASE_DIAGNOSTIC_FILE=""
HEALTH_DIAGNOSTIC_FILE=""

cleanup_diagnostics() {
    [ -z "$DATABASE_DIAGNOSTIC_FILE" ] || rm -f -- "$DATABASE_DIAGNOSTIC_FILE"
    [ -z "$HEALTH_DIAGNOSTIC_FILE" ] || rm -f -- "$HEALTH_DIAGNOSTIC_FILE"
}
trap cleanup_diagnostics EXIT

usage() {
    cat <<'USAGE'
Usage: scripts/verify-zatca-environment.sh [--env-file PATH]

Verify the selected ZATCA deployment environment and the running daemon's
mapped environment. The default selected file is config.env in the repository
root. No alternate file is used when the selected file is missing.
USAGE
}

config_error() {
    printf 'FAIL | configuration | %s\n' "$1" >&2
    exit 2
}

mark_failure() {
    local status="$1" check="$2" message="$3"
    printf '%s | %s | %s\n' "$status" "$check" "$message"
    VERIFICATION_OK=false
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-file)
            [ "$#" -ge 2 ] || config_error "--env-file requires a path"
            [ -n "$2" ] || config_error "--env-file requires a path"
            CONFIG_FILE="$2"
            EXPLICIT_CONFIG=true
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            config_error "unknown invocation option"
            ;;
    esac
done

if [ "$EXPLICIT_CONFIG" = true ] && [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PWD}/${CONFIG_FILE}"
fi

[ -f "$CONFIG_FILE" ] || config_error "selected configuration file does not exist"
[ -r "$CONFIG_FILE" ] || config_error "selected configuration file is not readable"

readonly SELECTED_CONFIG_FILE="$CONFIG_FILE"
set +e
set -a
source "$SELECTED_CONFIG_FILE" >/dev/null 2>&1
source_status=$?
set +a
set +x
set -euo pipefail
CONFIG_FILE="$SELECTED_CONFIG_FILE"
VERIFICATION_OK=true
[ "$source_status" -eq 0 ] || config_error "selected configuration file could not be loaded"

case "${ZATCA_DAEMON_ENABLED:-}" in
    1|true|yes) ;;
    *) config_error "ZATCA_DAEMON_ENABLED must be enabled" ;;
esac

for required_setting in \
    ZATCA_DAEMON_IMAGE \
    ZATCA_DB_USER \
    ZATCA_DB_PASSWORD \
    ZATCA_ENCRYPT_KEY \
    ZATCA_MONITOR_PASSWORD \
    NATS_USER \
    NATS_PASSWORD; do
    [ -n "${!required_setting:-}" ] ||
        config_error "required setting ${required_setting} is missing"
done

if { [ -n "${ZATCA_ADMIN_DB_USER:-}" ] && [ -z "${ZATCA_ADMIN_DB_PASSWORD:-}" ]; } ||
    { [ -z "${ZATCA_ADMIN_DB_USER:-}" ] && [ -n "${ZATCA_ADMIN_DB_PASSWORD:-}" ]; }; then
    config_error "ZATCA_ADMIN_DB_USER and ZATCA_ADMIN_DB_PASSWORD must be configured together"
fi

[ -f "$SETUP_SCRIPT" ] || config_error "daemon configuration validator is unavailable"
command -v docker >/dev/null 2>&1 ||
    mark_failure "NOT VERIFIED" "docker" "Docker is unavailable"
command -v python3 >/dev/null 2>&1 ||
    mark_failure "NOT VERIFIED" "python3" "Python 3 is unavailable"

if bash "$SETUP_SCRIPT" --config "$CONFIG_FILE" --validate-only >/dev/null 2>&1; then
    printf 'PASS | config.validation | required settings and Compose validation passed\n'
else
    config_error "daemon configuration validation failed"
fi

COMPOSE_FILE="${ZATCA_DAEMON_COMPOSE_FILE:-${REPO_DIR}/dashboard/docker-compose.zatca.yml}"
if [ ! -f "$COMPOSE_FILE" ]; then
    mark_failure "NOT VERIFIED" "compose.resolved" "daemon Compose file is unavailable"
    compose_json=""
else
    if compose_json="$(
        docker compose --env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" \
            --profile zatca config --format json 2>/dev/null
    )"; then
        printf 'PASS | compose.resolved | daemon Compose environment resolved\n'
    else
        mark_failure "NOT VERIFIED" "compose.resolved" "daemon Compose environment could not be resolved"
        compose_json=""
    fi
fi

database_target_output=$'unavailable\tunavailable'
if [ -n "$compose_json" ] && command -v python3 >/dev/null 2>&1; then
    if parsed_database_target="$(
        printf '%s' "$compose_json" |
            python3 -c '
import ipaddress
import json
import re
import sys

def unavailable():
    print("unavailable\tunavailable")

try:
    document = json.load(sys.stdin)
except json.JSONDecodeError:
    unavailable()
    raise SystemExit(0)

services = document.get("services") if isinstance(document, dict) else None
service = services.get("zatca-daemon") if isinstance(services, dict) else None
environment = service.get("environment") if isinstance(service, dict) else None
if not isinstance(environment, dict):
    unavailable()
    raise SystemExit(0)

host = environment.get("DB_HOST")
if not isinstance(host, str) or not host.strip():
    target_class = "unavailable"
else:
    host = host.strip()
    if host.casefold() == "host.docker.internal":
        target_class = "host_gateway"
    elif host.casefold() == "localhost":
        target_class = "container_loopback"
    else:
        address = host[1:-1] if host.startswith("[") and host.endswith("]") else host
        try:
            is_loopback = ipaddress.ip_address(address).is_loopback
        except ValueError:
            is_loopback = False
        target_class = "container_loopback" if is_loopback else "custom_host_redacted"

port = environment.get("DB_PORT")
if type(port) is int:
    numeric_port = port
elif isinstance(port, str) and re.fullmatch(r"[0-9]{1,5}", port):
    numeric_port = int(port)
else:
    numeric_port = None
safe_port = str(numeric_port) if numeric_port is not None and 1 <= numeric_port <= 65535 else "unavailable"
print("%s\t%s" % (target_class, safe_port))
'
    )" 2>/dev/null; then
        [ -z "$parsed_database_target" ] || database_target_output="$parsed_database_target"
    fi
fi
IFS=$'\t' read -r database_target_class database_target_port <<< "$database_target_output"
case "$database_target_class" in
    host_gateway|container_loopback|custom_host_redacted|unavailable) ;;
    *) database_target_class="unavailable"; database_target_port="unavailable" ;;
esac
if [ "$database_target_port" != "unavailable" ] &&
    [[ ! "$database_target_port" =~ ^[0-9]{1,5}$ ]]; then
    database_target_port="unavailable"
fi
if [ "$database_target_class" = "unavailable" ]; then
    database_target_port="unavailable"
fi
printf 'INFO | database.target | class=%s port=%s\n' \
    "$database_target_class" "$database_target_port"

CONTAINER="${ZATCA_DAEMON_CONTAINER:-zatca-daemon}"
if container_state="$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)"; then
    if [ "$container_state" = true ]; then
        printf 'PASS | daemon.container | configured daemon container is running\n'
    else
        mark_failure "FAIL" "daemon.container" "configured daemon container is not running"
    fi
else
    mark_failure "NOT VERIFIED" "daemon.container" "configured daemon container could not be inspected"
fi

if running_env_json="$(
    docker inspect --format '{{json .Config.Env}}' "$CONTAINER" 2>/dev/null
)"; then
    if [ -n "$compose_json" ]; then
        if parity_result="$(
            printf '%s\0%s' "$compose_json" "$running_env_json" |
                python3 -c '
import json
import re
import sys

def invalid():
    print("INVALID")
    raise SystemExit(0)

parts = sys.stdin.buffer.read().split(b"\0")
if len(parts) != 2:
    invalid()
try:
    compose = json.loads(parts[0])
    running = json.loads(parts[1])
except (TypeError, ValueError):
    invalid()

try:
    mapped = compose["services"]["zatca-daemon"]["environment"]
except (KeyError, TypeError):
    invalid()
if not isinstance(mapped, dict) or not mapped:
    invalid()

key_pattern = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
expected = {}
for key, value in mapped.items():
    if not isinstance(key, str) or not key_pattern.fullmatch(key):
        invalid()
    if not isinstance(value, str):
        invalid()
    expected[key] = value

if not isinstance(running, list):
    invalid()
actual = {}
for item in running:
    if not isinstance(item, str):
        invalid()
    key, separator, value = item.partition("=")
    if not separator or not key_pattern.fullmatch(key) or key in actual:
        invalid()
    actual[key] = value

mismatched = sorted(key for key, value in expected.items() if actual.get(key) != value)
if mismatched:
    print("MISMATCH\t" + "\t".join(mismatched))
else:
    print("MATCH")
'
        )"; then
            case "$parity_result" in
                MATCH)
                    printf 'PASS | env.parity | every mapped daemon setting matches the running container\n'
                    ;;
                MISMATCH$'\t'*)
                    mismatch_keys="${parity_result#MISMATCH$'\t'}"
                    mismatch_keys="${mismatch_keys//$'\t'/, }"
                    mark_failure "FAIL" "env.parity" "mismatched keys: ${mismatch_keys}"
                    ;;
                *)
                    mark_failure "NOT VERIFIED" "env.parity" "Compose or container environment evidence is malformed"
                    ;;
            esac
        else
            mark_failure "NOT VERIFIED" "env.parity" "environment parity comparison could not be completed"
        fi
    else
        mark_failure "NOT VERIFIED" "env.parity" "Compose environment is unavailable for comparison"
    fi
else
    mark_failure "NOT VERIFIED" "env.parity" "running daemon environment could not be inspected"
fi

is_valid_image_id() {
    [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]
}

read_safe_image_revision() {
    local image="$1" revision
    if revision="$(
        docker image inspect \
            --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
            "$image" 2>/dev/null
    )" && [[ "$revision" =~ ^[[:xdigit:]]{7,40}$ ]]; then
        printf '%s' "${revision,,}"
    else
        printf 'unavailable'
    fi
}

CONFIGURED_IMAGE_ID=""
RUNNING_IMAGE_ID=""
CONFIGURED_IMAGE_ID_DISPLAY="unavailable"
RUNNING_IMAGE_ID_DISPLAY="unavailable"
CONFIGURED_IMAGE_REVISION="unavailable"
RUNNING_IMAGE_REVISION="unavailable"

if CONFIGURED_IMAGE_ID="$(
    docker image inspect --format '{{.Id}}' "$ZATCA_DAEMON_IMAGE" 2>/dev/null
)"; then
    if is_valid_image_id "$CONFIGURED_IMAGE_ID"; then
        CONFIGURED_IMAGE_ID_DISPLAY="$CONFIGURED_IMAGE_ID"
        CONFIGURED_IMAGE_REVISION="$(read_safe_image_revision "$CONFIGURED_IMAGE_ID")"
    else
        CONFIGURED_IMAGE_ID=""
        mark_failure "NOT VERIFIED" "daemon.image" "configured daemon image returned an invalid image ID"
    fi
else
    mark_failure "NOT VERIFIED" "daemon.image" "configured daemon image is unavailable locally"
fi

if RUNNING_IMAGE_ID="$(
    docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null
)"; then
    if is_valid_image_id "$RUNNING_IMAGE_ID"; then
        RUNNING_IMAGE_ID_DISPLAY="$RUNNING_IMAGE_ID"
        RUNNING_IMAGE_REVISION="$(read_safe_image_revision "$RUNNING_IMAGE_ID")"
    else
        RUNNING_IMAGE_ID=""
        mark_failure "NOT VERIFIED" "daemon.image" "running daemon returned an invalid image ID"
    fi
else
    mark_failure "NOT VERIFIED" "daemon.image" "running daemon image could not be inspected"
fi

printf 'INFO | daemon.image.provenance | configured_id=%s configured_revision=%s running_id=%s running_revision=%s\n' \
    "$CONFIGURED_IMAGE_ID_DISPLAY" "$CONFIGURED_IMAGE_REVISION" \
    "$RUNNING_IMAGE_ID_DISPLAY" "$RUNNING_IMAGE_REVISION"

if [ -n "$CONFIGURED_IMAGE_ID" ] && [ -n "$RUNNING_IMAGE_ID" ]; then
    if [ "$CONFIGURED_IMAGE_ID" = "$RUNNING_IMAGE_ID" ]; then
        printf 'PASS | daemon.image | configured image matches the running daemon image\n'
    else
        mark_failure "FAIL" "daemon.image" "configured image does not match the running daemon image"
        printf 'HINT | daemon.image | configured and running image IDs differ; matching source revision labels do not prove identical image artifacts. Run scripts/rebuild-zatca-daemon.sh, then rerun scripts/verify-zatca-environment.sh\n'
    fi
fi

database_report=""
database_exit_status=125
database_probe_started=false
if [ -n "$CONFIGURED_IMAGE_ID" ] && [ -n "$compose_json" ]; then
    if DATABASE_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
        database_probe_started=true
        if database_report="$(
            docker compose --env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" \
                --profile zatca-check run --rm --no-deps zatca-check \
                2>"$DATABASE_DIAGNOSTIC_FILE"
        )"; then
            database_exit_status=0
        else
            database_exit_status=$?
        fi
    else
        mark_failure "NOT VERIFIED" "database.report" \
            "private diagnostic capture could not be created; verifier was not started"
    fi
else
    mark_failure "NOT VERIFIED" "database.report" "one-shot verifier image or Compose evidence is unavailable"
fi

if [ "$database_probe_started" = true ]; then
    if [ -n "$database_report" ]; then
        if database_validation="$(
            printf '%s' "$database_report" |
                DAEMON_EXIT_STATUS="$database_exit_status" python3 -c '
import json
import os
import re
import sys

def invalid():
    raise SystemExit(2)

raw = sys.stdin.read()
if "\n" in raw or "\r" in raw:
    invalid()
try:
    report = json.loads(raw)
except (TypeError, ValueError):
    invalid()
if not isinstance(report, dict) or set(report) != {"schema_version", "overall_status", "checks"}:
    invalid()
if type(report["schema_version"]) is not int or report["schema_version"] != 1:
    invalid()

statuses = {"PASS", "FAIL", "NOT_VERIFIED"}
categories = {
    "configuration", "connection", "timeout", "registry", "schema",
    "permission", "decryption", "not_ready", "internal",
}
target_fields = {"account_role", "tenant_id", "database", "branch_id", "operation"}
id_pattern = re.compile(r"^[A-Za-z0-9._:-]{1,256}$")
safe_value = re.compile(r"^[A-Za-z0-9._:$-]{1,128}$")
checks = report["checks"]
if not isinstance(checks, list) or not checks:
    invalid()

seen = set()
observed = []
lines = []
for check in checks:
    if not isinstance(check, dict):
        invalid()
    keys = set(check)
    if not {"id", "status", "target"}.issubset(keys) or keys - {
        "id", "status", "target", "error_category", "mysql_code",
    }:
        invalid()
    check_id = check["id"]
    status = check["status"]
    target = check["target"]
    if not isinstance(check_id, str) or not id_pattern.fullmatch(check_id) or check_id in seen:
        invalid()
    if not isinstance(status, str) or status not in statuses:
        invalid()
    if not isinstance(target, dict) or set(target) - target_fields:
        invalid()
    role = target.get("account_role")
    if role is not None and (
        not isinstance(role, str) or role not in {"runtime", "onboarding"}
    ):
        invalid()
    for field in ("tenant_id", "database", "operation"):
        value = target.get(field)
        if value is not None and (not isinstance(value, str) or not safe_value.fullmatch(value)):
            invalid()
    branch_id = target.get("branch_id")
    if branch_id is not None and (type(branch_id) is not int or branch_id <= 0):
        invalid()
    category = check.get("error_category")
    if category is not None and (
        not isinstance(category, str) or category not in categories
    ):
        invalid()
    mysql_code = check.get("mysql_code")
    if mysql_code is not None and (type(mysql_code) is not int or mysql_code < 0):
        invalid()
    if status == "PASS" and ("error_category" in check or "mysql_code" in check):
        invalid()

    seen.add(check_id)
    observed.append(status)
    context = []
    for field in ("account_role", "tenant_id", "branch_id", "operation"):
        if field in target:
            context.append("%s=%s" % (field, target[field]))
    if category is not None:
        context.append("error_category=%s" % category)
    if mysql_code is not None:
        context.append("mysql_code=%s" % mysql_code)
    lines.append("CHECK\t%s\t%s\t%s" % (
        "NOT VERIFIED" if status == "NOT_VERIFIED" else status,
        check_id,
        ", ".join(context) if context else "target=unspecified",
    ))

if "FAIL" in observed:
    aggregate = "FAIL"
elif "NOT_VERIFIED" in observed:
    aggregate = "NOT_VERIFIED"
else:
    aggregate = "PASS"
if report["overall_status"] != aggregate:
    invalid()
process_status = int(os.environ["DAEMON_EXIT_STATUS"])
if (process_status == 0) != (aggregate == "PASS"):
    invalid()
print("REPORT\t" + aggregate)
for line in lines:
    print(line)
' 2>/dev/null
        )"; then
            database_report_status=""
            while IFS=$'\t' read -r record_type status check_id context; do
                case "$record_type" in
                    REPORT)
                        database_report_status="$status"
                        ;;
                    CHECK)
                        case "$status" in
                            PASS)
                                printf 'PASS | %s | %s\n' "database.${check_id}" "$context"
                                ;;
                            FAIL)
                                mark_failure "FAIL" "database.${check_id}" "$context"
                                if [[ "$context" == *"mysql_code=1045"* ]]; then
                                    printf 'HINT | database.%s | MySQL 1045 means the server denied this tested connection; it does not prove the password is wrong. A successful Dokku admin test does not verify the daemon connection account/host match; compare the daemon target and MySQL host grants from its Compose network before changing credentials, without exposing them.\n' \
                                        "$check_id"
                                fi
                                ;;
                            "NOT VERIFIED")
                                mark_failure "NOT VERIFIED" "database.${check_id}" "$context"
                                ;;
                        esac
                        ;;
                esac
            done <<< "$database_validation"
            if [ "$database_report_status" != PASS ]; then
                VERIFICATION_OK=false
            fi
        else
            mark_failure "NOT VERIFIED" "database.report" "daemon JSON report is malformed, unknown, or inconsistent"
        fi
    else
        if grep -Eiq 'unknown flag|flag provided but not defined' "$DATABASE_DIAGNOSTIC_FILE"; then
            database_failure_detail="daemon image rejected --verify-db/--json; database probe was not run"
        elif [ "$database_exit_status" -eq 125 ]; then
            database_failure_detail="Docker could not start the one-shot verifier (exit 125); no database result was produced"
        elif [ "$database_exit_status" -eq 0 ]; then
            database_failure_detail="one-shot verifier exited successfully without a JSON report; database result is unavailable"
        else
            database_failure_detail="one-shot verifier exited with status ${database_exit_status} without JSON; database connection and permissions were not verified"
        fi
        mark_failure "NOT VERIFIED" "database.report" "$database_failure_detail"
    fi
fi

MONITOR_HOST="${ZATCA_NATS_MONITOR_HOST:-127.0.0.1}"
MONITOR_PORT="${ZATCA_NATS_MONITOR_PORT:-8222}"
monitor_target_class="custom_host_redacted"
case "${MONITOR_HOST,,}" in
    localhost|127.0.0.1|::1) monitor_target_class="loopback" ;;
esac

safe_monitor_port="unavailable"
if [[ "$MONITOR_PORT" =~ ^[0-9]{1,5}$ ]] &&
    (( 10#$MONITOR_PORT >= 1 && 10#$MONITOR_PORT <= 65535 )); then
    safe_monitor_port="$MONITOR_PORT"
fi
monitor_context="class=${monitor_target_class} port=${safe_monitor_port}"
printf 'INFO | daemon.monitor.target | %s endpoints=/healthz,/jsz\n' "$monitor_context"

health_output=""
health_exit_status=125
health_probe_started=false
if [ ! -f "$HEALTH_SCRIPT" ]; then
    mark_failure "NOT VERIFIED" "daemon.health" "daemon health checker is unavailable"
elif HEALTH_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
    health_probe_started=true
    if health_output="$(bash "$HEALTH_SCRIPT" --config "$CONFIG_FILE" --json 2>"$HEALTH_DIAGNOSTIC_FILE")"; then
        health_exit_status=0
    else
        health_exit_status=$?
    fi
else
    mark_failure "NOT VERIFIED" "daemon.health" \
        "private diagnostic capture could not be created; health check was not started"
fi

if [ "$health_probe_started" = true ]; then
    if [ -n "$health_output" ]; then
        if health_result="$(
            printf '%s' "$health_output" |
                HEALTH_EXIT_STATUS="$health_exit_status" python3 -c '
import json
import os
import sys

try:
    health = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(2)
if not isinstance(health, dict):
    raise SystemExit(2)
status = health.get("status")
limits_ok = health.get("limits_ok")
if (
    not isinstance(status, str)
    or status not in {"healthy", "backlog_exceeded", "disabled"}
    or type(limits_ok) is not bool
):
    raise SystemExit(2)
if status == "healthy":
    required = ("stream", "pending", "ack_pending", "redelivered", "stream_messages", "consumer_count")
    if health.get("stream") != "ZATCA":
        raise SystemExit(2)
    for field in required[1:]:
        if type(health.get(field)) is not int or health[field] < 0:
            raise SystemExit(2)
print("%s\t%s\t%s" % (status, "true" if limits_ok else "false", os.environ["HEALTH_EXIT_STATUS"]))
' 2>/dev/null
        )"; then
            IFS=$'\t' read -r health_status limits_ok health_exit_status <<< "$health_result"
            case "$health_status:$limits_ok:$health_exit_status" in
                healthy:true:0)
                    printf 'PASS | daemon.health | authenticated /healthz readiness and JetStream backlog are healthy\n'
                    ;;
                backlog_exceeded:false:*)
                    mark_failure "FAIL" "daemon.health" \
                        "/jsz JetStream backlog exceeds configured thresholds (${monitor_context})"
                    ;;
                disabled:*)
                    mark_failure "FAIL" "daemon.health" \
                        "health checker reports disabled; /healthz and /jsz were not verified (${monitor_context})"
                    ;;
                *)
                    mark_failure "NOT VERIFIED" "daemon.health" "daemon health evidence is not healthy or exit status is inconsistent"
                    ;;
            esac
        else
            mark_failure "NOT VERIFIED" "daemon.health" \
                "health checker did not provide a valid /healthz and /jsz report (${monitor_context})"
        fi
    else
        health_http_status="$(
            grep -Eo 'returned error: [0-9]{3}' "$HEALTH_DIAGNOSTIC_FILE" |
                tail -n 1 | grep -Eo '[0-9]{3}$' || true
        )"
        health_curl_code="$(
            grep -Eo 'curl: \([0-9]+\)' "$HEALTH_DIAGNOSTIC_FILE" |
                tail -n 1 | tr -cd '0-9' || true
        )"
        case "$health_curl_code" in
            [0-9]|[0-9][0-9]|[0-9][0-9][0-9]) ;;
            *) health_curl_code="" ;;
        esac
        health_curl_category=""
        case "$health_curl_code" in
            6) health_curl_category="name resolution failure" ;;
            7) health_curl_category="connection failure" ;;
            28) health_curl_category="timeout" ;;
            56) health_curl_category="response receive failure" ;;
            "") ;;
            *) health_curl_category="transport failure" ;;
        esac
        if grep -Fq 'daemon readiness check failed' "$HEALTH_DIAGNOSTIC_FILE"; then
            if [ "$health_http_status" = 401 ] || [ "$health_http_status" = 403 ]; then
                health_failure_detail="/healthz rejected monitor authentication (HTTP ${health_http_status})"
            elif [ -n "$health_http_status" ]; then
                health_failure_detail="/healthz returned HTTP ${health_http_status}; daemon readiness failed"
            elif [ "$health_curl_code" = 56 ]; then
                health_failure_detail="/healthz response receive failure (curl error 56); no complete HTTP response was obtained, and this does not establish a connection reset or identify the cause"
            elif [ -n "$health_curl_code" ]; then
                health_failure_detail="/healthz request failed before an HTTP response (${health_curl_category}; curl error ${health_curl_code})"
            else
                health_failure_detail="/healthz readiness request failed; response details withheld"
            fi
        elif grep -Fq 'daemon JetStream monitor check failed' "$HEALTH_DIAGNOSTIC_FILE"; then
            if [ "$health_http_status" = 401 ] || [ "$health_http_status" = 403 ]; then
                health_failure_detail="/jsz rejected monitor authentication (HTTP ${health_http_status})"
            elif [ -n "$health_http_status" ]; then
                health_failure_detail="/jsz returned HTTP ${health_http_status}"
            elif [ "$health_curl_code" = 56 ]; then
                health_failure_detail="/jsz response receive failure (curl error 56); no complete HTTP response was obtained, and this does not establish a connection reset or identify the cause"
            elif [ -n "$health_curl_code" ]; then
                health_failure_detail="/jsz request failed before an HTTP response (${health_curl_category}; curl error ${health_curl_code})"
            else
                health_failure_detail="/jsz monitor request failed; response details withheld"
            fi
        elif grep -Fq 'missing ZATCA stream' "$HEALTH_DIAGNOSTIC_FILE"; then
            health_failure_detail="JetStream monitor response does not contain the ZATCA stream"
        elif grep -Fq 'invalid JetStream health JSON' "$HEALTH_DIAGNOSTIC_FILE"; then
            health_failure_detail="/jsz returned invalid JSON"
        else
            health_failure_detail="health checker exited with status ${health_exit_status} without a valid health report"
        fi
        health_failure_detail="${health_failure_detail} (${monitor_context})"
        mark_failure "NOT VERIFIED" "daemon.health" "$health_failure_detail"
        if [ "$health_curl_code" = 56 ] && [ -z "$health_http_status" ]; then
            printf 'HINT | daemon.health | curl error 56 indicates a response receive failure; no complete HTTP response was obtained. If it persists after database access and configured/running image alignment are verified, inspect the daemon container logs and state. This does not establish a connection reset or identify the cause.\n'
        fi
    fi
fi

if [ "$VERIFICATION_OK" = true ]; then
    printf 'OVERALL PASS | selected configuration, database access, active-branch consumer readiness, and daemon health verified; external invoice submission was not tested\n'
    exit 0
fi

printf 'OVERALL NOT VERIFIED | one or more required checks failed or remain unknown\n'
exit 1
