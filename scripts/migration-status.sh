#!/usr/bin/env bash
# =============================================================================
# migration-status.sh — Check migration state for one or every tenant
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
TENANT_FILTER=""
JSON=false
INIT_SCRIPT="${MIGRATION_STATUS_INIT_SCRIPT:-$SCRIPT_DIR/init-tenant-db.sh}"

usage() {
    sed -n '1,24p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant) TENANT_FILTER="$2"; shift 2 ;;
        --json) JSON=true; shift ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
    esac
done

[ -f "$CONFIG_FILE" ] || {
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ -n "$TENANT_FILTER" ]; then
    TENANT_FILTER="$(tenant_full_name "$TENANT_FILTER")" || exit 1
fi

json_array() {
    local values="$1" value first=true
    printf '['
    while IFS= read -r value; do
        [ -n "$value" ] || continue
        $first || printf ','
        printf '"%s"' "$(json_escape "$value")"
        first=false
    done <<< "$values"
    printf ']'
}

backend_image() {
    local app="$1" cid
    cid="$(docker ps -a \
        --filter "label=com.dokku.app-name=${app}" \
        --filter "label=com.dokku.process-type=web" \
        --format '{{.ID}}' | head -1 || true)"
    if [ -z "$cid" ]; then
        cid="$(docker ps -a \
            --filter "label=com.dokku.app-name=${app}" \
            --format '{{.ID}}' | head -1 || true)"
    fi
    [ -n "$cid" ] || return 0
    docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true
}

backend_tenants() {
    local apps tenant
    apps="$(docker exec -i "${DOKKU_CONTAINER:-dokku}" dokku --quiet apps:list 2>/dev/null |
        awk '/^[a-z0-9][a-z0-9-]*-backend$/ { sub(/-backend$/, ""); print }' || true)"
    while IFS= read -r tenant; do
        [ -n "$tenant" ] || continue
        if tenant_in_scope "$tenant"; then
            printf '%s\n' "$tenant"
        fi
    done <<< "$apps"
}

check_tenant() {
    local tenant="$1" app image init_output rc status pending failed error checked_at
    app="${tenant}-backend"
    image="$(backend_image "$app")"
    checked_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    if [ -z "$image" ]; then
        if $JSON; then
            printf '{"tenant":"%s","image":"","schema_status":"unknown","pending_migrations":[],"failed_migrations":[],"error":"backend image is unavailable","checked_at":"%s"}\n' \
                "$(json_escape "$tenant")" "$checked_at"
        else
            printf 'tenant=%s\nimage=\nschema_status=unknown\nerror=backend image is unavailable\n\n' "$tenant"
        fi
        overall_rc=1
        return 0
    fi

    set +e
    init_output="$(bash "$INIT_SCRIPT" "$tenant" \
        --status \
        --backend-image "$image" \
        --config "$CONFIG_FILE" 2>&1)"
    rc=$?
    set -e

    init_output="$(printf '%s\n' "$init_output" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')"
    status="$(printf '%s\n' "$init_output" | awk -F= '/^schema_status=/{value=$2} END{print value}')"
    status="${status:-unknown}"
    pending="$(printf '%s\n' "$init_output" | sed -n 's/^pending_migration=//p')"
    failed="$(printf '%s\n' "$init_output" | sed -n 's/^failed_migration=\([^ ]*\).*/\1/p')"
    error="$(printf '%s\n' "$init_output" | sed -n 's/^\[x\] //p' | tail -1)"
    if [ "$rc" -ne 0 ] && [ -z "$error" ]; then
        error="migration status command exited with status ${rc}"
    fi

    if $JSON; then
        printf '{"tenant":"%s","image":"%s","schema_status":"%s","pending_migrations":' \
            "$(json_escape "$tenant")" "$(json_escape "$image")" "$(json_escape "$status")"
        json_array "$pending"
        printf ',"failed_migrations":'
        json_array "$failed"
        printf ',"error":"%s","checked_at":"%s"}\n' \
            "$(json_escape "$error")" "$checked_at"
    else
        printf '%s\n\n' "$init_output"
    fi

    [ "$status" = "up_to_date" ] || overall_rc=1
}

overall_rc=0
if [ -n "$TENANT_FILTER" ]; then
    tenants="$TENANT_FILTER"
else
    tenants="$(backend_tenants)"
fi

if [ -n "$tenants" ]; then
    while IFS= read -r tenant; do
        [ -n "$tenant" ] || continue
        check_tenant "$tenant"
    done <<< "$tenants"
fi

exit "$overall_rc"
