#!/usr/bin/env bash
# =============================================================================
# backup-tenant.sh — Backup tenant persistent data and/or database
# =============================================================================
# Usage:
#   ./scripts/backup-tenant.sh <tenant-name>
#   ./scripts/backup-tenant.sh --all
#   ./scripts/backup-tenant.sh --all --config /opt/deployment/config.dev.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

# Parse --config early (before sourcing)
CONFIG_FILE="$PROJECT_DIR/config.env"
ARGS=()
for arg in "$@"; do
    if [ "${_NEXT_IS_CONFIG:-}" = "1" ]; then
        CONFIG_FILE="$arg"
        _NEXT_IS_CONFIG=0
        continue
    fi
    if [ "$arg" = "--config" ]; then
        _NEXT_IS_CONFIG=1
        continue
    fi
    ARGS+=("$arg")
done
set -- "${ARGS[@]+"${ARGS[@]}"}" 

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/tenant-backups}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_ROOT_USER="${MYSQL_ROOT_USER:-root}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

mkdir -p "$BACKUP_DIR"

backup_tenant() {
    local tenant="$1"
    local source="$STORAGE_ROOT/$tenant"
    local dest="$BACKUP_DIR/${tenant}_files_${TIMESTAMP}.tar.gz"

    # Backup files
    if [ -d "$source" ]; then
        log "Backing up files: $tenant → $dest"
        tar czf "$dest" -C "$STORAGE_ROOT" "$tenant"
        echo "  Size: $(du -h "$dest" | cut -f1)"
    else
        warn "No data directory for tenant '$tenant'."
    fi

    # Backup MySQL database from external server
    local tenant_db="tenant_${tenant//-/_}"
    if [ -n "$MYSQL_ROOT_PASSWORD" ] && [ "$MYSQL_ROOT_PASSWORD" != "changeme" ]; then
        # Check if the database exists
        if run_mysql -e "USE \`${tenant_db}\`" 2>/dev/null; then
            local db_dest="$BACKUP_DIR/${tenant}_mysql_${TIMESTAMP}.sql.gz"
            log "Backing up MySQL: $tenant_db → $db_dest"
            run_mysqldump \
                --single-transaction --routines --triggers "$tenant_db" | gzip > "$db_dest"
            echo "  Size: $(du -h "$db_dest" | cut -f1)"
        fi
    fi
}

if [ "${1:-}" = "--all" ]; then
    log "Backing up ALL tenants..."
    ALL_APPS=$(dokku apps:list 2>/dev/null | tail -n +2 || true)
    declare -A SEEN
    while IFS= read -r app; do
        if [[ "$app" == *-backend ]]; then
            tenant="${app%-backend}"
            if [ -z "${SEEN[$tenant]:-}" ]; then
                SEEN["$tenant"]=1
                backup_tenant "$tenant"
            fi
        fi
    done <<< "$ALL_APPS"
elif [ -n "${1:-}" ]; then
    backup_tenant "$1"
else
    echo "Usage: $0 <tenant-name> | --all"
    exit 1
fi

# Clean backups older than 30 days
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +30 -delete 2>/dev/null || true
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +30 -delete 2>/dev/null || true

echo ""
log "Backups stored in: $BACKUP_DIR"
