#!/usr/bin/env bash
# =============================================================================
# set-tenant-plan.sh — Set a tenant's subscription plan
# =============================================================================
# Usage:
#   ./scripts/set-tenant-plan.sh TENANT_NAME --plan PLAN [--notes TEXT]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
TENANT_NAME=""
PLAN=""
NOTES=""

usage() {
    echo "Usage: $0 TENANT_NAME --plan PLAN [--notes TEXT] [--config PATH]"
    echo "PLAN must be one of: solo, growth, business, enterprise"
}

error() {
    printf '[✗] %s\n' "$*" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)
            [ $# -ge 2 ] || { error "--plan requires a value"; usage; exit 1; }
            PLAN="$2"
            shift 2
            ;;
        --notes)
            [ $# -ge 2 ] || { error "--notes requires a value"; usage; exit 1; }
            NOTES="$2"
            shift 2
            ;;
        --config)
            [ $# -ge 2 ] || { error "--config requires a path"; usage; exit 1; }
            CONFIG_FILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [ -n "$TENANT_NAME" ]; then
                error "Unexpected argument: $1"
                usage
                exit 1
            fi
            TENANT_NAME="$1"
            shift
            ;;
    esac
done

if [[ ! "$TENANT_NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    error "Invalid tenant name (must be 1-63 lowercase alphanumeric characters or hyphens)."
    usage
    exit 1
fi

case "$PLAN" in
    solo|growth|business|enterprise) ;;
    *)
        error "Invalid plan; choose solo, growth, business, or enterprise."
        usage
        exit 1
        ;;
esac

if [ "${#NOTES}" -gt 500 ]; then
    error "Notes must be 500 characters or fewer."
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    error "Config file not found: $CONFIG_FILE"
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"

sql_escape() {
    printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g"
}

tenant_sql="$(sql_escape "$TENANT_NAME")"
plan_sql="$(sql_escape "$PLAN")"
notes_sql="$(sql_escape "$NOTES")"

run_mysql "$MYSQL_MASTER_DB" <<SQLEOF
INSERT INTO tenant_plan (tenant_name, plan, notes)
VALUES ('${tenant_sql}', '${plan_sql}', '${notes_sql}')
ON DUPLICATE KEY UPDATE plan=VALUES(plan), notes=VALUES(notes);
SQLEOF

printf '[+] Tenant %s plan updated to %s\n' "$TENANT_NAME" "$PLAN"
