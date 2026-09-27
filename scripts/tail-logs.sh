#!/usr/bin/env bash
# =============================================================================
# tail-logs.sh — Aggregate logs from all tenants (or filter by tenant/type)
# =============================================================================
# Usage:
#   ./scripts/tail-logs.sh                          # all tenants, both apps
#   ./scripts/tail-logs.sh --tenant acme            # one tenant only
#   ./scripts/tail-logs.sh --type backend           # all backends
#   ./scripts/tail-logs.sh --grep "error"           # filter output
#   ./scripts/tail-logs.sh --since 1h               # last hour, no follow
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

CONFIG_FILE="$PROJECT_DIR/config.env"
TENANT=""
APP_TYPE=""
GREP_PATTERN=""
SINCE=""
FOLLOW=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant) TENANT="$2"; shift 2 ;;
        --type)   APP_TYPE="$2"; shift 2 ;;
        --grep)   GREP_PATTERN="$2"; shift 2 ;;
        --since)  SINCE="$2"; FOLLOW=false; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
[ -n "$TENANT" ] && TENANT="$(tenant_full_name "$TENANT")"

# Get matching apps
if [ -n "$TENANT" ] && [ -n "$APP_TYPE" ]; then
    APPS="${TENANT}-${APP_TYPE}"
elif [ -n "$TENANT" ]; then
    APPS=$(dokku apps:list 2>/dev/null | tail -n +2 | grep "^${TENANT}-" || true)
elif [ -n "$APP_TYPE" ]; then
    APPS=$(dokku apps:list 2>/dev/null | tail -n +2 | grep -- "-${APP_TYPE}$" || true)
else
    APPS=$(dokku apps:list 2>/dev/null | tail -n +2 || true)
fi

if [ -n "$(tenant_name_prefix)" ]; then
    APPS=$(while IFS= read -r app; do
        tenant="$(tenant_from_app_name "$app")"
        tenant_in_scope "$tenant" && printf '%s\n' "$app"
    done <<< "$APPS")
fi

if [ -z "$APPS" ]; then
    echo "No matching apps."
    exit 1
fi

# Color tags per app for visual separation
COLORS=(31 32 33 34 35 36 91 92 93 94 95 96)
declare -A APP_COLOR
i=0
for app in $APPS; do
    APP_COLOR[$app]=${COLORS[$((i % ${#COLORS[@]}))]}
    i=$((i + 1))
done

# Build dokku logs args
LOG_ARGS=""
$FOLLOW && LOG_ARGS="--tail"
[ -n "$SINCE" ] && LOG_ARGS="-n 1000"  # dokku doesn't have --since, fall back to lines

# Tail each app in parallel with colored prefix
PIDS=()
trap 'kill ${PIDS[@]} 2>/dev/null; exit 0' INT TERM

for app in $APPS; do
    color="${APP_COLOR[$app]}"
    (
        dokku logs "$app" $LOG_ARGS 2>&1 | \
        while IFS= read -r line; do
            if [ -n "$GREP_PATTERN" ] && ! echo "$line" | grep -qi "$GREP_PATTERN"; then
                continue
            fi
            printf "\033[${color}m[%s]\033[0m %s\n" "$app" "$line"
        done
    ) &
    PIDS+=($!)
done

wait
