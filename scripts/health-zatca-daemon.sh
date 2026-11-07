#!/usr/bin/env bash
# =============================================================================
# health-zatca-daemon.sh — Readiness and bounded JetStream queue signals.
# =============================================================================
# The daemon exposes the authenticated NATS monitor. This check verifies
# JetStream readiness, then reports the ZATCA stream's pending, ack-pending,
# and redelivery counters. ZATCA_MAX_PENDING and ZATCA_MAX_ACK_PENDING are
# deployment thresholds; they are not daemon configuration knobs.
#
# Usage:
#   bash scripts/health-zatca-daemon.sh --config /opt/deployment/config.env
#   bash scripts/health-zatca-daemon.sh --config /opt/deployment/config.env --json
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${CONFIG_FILE:-${REPO_DIR}/config.env}"
JSON_OUTPUT=false
QUIET=false
TIMEOUT_SECONDS="${ZATCA_HEALTH_TIMEOUT_SECONDS:-5}"
MAX_PENDING_OVERRIDE=""
MAX_ACK_PENDING_OVERRIDE=""

error() { echo "[x] $*" >&2; }
fail() { error "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || fail "--config requires a path"
            CONFIG_FILE="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        --timeout)
            [ "$#" -ge 2 ] || fail "--timeout requires seconds"
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --max-pending)
            [ "$#" -ge 2 ] || fail "--max-pending requires a number"
            MAX_PENDING_OVERRIDE="$2"
            shift 2
            ;;
        --max-ack-pending)
            [ "$#" -ge 2 ] || fail "--max-ack-pending requires a number"
            MAX_ACK_PENDING_OVERRIDE="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '1,22p' "$0"
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[ -f "$CONFIG_FILE" ] || fail "Config file not found: $CONFIG_FILE"

# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

case "${ZATCA_DAEMON_ENABLED:-0}" in
    1|true|yes)
        ;;
    *)
        if $JSON_OUTPUT; then
            $QUIET || printf '%s\n' '{"status":"disabled","limits_ok":true}'
        elif ! $QUIET; then
            echo "ZATCA daemon health: disabled"
        fi
        exit 0
        ;;
esac

: "${ZATCA_MONITOR_PASSWORD:?ZATCA_MONITOR_PASSWORD must be set in ${CONFIG_FILE}}"

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
    is_integer "$1" && [ "$1" -gt 0 ]
}

is_integer "$TIMEOUT_SECONDS" || fail "--timeout must be a non-negative integer"
[ "$TIMEOUT_SECONDS" -gt 0 ] || fail "--timeout must be greater than zero"

MAX_PENDING="${MAX_PENDING_OVERRIDE:-${ZATCA_MAX_PENDING:-1000}}"
MAX_ACK_PENDING="${MAX_ACK_PENDING_OVERRIDE:-${ZATCA_MAX_ACK_PENDING:-100}}"
is_positive_integer "$MAX_PENDING" || fail "ZATCA_MAX_PENDING must be a positive integer"
is_integer "$MAX_ACK_PENDING" || fail "ZATCA_MAX_ACK_PENDING must be a non-negative integer"

command -v curl >/dev/null 2>&1 || fail "curl is required for daemon health"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse daemon health"

MONITOR_HOST="${ZATCA_NATS_MONITOR_HOST:-127.0.0.1}"
MONITOR_PORT="${ZATCA_NATS_MONITOR_PORT:-8222}"
MONITOR_BASE="http://${MONITOR_HOST}:${MONITOR_PORT}"

monitor_get() {
    local path="$1"
    curl --config - <<CURL_CONFIG
url = "${MONITOR_BASE}${path}"
user = "health:${ZATCA_MONITOR_PASSWORD}"
fail
silent
show-error
connect-timeout = ${TIMEOUT_SECONDS}
max-time = ${TIMEOUT_SECONDS}
output = -
CURL_CONFIG
}

monitor_get "/healthz" >/dev/null \
    || fail "daemon readiness check failed at ${MONITOR_BASE}/healthz"

jsz_payload="$(monitor_get "/jsz?accounts=true&streams=true&consumers=true" 2>/dev/null)" \
    || fail "daemon JetStream monitor check failed at ${MONITOR_BASE}/jsz"

summary="$(
    MAX_PENDING="$MAX_PENDING" MAX_ACK_PENDING="$MAX_ACK_PENDING" \
        printf '%s' "$jsz_payload" |
        MAX_PENDING="$MAX_PENDING" MAX_ACK_PENDING="$MAX_ACK_PENDING" \
        python3 -c '
import json
import os
import sys

try:
    payload = json.load(sys.stdin)
except Exception as exc:
    print("invalid JetStream health JSON: %s" % exc, file=sys.stderr)
    raise SystemExit(2)

root = payload.get("data", payload)
accounts = root.get("account_details", [])
streams = []
if isinstance(accounts, list):
    for account in accounts:
        if isinstance(account, dict):
            streams.extend(account.get("stream_detail", []) or [])
streams.extend(root.get("stream_detail", []) or [])

target = next((stream for stream in streams if stream.get("name") == "ZATCA"), None)
if target is None:
    print("missing ZATCA stream", file=sys.stderr)
    raise SystemExit(3)

state = target.get("state") or {}
consumers = target.get("consumer_detail") or []
pending = sum(int(c.get("num_pending") or 0) for c in consumers)
ack_pending = sum(int(c.get("num_ack_pending") or 0) for c in consumers)
redelivered = sum(int(c.get("num_redelivered") or 0) for c in consumers)
max_pending = int(os.environ["MAX_PENDING"])
max_ack_pending = int(os.environ["MAX_ACK_PENDING"])
limits_ok = pending <= max_pending and ack_pending <= max_ack_pending

result = {
    "status": "healthy" if limits_ok else "backlog_exceeded",
    "stream": "ZATCA",
    "stream_messages": int(state.get("messages") or 0),
    "consumer_count": len(consumers),
    "pending": pending,
    "ack_pending": ack_pending,
    "redelivered": redelivered,
    "reconciliation_signal": "redeliveries_observed" if redelivered else "none",
    "max_pending": max_pending,
    "max_ack_pending": max_ack_pending,
    "limits_ok": limits_ok,
}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
'
)" || fail "daemon JetStream health payload is invalid or missing the ZATCA stream"

limits_ok="$(
    printf '%s' "$summary" |
        python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["limits_ok"] else "false")'
)"

if $JSON_OUTPUT; then
    $QUIET || printf '%s\n' "$summary"
elif ! $QUIET; then
    printf '%s\n' "$summary" | python3 -c '
import json
import sys

health = json.load(sys.stdin)
print("ZATCA daemon health: %s" % health["status"])
print("  stream:              %s" % health["stream"])
print("  stream messages:     %s" % health["stream_messages"])
print("  consumers:           %s" % health["consumer_count"])
print("  pending:             %s / %s" % (health["pending"], health["max_pending"]))
print("  ack pending:         %s / %s" % (health["ack_pending"], health["max_ack_pending"]))
print("  redelivered:         %s" % health["redelivered"])
print("  reconciliation:      %s" % health["reconciliation_signal"])
'
fi

if [ "$limits_ok" != "true" ]; then
    error "ZATCA queue backlog exceeds configured deployment threshold"
    exit 1
fi
