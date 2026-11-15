#!/usr/bin/env bash
# =============================================================================
# migrate-zatca-master.sh — prepare the ZATCA master tenant registry
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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
LOCK_FILE="${ZATCA_MASTER_MIGRATION_LOCK_FILE:-${DEPLOY_STATE_DIR:-${PROJECT_DIR}/state}/zatca-master-migration.lock}"
BACKUP_DIR="${ZATCA_MASTER_BACKUP_DIR:-${BACKUP_DIR:-/opt/tenant-backups}}"
DRY_RUN=false
MASTER_BACKUP_PATH=""

usage() {
    cat <<'USAGE'
Usage: migrate-zatca-master.sh [options]

Prepare and verify the master tenant registry using the configured MySQL client.

Options:
  --config <path>                 Config file (default: ../config.env)
  --master-db <name>              Master database (default: zatca_master)
  --dry-run                       Validate configuration without changing MySQL
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || { error "--config requires a path"; exit 1; }
            CONFIG_FILE="$2"
            shift 2
            ;;
        --master-db)
            [ "$#" -ge 2 ] || { error "--master-db requires a name"; exit 1; }
            MASTER_DB="$2"
            shift 2
            ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

validate_database_identifier "$MASTER_DB" || exit 1

mysql_output() {
    run_mysql -N -B -e "$1"
}

mysql_scalar() {
    run_mysql_scalar "$1"
}

master_database_exists() {
    local count
    count="$(mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${MASTER_DB}';")" ||
        return 2
    case "$count" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

master_table_count() {
    local table_name="$1"
    mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MASTER_DB}' AND table_name='${table_name}';"
}

master_base_table_count() {
    local table_name="$1"
    mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MASTER_DB}' AND table_name='${table_name}' AND table_type='BASE TABLE';"
}

create_master_database() {
    log "Creating fresh master database: $MASTER_DB"
    if ! run_mysql -e \
        "CREATE DATABASE IF NOT EXISTS \`${MASTER_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
        error "Could not create master database '$MASTER_DB'."
        return 1
    fi
}

backup_master_database() {
    local timestamp backup_path manifest
    if ! mkdir -p "$BACKUP_DIR"; then
        error "Could not create master backup directory: $BACKUP_DIR"
        return 1
    fi
    timestamp="$(date -u '+%Y%m%d-%H%M%S')"
    backup_path="$BACKUP_DIR/${MASTER_DB}_pre-script-migration_${timestamp}.sql.gz"
    manifest="${backup_path%.sql.gz}.meta.json"

    log "Creating verified pre-migration backup for $MASTER_DB"
    if ! run_mysqldump --single-transaction --routines --triggers --no-tablespaces "$MASTER_DB" |
        gzip > "$backup_path"; then
        rm -f "$backup_path"
        error "Pre-migration backup failed for $MASTER_DB; refusing schema changes."
        return 1
    fi
    if ! verify_gzip_artifact "$backup_path"; then
        rm -f "$backup_path"
        error "Pre-migration backup failed verification for $MASTER_DB; refusing schema changes."
        return 1
    fi
    cat > "$manifest" <<EOF
{
  "database": "$(json_escape "$MASTER_DB")",
  "artifact": "$(json_escape "$backup_path")",
  "purpose": "zatca_master_pre_script_migration",
  "verified": true,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    MASTER_BACKUP_PATH="$backup_path"
}

preflight_mysql_connection() {
    local query output
    query="SELECT 1 AS ok, CURRENT_USER() AS authenticated_user, USER() AS connection_user, DATABASE() AS database_name;"
    log "Preflight: checking deployment MySQL connection"
    if ! output="$(run_mysql -N -B -e "$query")"; then
        error "Deployment MySQL preflight failed before migration; no backup or schema change was attempted."
        return 1
    fi
    info "Deployment MySQL preflight passed: $(printf '%s' "$output" | tr '\t' ' ' | tr '\n' ' ' | cut -c1-512)"
}

ensure_baseline_table() {
    local table_count base_table_count column_count db_name_index_rows db_name_index_valid
    table_count="$(master_table_count tenant)" || {
        error "Could not inspect ${MASTER_DB}.tenant; refusing schema changes."
        return 1
    }
    base_table_count="$(master_base_table_count tenant)" || {
        error "Could not inspect the type of ${MASTER_DB}.tenant; refusing schema changes."
        return 1
    }

    if [ "$table_count" = "0" ]; then
        log "Creating the master tenant registry table"
        if ! run_mysql "$MASTER_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS tenant (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(100)  NOT NULL,
    db_name     VARCHAR(100)  NOT NULL UNIQUE,
    zatca_env   VARCHAR(20)   NOT NULL DEFAULT 'production',
    alert_email VARCHAR(255)  NOT NULL DEFAULT '',
    enabled     TINYINT(1)    NOT NULL DEFAULT 1,
    created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_enabled (enabled)
) ENGINE=InnoDB;
SQL
        then
            error "Could not create ${MASTER_DB}.tenant."
            return 1
        fi
    elif [ "$table_count" != "1" ] || [ "$base_table_count" != "1" ]; then
        error "${MASTER_DB}.tenant is not a compatible base table; refusing schema changes."
        return 1
    fi

    column_count="$(mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND column_name IN ('id','name','db_name','zatca_env','alert_email','enabled','created_at');")" || {
        error "Could not inspect ${MASTER_DB}.tenant columns."
        return 1
    }
    if [ "$column_count" != "7" ]; then
        error "${MASTER_DB}.tenant is missing required baseline columns; refusing schema changes."
        return 1
    fi

    db_name_index_rows="$(mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND index_name='db_name';")" || {
        error "Could not inspect the tenant db_name index."
        return 1
    }
    db_name_index_valid="$(mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND index_name='db_name' AND non_unique=0 AND seq_in_index=1 AND column_name='db_name';")" || {
        error "Could not verify the tenant db_name index."
        return 1
    }
    if [ "$db_name_index_rows" != "1" ] || [ "$db_name_index_valid" != "1" ]; then
        error "${MASTER_DB}.tenant.db_name is missing its expected unique index; refusing schema changes."
        return 1
    fi
}

tenant_key_column_count() {
    mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND column_name='tenant_key';"
}

tenant_key_column_compatible_count() {
    mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND column_name='tenant_key' AND data_type='varchar' AND character_maximum_length=64 AND character_set_name='utf8mb4' AND collation_name='utf8mb4_0900_bin' AND is_nullable IN ('YES','NO') AND (column_default IS NULL OR column_default='');"
}

tenant_key_column_state() {
    mysql_output \
        "SELECT CONCAT(is_nullable, CHAR(9), IF(column_default IS NULL, '<NULL>', column_default)) FROM information_schema.columns WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND column_name='tenant_key';"
}

trigger_definition() {
    registry_tenant_key_trigger_definition "$MASTER_DB" "$1"
}

trigger_is_compatible() {
    registry_tenant_key_trigger_is_compatible "$@"
}

create_tenant_key_trigger() {
    local name="$1"
    case "$name" in
        tenant_key_default)
            if ! run_mysql "$MASTER_DB" <<'SQL'
DELIMITER //
CREATE TRIGGER tenant_key_default BEFORE INSERT ON tenant FOR EACH ROW
BEGIN
    IF NEW.tenant_key = '' THEN
        SET NEW.tenant_key = NEW.db_name;
    END IF;
END//
DELIMITER ;
SQL
            then
                error "Could not create tenant_key_default."
                return 1
            fi
            ;;
        tenant_key_immutable)
            if ! run_mysql "$MASTER_DB" <<'SQL'
DELIMITER //
CREATE TRIGGER tenant_key_immutable BEFORE UPDATE ON tenant FOR EACH ROW
BEGIN
    IF NEW.tenant_key <> OLD.tenant_key THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'tenant_key is immutable';
    END IF;
END//
DELIMITER ;
SQL
            then
                error "Could not create tenant_key_immutable."
                return 1
            fi
            ;;
        *) error "Unknown tenant identity trigger: $name"; return 1 ;;
    esac
}

ensure_tenant_key_trigger() {
    local name="$1" definition
    if ! definition="$(trigger_definition "$name")"; then
        error "Could not inspect trigger '$name'; refusing schema changes."
        return 1
    fi
    if [ -n "$definition" ]; then
        if ! trigger_is_compatible "$name" "$definition"; then
            error "Existing trigger '$name' conflicts with the tenant identity contract."
            return 1
        fi
        return 0
    fi
    create_tenant_key_trigger "$name"
}

tenant_key_duplicate_count() {
    mysql_scalar \
        "SELECT COUNT(*) FROM (SELECT candidate_key FROM (SELECT CASE WHEN tenant_key IS NULL OR tenant_key='' THEN db_name ELSE tenant_key END AS candidate_key FROM tenant) AS prepared_keys GROUP BY candidate_key HAVING COUNT(*) > 1) AS duplicate_keys;"
}

ensure_tenant_key_schema() {
    local column_count compatible_count column_state nullable default_value
    local too_long_count missing_count duplicate_count immutable_definition
    local index_rows index_valid

    column_count="$(tenant_key_column_count)" || {
        error "Could not inspect ${MASTER_DB}.tenant.tenant_key."
        return 1
    }
    case "$column_count" in
        0)
            log "Adding tenant_key to ${MASTER_DB}.tenant"
            if ! run_mysql "$MASTER_DB" -e \
                "ALTER TABLE tenant ADD COLUMN tenant_key VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin NULL AFTER db_name;"; then
                error "Could not add ${MASTER_DB}.tenant.tenant_key."
                return 1
            fi
            ;;
        1) ;;
        *) error "Found an invalid number of tenant_key columns; refusing schema changes."; return 1 ;;
    esac

    compatible_count="$(tenant_key_column_compatible_count)" || {
        error "Could not verify the tenant_key column definition."
        return 1
    }
    if [ "$compatible_count" != "1" ]; then
        error "${MASTER_DB}.tenant.tenant_key has an incompatible type, length, charset, or collation."
        return 1
    fi

    ensure_tenant_key_trigger tenant_key_default || return 1
    if ! immutable_definition="$(trigger_definition tenant_key_immutable)"; then
        error "Could not inspect trigger tenant_key_immutable."
        return 1
    fi
    if [ -n "$immutable_definition" ] &&
        ! trigger_is_compatible tenant_key_immutable "$immutable_definition"; then
        error "Existing trigger 'tenant_key_immutable' conflicts with the tenant identity contract."
        return 1
    fi

    too_long_count="$(mysql_scalar \
        "SELECT COUNT(*) FROM tenant WHERE (tenant_key IS NULL OR tenant_key='') AND CHAR_LENGTH(db_name)>64;")" || {
        error "Could not check the length of tenant routing names."
        return 1
    }
    if [ "$too_long_count" != "0" ]; then
        error "A tenant db_name is longer than 64 characters and cannot become tenant_key."
        return 1
    fi
    duplicate_count="$(tenant_key_duplicate_count)" || {
        error "Could not check tenant_key uniqueness before backfill."
        return 1
    }
    if [ "$duplicate_count" != "0" ]; then
        error "Existing or backfilled tenant_key values would not be unique; refusing schema changes."
        return 1
    fi

    missing_count="$(mysql_scalar \
        "SELECT COUNT(*) FROM tenant WHERE tenant_key IS NULL OR tenant_key='';")" || {
        error "Could not check for missing tenant_key values."
        return 1
    }
    if [ "$missing_count" != "0" ] && [ -n "$immutable_definition" ]; then
        error "Cannot safely backfill missing tenant_key values while tenant_key_immutable exists; resolve the partial schema before retrying."
        return 1
    fi
    if [ "$missing_count" != "0" ]; then
        log "Filling missing tenant_key values from db_name"
        if ! run_mysql "$MASTER_DB" -e \
            "UPDATE tenant SET tenant_key=db_name WHERE tenant_key IS NULL OR tenant_key='';"; then
            error "Could not backfill missing tenant_key values from db_name."
            return 1
        fi
    fi

    missing_count="$(mysql_scalar \
        "SELECT COUNT(*) FROM tenant WHERE tenant_key IS NULL OR tenant_key='';")" || {
        error "Could not verify the tenant_key backfill."
        return 1
    }
    if [ "$missing_count" != "0" ]; then
        error "Some tenant_key values remain empty after backfill."
        return 1
    fi
    duplicate_count="$(tenant_key_duplicate_count)" || {
        error "Could not verify tenant_key uniqueness."
        return 1
    }
    if [ "$duplicate_count" != "0" ]; then
        error "Tenant_key values are not unique after backfill."
        return 1
    fi

    if ! column_state="$(tenant_key_column_state)"; then
        error "Could not inspect tenant_key nullability and default."
        return 1
    fi
    IFS=$'\t' read -r nullable default_value <<< "$column_state"
    if [ "$nullable" != "NO" ] || [ "$default_value" != "" ]; then
        log "Enforcing tenant_key NOT NULL with an empty insert default"
        if ! run_mysql "$MASTER_DB" -e \
            "ALTER TABLE tenant MODIFY COLUMN tenant_key VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin NOT NULL DEFAULT '';"; then
            error "Could not enforce the tenant_key column constraints."
            return 1
        fi
    fi

    index_rows="$(mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND index_name='uq_tenant_key';")" || {
        error "Could not inspect the uq_tenant_key index."
        return 1
    }
    index_valid="$(mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND index_name='uq_tenant_key' AND non_unique=0 AND seq_in_index=1 AND column_name='tenant_key';")" || {
        error "Could not verify the uq_tenant_key index."
        return 1
    }
    if [ "$index_rows" = "0" ]; then
        log "Adding the unique tenant_key index"
        if ! run_mysql "$MASTER_DB" -e \
            "ALTER TABLE tenant ADD UNIQUE KEY uq_tenant_key (tenant_key);"; then
            error "Could not create the unique tenant_key index."
            return 1
        fi
    elif [ "$index_rows" != "1" ] || [ "$index_valid" != "1" ]; then
        error "Existing index 'uq_tenant_key' conflicts with the tenant identity contract."
        return 1
    fi

    ensure_tenant_key_trigger tenant_key_immutable || return 1
}

verify_registry() {
    local table_count column_count compatible_count column_state nullable default_value
    local index_rows index_valid missing_count duplicate_count definition

    table_count="$(master_base_table_count tenant)" || {
        error "Could not verify the master tenant registry table."
        return 1
    }
    if [ "$table_count" != "1" ]; then
        error "ZATCA master migration verification failed: tenant base table is missing."
        return 1
    fi

    column_count="$(tenant_key_column_count)" || {
        error "Could not verify the tenant_key column."
        return 1
    }
    compatible_count="$(tenant_key_column_compatible_count)" || {
        error "Could not verify the tenant_key column definition."
        return 1
    }
    if [ "$column_count" != "1" ] || [ "$compatible_count" != "1" ]; then
        error "ZATCA master migration verification failed: tenant_key column is missing or incompatible."
        return 1
    fi
    if ! column_state="$(tenant_key_column_state)"; then
        error "Could not verify tenant_key nullability and default."
        return 1
    fi
    IFS=$'\t' read -r nullable default_value <<< "$column_state"
    if [ "$nullable" != "NO" ] || [ "$default_value" != "" ]; then
        error "ZATCA master migration verification failed: tenant_key must be NOT NULL with an empty insert default (is_nullable=${nullable:-unknown}, default=${default_value:-<empty>})."
        return 1
    fi

    index_rows="$(mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND index_name='uq_tenant_key';")" || {
        error "Could not verify the uq_tenant_key index."
        return 1
    }
    index_valid="$(mysql_scalar \
        "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='${MASTER_DB}' AND table_name='tenant' AND index_name='uq_tenant_key' AND non_unique=0 AND seq_in_index=1 AND column_name='tenant_key';")" || {
        error "Could not verify the uq_tenant_key index definition."
        return 1
    }
    if [ "$index_rows" != "1" ] || [ "$index_valid" != "1" ]; then
        error "ZATCA master migration verification failed: uq_tenant_key is missing or incompatible."
        return 1
    fi

    for definition in tenant_key_default tenant_key_immutable; do
        local trigger_sql
        if ! trigger_sql="$(trigger_definition "$definition")"; then
            error "Could not verify trigger '$definition'."
            return 1
        fi
        if ! trigger_is_compatible "$definition" "$trigger_sql"; then
            error "ZATCA master migration verification failed: trigger '$definition' is missing or incompatible."
            return 1
        fi
    done

    missing_count="$(mysql_scalar \
        "SELECT COUNT(*) FROM tenant WHERE tenant_key IS NULL OR tenant_key='';")" || {
        error "Could not verify tenant_key values."
        return 1
    }
    duplicate_count="$(tenant_key_duplicate_count)" || {
        error "Could not verify tenant_key uniqueness."
        return 1
    }
    if [ "$missing_count" != "0" ] || [ "$duplicate_count" != "0" ]; then
        error "ZATCA master migration verification failed: tenant_key values are empty or duplicated."
        return 1
    fi

    log "Verified ZATCA master registry: tenant_key, unique index, and both triggers are compatible."
}

run_migration() {
    local db_state lock_fd

    if $DRY_RUN; then
        info "Dry run: would lock, back up, and ensure the tenant registry schema in $MASTER_DB."
        return 0
    fi

    preflight_mysql_connection || return 1
    if ! command -v flock >/dev/null 2>&1; then
        error "flock is required to serialize ZATCA master registry changes."
        return 1
    fi
    if ! mkdir -p "$(dirname "$LOCK_FILE")"; then
        error "Could not create the master registry lock directory."
        return 1
    fi
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

    if [ "$db_state" = "fresh" ]; then
        create_master_database || return 1
    fi
    backup_master_database || return 1
    info "Master registry backed up before schema changes: $MASTER_BACKUP_PATH"
    ensure_baseline_table || return 1
    ensure_tenant_key_schema || return 1
    verify_registry
}

run_migration
