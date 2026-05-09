#!/usr/bin/env bash
# =============================================================================
# init-tenant-db.sh - Initialize or repair a tenant database
# =============================================================================
# Applies the bundled ifritah schema/migrations to an empty tenant DB and, when
# credentials are supplied, registers admin/manager users through the tenant API
# so passwords are hashed by the backend itself.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 <tenant-name> [options]

Options:
  --env KEY=VALUE       Seed value; supports ADMIN_USER, ADMIN_PASSWORD,
                        MANAGER_USER, MANAGER_PASSWORD, COMPANY_NAME
  --schema-only         Apply schema/migrations only
  --seed-only           Seed users/company only
  --dry-run             Show planned work without executing
  --config <path>       Path to config.env file (default: ../config.env)

Environment overrides:
  TENANT_SCHEMA_FILE    SQL schema file to apply to an empty tenant DB
  TENANT_MIGRATIONS_DIR Directory containing idempotent *.sql migrations
EOF
}

CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
TENANT_NAME=""
SCHEMA_ONLY=false
SEED_ONLY=false
DRY_RUN=false
declare -a ENV_VARS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)         ENV_VARS+=("$2"); shift 2 ;;
        --schema-only) SCHEMA_ONLY=true; shift ;;
        --seed-only)   SEED_ONLY=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --config)      CONFIG_FILE="$2"; shift 2 ;;
        --help|-h)     usage; exit 0 ;;
        -*)            error "Unknown option: $1"; usage; exit 1 ;;
        *)
            if [ -z "$TENANT_NAME" ]; then
                TENANT_NAME="$1"
            else
                error "Unexpected argument: $1"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if $SCHEMA_ONLY && $SEED_ONLY; then
    error "Use only one of --schema-only or --seed-only."
    exit 1
fi

if [ -z "$TENANT_NAME" ]; then
    usage
    exit 1
fi

TENANT_NAME="$(echo "$TENANT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/^-//;s/-$//')"
if [ -z "$TENANT_NAME" ] || [ ${#TENANT_NAME} -gt 63 ]; then
    error "Invalid tenant name (must be 1-63 chars, lowercase alphanumeric + hyphens)."
    exit 1
fi

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    error "Config file not found: $CONFIG_FILE"
    exit 1
fi

BASE_DOMAIN="${BASE_DOMAIN:?BASE_DOMAIN not set in config.env}"
DOKKU_PORT="${DOKKU_PORT:-8080}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
MYSQL_TENANT_HOST="${MYSQL_TENANT_HOST:-172.%}"

if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" = "changeme" ]; then
    error "MYSQL_ROOT_PASSWORD is not configured; cannot initialize tenant DB."
    exit 1
fi

TENANT_DB_NAME="tenant_${TENANT_NAME//-/_}"
TENANT_DB_USER="usr_${TENANT_NAME//-/_}"
TENANT_DOMAIN="${TENANT_NAME}.${BASE_DOMAIN}"
SCHEMA_FILE="${TENANT_SCHEMA_FILE:-$SCRIPT_DIR/sql/ifritah-schema.sql}"
MIGRATIONS_DIR="${TENANT_MIGRATIONS_DIR:-$SCRIPT_DIR/sql/ifritah-migrations}"

env_value() {
    local key="$1"
    local ev
    for ev in "${ENV_VARS[@]+${ENV_VARS[@]}}"; do
        if [[ "$ev" == "$key="* ]]; then
            printf '%s' "${ev#*=}"
            return 0
        fi
    done
    printf '%s' "${!key:-}"
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

tenant_table_count() {
    if $DRY_RUN; then
        echo 0
        return 0
    fi
    run_mysql -N -B "$TENANT_DB_NAME" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();" | awk 'NF { print $1; exit }'
}

ensure_tenant_database() {
    if $DRY_RUN; then
        info "Would ensure database exists: $TENANT_DB_NAME"
        return 0
    fi

    run_mysql <<SQLEOF
CREATE DATABASE IF NOT EXISTS \`${TENANT_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQLEOF
}

apply_schema() {
    ensure_tenant_database

    local count
    count="$(tenant_table_count)"
    if [ "$count" != "0" ]; then
        info "Tenant DB already has $count tables; skipping bundled base schema to avoid destructive DROP statements."
    else
        if [ ! -f "$SCHEMA_FILE" ]; then
            error "Tenant schema file not found: $SCHEMA_FILE"
            exit 1
        fi
        log "Applying base schema to $TENANT_DB_NAME"
        if $DRY_RUN; then
            info "Would apply: $SCHEMA_FILE"
        else
            run_mysql "$TENANT_DB_NAME" < "$SCHEMA_FILE"
        fi
    fi

    if [ -d "$MIGRATIONS_DIR" ]; then
        local migration
        for migration in "$MIGRATIONS_DIR"/*.sql; do
            [ -e "$migration" ] || continue
            log "Applying migration: $(basename "$migration")"
            if $DRY_RUN; then
                info "Would apply: $migration"
            else
                run_mysql "$TENANT_DB_NAME" < "$migration"
            fi
        done
    else
        warn "Migrations directory not found: $MIGRATIONS_DIR"
    fi
}

seed_company_defaults() {
    local company_name
    company_name="$(env_value COMPANY_NAME)"
    company_name="${company_name:-$TENANT_NAME}"
    local company_sql
    company_sql="$(sql_escape "$company_name")"

    log "Seeding company/store defaults"
    if $DRY_RUN; then
        info "Would seed company '$company_name' in $TENANT_DB_NAME"
        return 0
    fi

    run_mysql "$TENANT_DB_NAME" <<SQLEOF
INSERT INTO company (id, state, name, vat_number, vat_registration_number, commercial_registration_number, name_ar, business_category)
VALUES (1, 0, '${company_sql}', '300000000000003', '300000000000003', '1010000000', '${company_sql}', 'Supply activities')
ON DUPLICATE KEY UPDATE name=VALUES(name), name_ar=VALUES(name_ar);

INSERT INTO branches (id, name, company_id, is_active)
VALUES (1, 'Main', 1, 1)
ON DUPLICATE KEY UPDATE company_id=VALUES(company_id), is_active=VALUES(is_active);

INSERT INTO store (id, company_id, branch_id, name, status)
VALUES (1, 1, 1, 'Main Store', 0)
ON DUPLICATE KEY UPDATE company_id=VALUES(company_id), branch_id=VALUES(branch_id), status=VALUES(status);
SQLEOF
}

http_post_register() {
    local payload="$1"
    local url="http://127.0.0.1:${DOKKU_PORT}/api/register"
    local -a args=(-sS -w $'\n%{http_code}' -H "Host: ${TENANT_DOMAIN}" -H "Content-Type: application/json" --data "$payload" "$url")

    if command -v curl >/dev/null 2>&1; then
        curl "${args[@]}"
        return $?
    fi
    if command -v docker >/dev/null 2>&1; then
        docker run --rm --network host curlimages/curl:8.10.1 "${args[@]}"
        return $?
    fi
    error "Neither curl nor docker is available to register seed users."
    return 1
}

set_user_role() {
    local username="$1"
    local role="$2"
    local username_sql
    username_sql="$(sql_escape "$username")"

    if $DRY_RUN; then
        info "Would set role '$role' for user '$username'"
        return 0
    fi

    local user_id
    user_id="$(run_mysql -N -B "$TENANT_DB_NAME" -e "SELECT id FROM \`user\` WHERE username='${username_sql}' LIMIT 1;" | awk 'NF { print $1; exit }')"
    if [ -z "$user_id" ]; then
        error "Seed user '$username' was not found after registration."
        exit 1
    fi

    run_mysql "$TENANT_DB_NAME" <<SQLEOF
UPDATE \`user\`
SET role='${role}', is_active=1, company_id=1
WHERE id=${user_id};

INSERT INTO user_permission (user_id, resource, can_view, can_add, can_edit, can_delete)
VALUES
  (${user_id}, 'invoices', 1, 1, 1, 1),
  (${user_id}, 'products', 1, 1, 1, 1),
  (${user_id}, 'clients', 1, 1, 1, 1),
  (${user_id}, 'suppliers', 1, 1, 1, 1),
  (${user_id}, 'stores', 1, 1, 1, 1),
  (${user_id}, 'orders', 1, 1, 1, 1),
  (${user_id}, 'users', 1, 1, 1, 1),
  (${user_id}, 'settings', 1, 1, 1, 1)
ON DUPLICATE KEY UPDATE
  can_view=VALUES(can_view),
  can_add=VALUES(can_add),
  can_edit=VALUES(can_edit),
  can_delete=VALUES(can_delete);
SQLEOF
}

register_seed_user() {
    local username="$1"
    local password="$2"
    local role="$3"
    local full_name="$4"

    if [ -z "$username" ] || [ -z "$password" ]; then
        warn "Skipping ${role} seed user; username/password not supplied."
        return 0
    fi

    local email payload response status body attempt
    email="${username}@${TENANT_DOMAIN}"
    payload="{\"username\":\"$(json_escape "$username")\",\"email\":\"$(json_escape "$email")\",\"password\":\"$(json_escape "$password")\",\"full_name\":\"$(json_escape "$full_name")\",\"phone\":\"\"}"

    log "Registering ${role} seed user: $username"
    if $DRY_RUN; then
        info "Would POST /api/register for '$username' on $TENANT_DOMAIN"
        return 0
    fi

    for attempt in {1..30}; do
        response="$(http_post_register "$payload" 2>&1 || true)"
        status="${response##*$'\n'}"
        body="${response%$'\n'$status}"

        if [ "$status" = "201" ] || [ "$status" = "200" ] || [ "$status" = "409" ]; then
            [ "$status" = "409" ] && warn "User '$username' already exists; updating role and permissions."
            set_user_role "$username" "$role"
            return 0
        fi

        if [ "$status" = "000" ] || [ "$status" = "502" ] || [ "$status" = "503" ] || [ "$status" = "504" ]; then
            sleep 2
            continue
        fi

        error "Failed to register user '$username' (HTTP $status): $body"
        exit 1
    done

    error "Tenant app did not become ready for seed registration after 60 seconds."
    exit 1
}

seed_users() {
    seed_company_defaults

    local admin_user admin_password manager_user manager_password company_name
    admin_user="$(env_value ADMIN_USER)"
    admin_password="$(env_value ADMIN_PASSWORD)"
    manager_user="$(env_value MANAGER_USER)"
    manager_password="$(env_value MANAGER_PASSWORD)"
    company_name="$(env_value COMPANY_NAME)"
    company_name="${company_name:-$TENANT_NAME}"

    register_seed_user "$admin_user" "$admin_password" "admin" "${company_name} Admin"
    register_seed_user "$manager_user" "$manager_password" "manager" "${company_name} Manager"
}

info "Tenant DB init target: $TENANT_NAME ($TENANT_DB_NAME)"
if ! $SEED_ONLY; then
    apply_schema
fi
if ! $SCHEMA_ONLY; then
    seed_users
fi

log "Tenant DB initialization complete: $TENANT_NAME"