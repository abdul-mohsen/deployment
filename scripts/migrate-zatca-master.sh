#!/usr/bin/env bash
# =============================================================================
# migrate-zatca-master.sh — apply the ZATCA-owned zatca_master Goose artifact
# =============================================================================
# This script orchestrates the migration only. The migration SQL remains owned
# by zatca_integration and is supplied as an external artifact directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Find the config path before loading the shared helpers. The helpers inspect
# MYSQL_CLIENT_MODE while they are sourced.
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
for ((i = 1; i <= $#; i++)); do
    if [ "${!i:-}" = "--config" ]; then
        j=$((i + 1))
        [ "$j" -le "$#" ] || {
            echo "migrate-zatca-master.sh: --config requires a path" >&2
            exit 1
        }
        CONFIG_FILE="${!j}"
        break
    fi
done

[ -f "$CONFIG_FILE" ] || {
    echo "migrate-zatca-master.sh: config file not found: $CONFIG_FILE" >&2
    exit 1
}
# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
deployment_init_logging

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { deployment_log INFO "$*"; echo -e "${GREEN}[+]${NC} $*"; }
warn()  { deployment_log WARN "$*"; echo -e "${YELLOW}[!]${NC} $*"; }
error() { deployment_log ERROR "$*"; echo -e "${RED}[x]${NC} $*" >&2; }
info()  { deployment_log INFO "$*"; echo -e "${BLUE}[i]${NC} $*"; }

MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"
ARTIFACT_DIR="${ZATCA_MASTER_MIGRATION_ARTIFACT:-${ZATCA_MASTER_MIGRATIONS_DIR:-}}"
GOOSE_BIN="${ZATCA_MASTER_GOOSE_BIN:-goose}"
GOOSE_DSN="${ZATCA_MASTER_GOOSE_DSN:-${MYSQL_MASTER_DSN:-}}"
LEGACY_POLICY="${ZATCA_MASTER_LEGACY_POLICY:-refuse}"
LOCK_FILE="${ZATCA_MASTER_MIGRATION_LOCK_FILE:-${DEPLOY_STATE_DIR:-${PROJECT_DIR}/state}/zatca-master-migration.lock}"
BACKUP_DIR="${ZATCA_MASTER_BACKUP_DIR:-${BACKUP_DIR:-/opt/tenant-backups}}"
DRY_RUN=false
MASTER_BACKUP_PATH=""

usage() {
    cat <<'USAGE'
Usage: migrate-zatca-master.sh [options]

Apply the ZATCA-owned Goose artifact to MYSQL_MASTER_DB before tenant creation.
The deployment repository does not contain or generate the ZATCA schema.

Options:
  --config <path>                 Config file (default: ../config.env)
  --artifact <dir>                ZATCA migrations/zatca_master directory
  --migrations-dir <dir>          Alias for --artifact
  --goose-bin <path>              Goose executable (default: goose)
  --dsn <dsn>                     Goose MySQL DSN (otherwise built from config)
  --master-db <name>              Master database (default: zatca_master)
  --legacy-policy refuse|baseline Refuse legacy DBs, or explicitly baseline v1
  --dry-run                       Validate configuration without changing MySQL
USAGE
}

for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --config|--artifact|--migrations-dir|--goose-bin|--dsn|--master-db|--legacy-policy)
            i=$((i + 1))
            ;;
        --dry-run|--help|-h) ;;
        *) ;;
    esac
done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)          CONFIG_FILE="$2"; shift 2 ;;
        --artifact|--migrations-dir)
                            ARTIFACT_DIR="$2"; shift 2 ;;
        --goose-bin)       GOOSE_BIN="$2"; shift 2 ;;
        --dsn)             GOOSE_DSN="$2"; shift 2 ;;
        --master-db)       MASTER_DB="$2"; shift 2 ;;
        --legacy-policy)   LEGACY_POLICY="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --help|-h)         usage; exit 0 ;;
        *)                  error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

validate_database_identifier "$MASTER_DB" || exit 1
case "$LEGACY_POLICY" in
    refuse|baseline) ;;
    *) error "legacy policy must be 'refuse' or 'baseline'"; exit 1 ;;
esac

if [ -z "$ARTIFACT_DIR" ]; then
    error "ZATCA_MASTER_MIGRATION_ARTIFACT is required; provide the ZATCA-owned migrations/zatca_master directory."
    exit 1
fi
if [ ! -d "$ARTIFACT_DIR" ]; then
    error "ZATCA migration artifact directory does not exist: $ARTIFACT_DIR"
    exit 1
fi
for migration in 00001_baseline.sql 00002_tenant_key.sql; do
    if [ ! -r "$ARTIFACT_DIR/$migration" ]; then
        error "ZATCA migration artifact is incomplete; missing $migration."
        exit 1
    fi
done
if ! command -v "$GOOSE_BIN" >/dev/null 2>&1 && [ ! -x "$GOOSE_BIN" ]; then
    error "Goose executable is unavailable: $GOOSE_BIN"
    exit 1
fi

mysql_dsn_escape() {
    local value="$1"
    value="${value//%/%25}"
    value="${value//\//%2F}"
    value="${value//@/%40}"
    value="${value//:/%3A}"
    value="${value//\?/%3F}"
    value="${value//#/%23}"
    value="${value//;/%3B}"
    printf '%s' "$value"
}

goose_dsn() {
    if [ -n "$GOOSE_DSN" ]; then
        printf '%s' "$GOOSE_DSN"
        return 0
    fi
    local host user password port
    host="${ZATCA_MASTER_GOOSE_HOST:-${MYSQL_HOST:-127.0.0.1}}"
    [ "$host" = "host.docker.internal" ] && host="127.0.0.1"
    port="${MYSQL_PORT:-3306}"
    user="$(mysql_admin_user)"
    password="$(mysql_admin_password)"
    [ -n "$user" ] && [ -n "$password" ] || {
        error "A Goose DSN or configured MySQL admin credentials are required."
        return 1
    }
    printf '%s:%s@tcp(%s:%s)/%s' \
        "$(mysql_dsn_escape "$user")" \
        "$(mysql_dsn_escape "$password")" \
        "$host" "$port" "$MASTER_DB"
}

master_database_exists() {
    local count
    count="$(run_mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${MASTER_DB}';")" || return 2
    count="$(printf '%s\n' "$count" | awk 'NF { print $1; exit }')"
    case "$count" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

master_table_count() {
    local table_name="$1" count
    count="$(run_mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MASTER_DB}' AND table_name='${table_name}';")" || return 1
    printf '%s\n' "$count" | awk 'NF { print $1; exit }'
}

master_base_table_count() {
    run_mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MASTER_DB}' AND table_type='BASE TABLE';" |
        awk 'NF { print $1; exit }'
}

master_goose_row_count() {
    run_mysql -N -B "$MASTER_DB" -e \
        "SELECT COUNT(*) FROM goose_db_version;" | awk 'NF { print $1; exit }'
}

create_master_database() {
    log "Creating fresh master database: $MASTER_DB"
    run_mysql -e \
        "CREATE DATABASE IF NOT EXISTS \`${MASTER_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

backup_master_database() {
    local timestamp backup_path manifest
    mkdir -p "$BACKUP_DIR"
    timestamp="$(date -u '+%Y%m%d-%H%M%S')"
    backup_path="$BACKUP_DIR/${MASTER_DB}_pre-goose_${timestamp}.sql.gz"
    manifest="${backup_path%.sql.gz}.meta.json"

    log "Creating verified pre-Goose backup for $MASTER_DB"
    if ! run_mysqldump --single-transaction --routines --triggers --no-tablespaces "$MASTER_DB" |
        gzip > "$backup_path"; then
        rm -f "$backup_path"
        error "Pre-Goose backup failed for $MASTER_DB; refusing migration."
        return 1
    fi
    if ! verify_gzip_artifact "$backup_path"; then
        rm -f "$backup_path"
        error "Pre-Goose backup failed verification for $MASTER_DB; refusing migration."
        return 1
    fi
    cat > "$manifest" <<EOF
{
  "database": "$(json_escape "$MASTER_DB")",
  "artifact": "$(json_escape "$backup_path")",
  "purpose": "zatca_master_pre_goose",
  "verified": true,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    MASTER_BACKUP_PATH="$backup_path"
}

goose_run() {
    local action="$1" dsn
    dsn="$(goose_dsn)" || return 1
    "$GOOSE_BIN" -dir "$ARTIFACT_DIR" mysql "$dsn" "$action"
}

baseline_legacy_registry() {
    log "Recording the explicit ZATCA baseline for the legacy master registry"
    goose_run version || {
        error "Goose could not initialize its ledger for the legacy master registry."
        return 1
    }
    run_mysql "$MASTER_DB" -e \
        "INSERT INTO goose_db_version (version_id, is_applied) SELECT 1, 1 FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM goose_db_version WHERE version_id=1);"
}

verify_registry() {
    local table_count column_count default_trigger immutable_trigger unique_key
    table_count="$(master_table_count tenant)" || return 1
    column_count="$(run_mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND column_name='tenant_key';")" || return 1
    default_trigger="$(run_mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='${MASTER_DB}' AND event_object_table='tenant' AND trigger_name='tenant_key_default' AND action_timing='BEFORE' AND event_manipulation='INSERT';")" || return 1
    immutable_trigger="$(run_mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='${MASTER_DB}' AND event_object_table='tenant' AND trigger_name='tenant_key_immutable' AND action_timing='BEFORE' AND event_manipulation='UPDATE';")" || return 1
    unique_key="$(run_mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND index_name='uq_tenant_key';")" || return 1

    table_count="$(printf '%s\n' "$table_count" | awk 'NF { print $1; exit }')"
    column_count="$(printf '%s\n' "$column_count" | awk 'NF { print $1; exit }')"
    default_trigger="$(printf '%s\n' "$default_trigger" | awk 'NF { print $1; exit }')"
    immutable_trigger="$(printf '%s\n' "$immutable_trigger" | awk 'NF { print $1; exit }')"
    unique_key="$(printf '%s\n' "$unique_key" | awk 'NF { print $1; exit }')"

    if [ "$table_count" != "1" ] ||
        [ "$column_count" != "1" ] ||
        [ "$default_trigger" != "1" ] ||
        [ "$immutable_trigger" != "1" ] ||
        [ "$unique_key" != "1" ]; then
        error "ZATCA master migration verification failed (tenant_key column/triggers/index are incomplete)."
        return 1
    fi
    log "Verified ZATCA master registry: tenant_key, unique index, and both triggers are present."
}

run_migration() {
    local db_state backup_path=""
    if $DRY_RUN; then
        info "Dry run: would lock, back up, and run Goose from the ZATCA artifact against $MASTER_DB."
        return 0
    fi

    if ! command -v flock >/dev/null 2>&1; then
        error "flock is required to serialize ZATCA master migrations."
        return 1
    fi
    mkdir -p "$(dirname "$LOCK_FILE")"
    local lock_fd
    exec {lock_fd}>"$LOCK_FILE"
    if ! flock -n "$lock_fd"; then
        error "Another ZATCA master migration is already running; refusing concurrent execution."
        return 1
    fi

    if master_database_exists; then
        db_state="existing"
    else
        case "$?" in
            1) db_state="fresh" ;;
            *) error "Could not determine whether master database '$MASTER_DB' exists."; return 1 ;;
        esac
    fi

    local tenant_tables goose_tables base_tables goose_rows
    if [ "$db_state" = "fresh" ]; then
        create_master_database
        backup_master_database || return 1
        backup_path="$MASTER_BACKUP_PATH"
        info "Fresh master database backed up before Goose: $backup_path"
    else
        tenant_tables="$(master_table_count tenant)" || {
            error "Could not inspect ${MASTER_DB}.tenant; refusing migration."
            return 1
        }
        goose_tables="$(master_table_count goose_db_version)" || {
            error "Could not inspect ${MASTER_DB}.goose_db_version; refusing migration."
            return 1
        }
        base_tables="$(master_base_table_count)" || {
            error "Could not inspect master database tables; refusing migration."
            return 1
        }
        goose_rows="0"
        if [ "$goose_tables" = "1" ]; then
            goose_rows="$(master_goose_row_count)" || {
                error "Could not inspect the Goose ledger; refusing migration."
                return 1
            }
        fi

        if [ "$tenant_tables" = "0" ] && [ "$goose_tables" = "0" ] && [ "$base_tables" = "0" ]; then
            db_state="empty"
        elif [ "$goose_tables" = "1" ] && [ "$goose_rows" != "0" ]; then
            db_state="goose"
        elif [ "$tenant_tables" = "1" ] && [ "$goose_tables" = "0" ]; then
            db_state="legacy"
        else
            error "Master database '$MASTER_DB' has an unknown pre-Goose shape; refusing to guess ownership."
            return 1
        fi
        backup_master_database || return 1
        backup_path="$MASTER_BACKUP_PATH"
        info "Existing master database backed up before Goose: $backup_path"
    fi

    case "$db_state" in
        fresh|empty|goose)
            log "Running ZATCA-owned Goose migrations for $MASTER_DB"
            goose_run up || {
                error "ZATCA Goose migration failed; master registry was not verified."
                return 1
            }
            ;;
        legacy)
            if [ "$LEGACY_POLICY" != "baseline" ]; then
                error "Pre-Goose legacy registry detected; refusing silent adoption."
                error "Review the verified backup and rerun with --legacy-policy baseline if adoption is authorized."
                return 1
            fi
            baseline_legacy_registry || return 1
            log "Running ZATCA-owned Goose migrations after the explicit legacy baseline"
            goose_run up || {
                error "ZATCA Goose migration failed after legacy baseline; restore the verified backup before retry."
                return 1
            }
            ;;
        *) error "Internal error: unsupported master database state '$db_state'."; return 1 ;;
    esac

    verify_registry
}

run_migration
