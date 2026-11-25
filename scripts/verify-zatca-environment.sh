#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup-zatca-daemon.sh"
HEALTH_SCRIPT="${SCRIPT_DIR}/health-zatca-daemon.sh"
CONFIG_FILE="${REPO_DIR}/config.env"
EXPLICIT_CONFIG=false
VERIFICATION_OK=true

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

CONFIGURED_IMAGE_ID=""
RUNNING_IMAGE_ID=""
if CONFIGURED_IMAGE_ID="$(
    docker image inspect --format '{{.Id}}' "$ZATCA_DAEMON_IMAGE" 2>/dev/null
)"; then
    if [ -n "$CONFIGURED_IMAGE_ID" ] &&
        RUNNING_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null)" &&
        [ -n "$RUNNING_IMAGE_ID" ]; then
        if [ "$CONFIGURED_IMAGE_ID" = "$RUNNING_IMAGE_ID" ]; then
            printf 'PASS | daemon.image | configured image matches the running daemon image\n'
        else
            mark_failure "FAIL" "daemon.image" "configured image does not match the running daemon image"
        fi
    else
        mark_failure "NOT VERIFIED" "daemon.image" "running daemon image could not be inspected"
    fi
else
    mark_failure "NOT VERIFIED" "daemon.image" "configured daemon image is unavailable locally"
fi

database_report=""
database_exit_status=125
if [ -n "$CONFIGURED_IMAGE_ID" ] && [ -n "$compose_json" ]; then
    if database_report="$(
        docker compose --env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" \
            --profile zatca-check run --rm --no-deps zatca-check 2>/dev/null
    )"; then
        database_exit_status=0
    else
        database_exit_status=$?
    fi
else
    mark_failure "NOT VERIFIED" "database.report" "one-shot verifier image or Compose evidence is unavailable"
fi

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
    mark_failure "NOT VERIFIED" "database.report" "one-shot daemon report is missing"
fi

health_output=""
health_exit_status=125
if [ ! -f "$HEALTH_SCRIPT" ]; then
    mark_failure "NOT VERIFIED" "daemon.health" "daemon health checker is unavailable"
elif health_output="$(bash "$HEALTH_SCRIPT" --config "$CONFIG_FILE" --json 2>/dev/null)"; then
    health_exit_status=0
else
    health_exit_status=$?
fi

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
                mark_failure "FAIL" "daemon.health" "JetStream backlog exceeds configured thresholds"
                ;;
            disabled:*)
                mark_failure "FAIL" "daemon.health" "daemon health checker reports disabled"
                ;;
            *)
                mark_failure "NOT VERIFIED" "daemon.health" "daemon health evidence is not healthy or exit status is inconsistent"
                ;;
        esac
    else
        mark_failure "NOT VERIFIED" "daemon.health" "health report is malformed, disabled, or incomplete"
    fi
else
    if [ "$health_exit_status" -eq 125 ]; then
        mark_failure "NOT VERIFIED" "daemon.health" "daemon health check could not be started"
    else
        mark_failure "NOT VERIFIED" "daemon.health" "authenticated daemon readiness or JetStream health check failed"
    fi
fi

if [ "$VERIFICATION_OK" = true ]; then
    printf 'OVERALL PASS | selected configuration, database access, active-branch consumer readiness, and daemon health verified; external invoice submission was not tested\n'
    exit 0
fi

printf 'OVERALL NOT VERIFIED | one or more required checks failed or remain unknown\n'
exit 1
