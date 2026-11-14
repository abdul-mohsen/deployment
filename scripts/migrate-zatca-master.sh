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
ZATCA_MIGRATION_REPOSITORY="https://github.com/abdul-mohsen/zatca_integration"
ZATCA_MIGRATION_REF="7ea7056c1092a1ff5986e5267e876510a0465ab7"
ZATCA_MIGRATION_CACHE_DIR="${ZATCA_MASTER_MIGRATION_CACHE_DIR:-${DEPLOY_STATE_DIR:-${PROJECT_DIR}/state}/zatca-master}"
ARTIFACT_DIR=""
# Pinned Pressly Goose release; digests are selected per supported Linux arch.
GOOSE_RELEASE_VERSION="v3.30.0"
GOOSE_BIN="${ZATCA_MASTER_GOOSE_BIN:-}"
GOOSE_BIN_EXPLICIT=false
if [ -n "$GOOSE_BIN" ]; then
    GOOSE_BIN_EXPLICIT=true
fi
GOOSE_CACHE_DIR="${ZATCA_MASTER_GOOSE_CACHE_DIR:-${DEPLOY_STATE_DIR:-${PROJECT_DIR}/state}/bin}"
GOOSE_DSN="${ZATCA_MASTER_GOOSE_DSN:-${MYSQL_MASTER_DSN:-}}"
LOCK_FILE="${ZATCA_MASTER_MIGRATION_LOCK_FILE:-${DEPLOY_STATE_DIR:-${PROJECT_DIR}/state}/zatca-master-migration.lock}"
BACKUP_DIR="${ZATCA_MASTER_BACKUP_DIR:-${BACKUP_DIR:-/opt/tenant-backups}}"
DRY_RUN=false
MASTER_BACKUP_PATH=""

usage() {
    cat <<'USAGE'
Usage: migrate-zatca-master.sh [options]

Apply the ZATCA-owned Goose artifact to MYSQL_MASTER_DB before tenant creation.
The approved ZATCA source is fetched at a pinned revision and cached locally.

Options:
  --config <path>                 Config file (default: ../config.env)
  --goose-bin <path>              Goose executable (otherwise auto-installed)
  --dsn <dsn>                     Goose MySQL DSN (otherwise built from config)
  --master-db <name>              Master database (default: zatca_master)
  --dry-run                       Validate configuration without changing MySQL
USAGE
}

for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --config|--goose-bin|--dsn|--master-db)
            i=$((i + 1))
            ;;
        --dry-run|--help|-h) ;;
        *) ;;
    esac
done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)          CONFIG_FILE="$2"; shift 2 ;;
        --goose-bin)       GOOSE_BIN="$2"; GOOSE_BIN_EXPLICIT=true; shift 2 ;;
        --dsn)             GOOSE_DSN="$2"; shift 2 ;;
        --master-db)       MASTER_DB="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --help|-h)         usage; exit 0 ;;
        *)                  error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

validate_database_identifier "$MASTER_DB" || exit 1

fetch_zatca_migration_artifact() {
    local cache_root archive extract_root source_root url download_tool
    cache_root="$ZATCA_MIGRATION_CACHE_DIR/zatca_integration-$ZATCA_MIGRATION_REF"
    ARTIFACT_DIR="$cache_root/migrations/zatca_master"

    if [ -r "$ARTIFACT_DIR/00001_baseline.sql" ] &&
        [ -r "$ARTIFACT_DIR/00002_tenant_key.sql" ]; then
        log "Using cached approved ZATCA migrations at revision $ZATCA_MIGRATION_REF"
        return 0
    fi

    mkdir -p "$ZATCA_MIGRATION_CACHE_DIR" || {
        error "Could not create ZATCA migration cache: $ZATCA_MIGRATION_CACHE_DIR"
        return 1
    }
    rm -rf "$cache_root"

    if command -v curl >/dev/null 2>&1; then
        download_tool=curl
    elif command -v wget >/dev/null 2>&1; then
        download_tool=wget
    else
        error "Fetching approved ZATCA migrations requires curl or wget."
        return 1
    fi
    command -v tar >/dev/null 2>&1 || {
        error "Fetching approved ZATCA migrations requires tar."
        return 1
    }

    archive="$(mktemp "$ZATCA_MIGRATION_CACHE_DIR/.zatca-source.XXXXXX.tar.gz")" || {
        error "Could not create a temporary ZATCA source archive."
        return 1
    }
    extract_root="$(mktemp -d "$ZATCA_MIGRATION_CACHE_DIR/.zatca-extract.XXXXXX")" || {
        rm -f "$archive"
        error "Could not create a temporary ZATCA extraction directory."
        return 1
    }
    url="${ZATCA_MIGRATION_REPOSITORY}/archive/${ZATCA_MIGRATION_REF}.tar.gz"
    log "Fetching approved ZATCA migrations at revision $ZATCA_MIGRATION_REF"
    if [ "$download_tool" = "curl" ]; then
        if ! curl --fail --location --silent --show-error --retry 3 \
            --connect-timeout 10 --max-time 120 --output "$archive" "$url"; then
            rm -f "$archive"
            rm -rf "$extract_root"
            error "Approved ZATCA migration source download failed."
            return 1
        fi
    elif ! wget --quiet --timeout=10 --tries=3 --output-document="$archive" "$url"; then
        rm -f "$archive"
        rm -rf "$extract_root"
        error "Approved ZATCA migration source download failed."
        return 1
    fi

    if ! tar -xzf "$archive" -C "$extract_root"; then
        rm -f "$archive"
        rm -rf "$extract_root"
        error "Approved ZATCA migration source archive could not be extracted."
        return 1
    fi
    rm -f "$archive"

    source_root="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    if [ -z "$source_root" ] ||
        [ ! -r "$source_root/migrations/zatca_master/00001_baseline.sql" ] ||
        [ ! -r "$source_root/migrations/zatca_master/00002_tenant_key.sql" ]; then
        rm -rf "$extract_root"
        error "Approved ZATCA source is missing the required master migration files."
        return 1
    fi
    if ! mv "$source_root" "$cache_root"; then
        rm -rf "$extract_root"
        error "Could not cache the approved ZATCA migration source."
        return 1
    fi
    rm -rf "$extract_root"
    ARTIFACT_DIR="$cache_root/migrations/zatca_master"
    log "Cached approved ZATCA migrations at revision $ZATCA_MIGRATION_REF"
}

fetch_zatca_migration_artifact || exit 1

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
    host="$(goose_connection_host)"
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

goose_connection_host() {
    local host="${ZATCA_MASTER_GOOSE_HOST:-${MYSQL_HOST:-127.0.0.1}}"
    if [ "${ZATCA_MASTER_GOOSE_IN_DOCKER:-0}" = "1" ]; then
        case "$host" in
            localhost|127.0.0.1|::1) host="host.docker.internal" ;;
        esac
    elif [ "$host" = "host.docker.internal" ]; then
        host="127.0.0.1"
    fi
    printf '%s' "$host"
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

goose_download_metadata() {
    local os arch
    os="$(uname -s 2>/dev/null || true)"
    arch="$(uname -m 2>/dev/null || true)"
    if [ "$os" != "Linux" ]; then
        error "Automatic Goose installation supports Linux only (detected $os). Set ZATCA_MASTER_GOOSE_BIN to an installed executable."
        return 1
    fi

    case "$arch" in
        x86_64|amd64)
            GOOSE_ASSET="goose_linux_x86_64"
            GOOSE_PLATFORM="amd64"
            GOOSE_SHA256="cce6e6371670f0654adc0ece407b81a22e53ba51e24e17a80ff7a0e25cda8548"
            ;;
        aarch64|arm64)
            GOOSE_ASSET="goose_linux_arm64"
            GOOSE_PLATFORM="arm64"
            GOOSE_SHA256="624ae3159e221494c5e780c772cc000d788a4afe34a791553e43b2419174a715"
            ;;
        *)
            error "Automatic Goose installation does not support Linux architecture '$arch'. Set ZATCA_MASTER_GOOSE_BIN to an installed executable."
            return 1
            ;;
    esac
}

goose_file_sha256() {
    sha256sum "$1" | awk '{ print $1; exit }'
}

download_goose() {
    local cache_path temp_file url actual download_tool
    goose_download_metadata || return 1

    if ! command -v sha256sum >/dev/null 2>&1; then
        error "sha256sum is required to verify the automatic Goose download."
        return 1
    fi
    mkdir -p "$GOOSE_CACHE_DIR" || {
        error "Could not create the Goose cache directory: $GOOSE_CACHE_DIR"
        return 1
    }

    cache_path="$GOOSE_CACHE_DIR/goose-${GOOSE_RELEASE_VERSION}-${GOOSE_PLATFORM}"
    if [ -e "$cache_path" ]; then
        if [ -f "$cache_path" ] && actual="$(goose_file_sha256 "$cache_path")" &&
            [ "$actual" = "$GOOSE_SHA256" ]; then
            chmod 0755 "$cache_path" || {
                error "Could not make the cached Goose executable: $cache_path"
                return 1
            }
            GOOSE_BIN="$cache_path"
            log "Using verified cached Goose ${GOOSE_RELEASE_VERSION} ($GOOSE_PLATFORM)"
            return 0
        fi
        warn "Discarding an invalid cached Goose binary: $cache_path"
        rm -f "$cache_path" || {
            error "Could not remove the invalid cached Goose binary: $cache_path"
            return 1
        }
    fi

    if command -v curl >/dev/null 2>&1; then
        download_tool=curl
    elif command -v wget >/dev/null 2>&1; then
        download_tool=wget
    else
        error "Automatic Goose installation requires curl or wget."
        return 1
    fi

    temp_file="$(mktemp "$GOOSE_CACHE_DIR/.goose-download.XXXXXX")" || {
        error "Could not create a temporary Goose download in $GOOSE_CACHE_DIR"
        return 1
    }
    url="https://github.com/pressly/goose/releases/download/${GOOSE_RELEASE_VERSION}/${GOOSE_ASSET}"
    log "Downloading verified Goose ${GOOSE_RELEASE_VERSION} ($GOOSE_PLATFORM)"
    if [ "$download_tool" = "curl" ]; then
        if ! curl --fail --location --silent --show-error --retry 3 \
            --connect-timeout 10 --max-time 120 --output "$temp_file" "$url"; then
            rm -f "$temp_file"
            error "Goose download failed."
            return 1
        fi
    elif ! wget --quiet --timeout=10 --tries=3 --output-document="$temp_file" "$url"; then
        rm -f "$temp_file"
        error "Goose download failed."
        return 1
    fi

    if [ ! -s "$temp_file" ]; then
        rm -f "$temp_file"
        error "Goose download returned an empty file."
        return 1
    fi
    actual="$(goose_file_sha256 "$temp_file")" || actual=""
    if [ "$actual" != "$GOOSE_SHA256" ]; then
        rm -f "$temp_file"
        error "Goose download checksum verification failed."
        return 1
    fi
    chmod 0755 "$temp_file" || {
        rm -f "$temp_file"
        error "Could not make the downloaded Goose executable."
        return 1
    }
    if ! mv -f "$temp_file" "$cache_path"; then
        rm -f "$temp_file"
        error "Could not install Goose into the cache: $cache_path"
        return 1
    fi
    GOOSE_BIN="$cache_path"
    log "Installed verified Goose ${GOOSE_RELEASE_VERSION} ($GOOSE_PLATFORM)"
}

resolve_goose_bin() {
    local allow_download="${1:-true}" resolved
    if $GOOSE_BIN_EXPLICIT; then
        if command -v "$GOOSE_BIN" >/dev/null 2>&1; then
            resolved="$(command -v "$GOOSE_BIN")"
        elif [ -x "$GOOSE_BIN" ]; then
            resolved="$GOOSE_BIN"
        else
            error "Goose executable is unavailable: $GOOSE_BIN"
            return 1
        fi
        GOOSE_BIN="$resolved"
        log "Using explicitly configured Goose: $GOOSE_BIN"
        return 0
    fi

    if command -v goose >/dev/null 2>&1; then
        GOOSE_BIN="$(command -v goose)"
        log "Using Goose from PATH: $GOOSE_BIN"
        return 0
    fi

    if [ "$allow_download" != "true" ]; then
        info "Dry run: Goose is not on PATH; a verified ${GOOSE_RELEASE_VERSION} binary would be downloaded."
        return 0
    fi
    download_goose
}

goose_run() {
    local action="$1" dsn host port user
    host="$(goose_connection_host)"
    port="${MYSQL_PORT:-3306}"
    user="$(mysql_admin_user)"
    info "Running Goose action=$action database=$MASTER_DB host=$host port=$port user=$user"
    dsn="$(goose_dsn)" || return 1
    if ! "$GOOSE_BIN" -dir "$ARTIFACT_DIR" mysql "$dsn" "$action"; then
        error "Goose action failed: action=$action database=$MASTER_DB host=$host port=$port user=$user"
        return 1
    fi
}

baseline_legacy_registry() {
    log "Recording the ZATCA baseline for the legacy master registry"
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
        resolve_goose_bin false || return 1
        info "Dry run: would lock, back up, and run Goose from the ZATCA artifact against $MASTER_DB."
        return 0
    fi
    resolve_goose_bin true || return 1

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
            baseline_legacy_registry || return 1
            log "Running ZATCA-owned Goose migrations after the legacy baseline"
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
