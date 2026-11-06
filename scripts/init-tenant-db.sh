#!/usr/bin/env bash
# =============================================================================
# init-tenant-db.sh - Initialize or repair a tenant database
# =============================================================================
# Builds the tenant DB with goose: runs /app/migrate up from the backend image
# (the only migration path), then seeds company/store and the seed users. The
# deployment repo intentionally does not own or copy database schema files.
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
  --backend-image <image> Backend image whose /app/migrate runs goose
  --env KEY=VALUE         Seed value; supports ADMIN_USER, ADMIN_PASSWORD,
                          MANAGER_USER, MANAGER_PASSWORD, COMPANY_NAME
  --schema-only           Run goose migrations and the company seed only
  --seed-only             Seed users/company only
  --dry-run               Show planned work without executing
  --config <path>         Path to config.env file (default: ../config.env)

Environment overrides:
    BACKEND_IMAGE                Backend image whose /app/migrate runs goose
    TENANT_IMAGE_PULL_POLICY     always | missing | never (default: always)
EOF
}

CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
TENANT_NAME=""
BACKEND_IMAGE="${BACKEND_IMAGE:-}"
SCHEMA_ONLY=false
SEED_ONLY=false
DRY_RUN=false
declare -a ENV_VARS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend-image) BACKEND_IMAGE="$2"; shift 2 ;;
        --env)           ENV_VARS+=("$2"); shift 2 ;;
        --schema-only)   SCHEMA_ONLY=true; shift ;;
        --seed-only)     SEED_ONLY=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --config)        CONFIG_FILE="$2"; shift 2 ;;
        --help|-h)       usage; exit 0 ;;
        -*)              error "Unknown option: $1"; usage; exit 1 ;;
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

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    error "Config file not found: $CONFIG_FILE"
    exit 1
fi

TENANT_NAME="$(tenant_full_name "$TENANT_NAME")" || exit 1

BASE_DOMAIN="${BASE_DOMAIN:?BASE_DOMAIN not set in config.env}"
DOKKU_PORT="${DOKKU_PORT:-8080}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
TENANT_IMAGE_PULL_POLICY="${TENANT_IMAGE_PULL_POLICY:-always}"

if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" = "changeme" ]; then
    error "MYSQL_ROOT_PASSWORD is not configured; cannot initialize tenant DB."
    exit 1
fi

BACKEND_APP="${TENANT_NAME}-backend"
TENANT_DB_NAME="tenant_${TENANT_NAME//-/_}"
TENANT_DOMAIN="${TENANT_NAME}.${BASE_DOMAIN}"

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

sql_identifier_escape() {
    printf '%s' "$1" | sed 's/`/``/g'
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

tenant_missing_required_tables() {
    run_tenant_mysql "$TENANT_DB_NAME" -N -B -e "SELECT required.name FROM (SELECT 'company' AS name UNION ALL SELECT 'branches' UNION ALL SELECT 'store' UNION ALL SELECT 'user') required LEFT JOIN information_schema.tables existing ON existing.table_schema=DATABASE() AND existing.table_name=required.name WHERE existing.table_name IS NULL;" \
        | paste -sd ',' -
}

validate_tenant_schema() {
    if $DRY_RUN; then
        return 0
    fi
    local missing
    missing="$(tenant_missing_required_tables)"
    if [ -n "$missing" ]; then
        error "Tenant schema is incomplete in ${TENANT_DB_NAME}; missing required tables: $missing"
        exit 1
    fi
    info "Tenant schema verified: required base tables exist."
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

resolve_backend_image() {
    if [ -n "$BACKEND_IMAGE" ]; then
        echo "$BACKEND_IMAGE"
        return 0
    fi

    local cid image
    cid="$(docker ps -a \
        --filter "label=com.dokku.app-name=${BACKEND_APP}" \
        --filter "label=com.dokku.process-type=web" \
        --format '{{.ID}}' | head -1)"
    if [ -n "$cid" ]; then
        image="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
        if [ -n "$image" ]; then
            echo "$image"
            return 0
        fi
    fi

    image="$(dokku git:report "$BACKEND_APP" 2>/dev/null | awk '/source-image/ {print $NF; exit}' || true)"
    if [ -n "$image" ]; then
        echo "$image"
        return 0
    fi

    error "Backend image is required to run goose migrations. Pass --backend-image <image>."
    exit 1
}

ensure_backend_image_available() {
    local image="$1"
    if $DRY_RUN; then
        info "Would use backend image: $image"
        return 0
    fi
    case "$TENANT_IMAGE_PULL_POLICY" in
        always)
            log "Pulling backend image: $image"
            docker pull "$image" >/dev/null
            ;;
        missing)
            if docker image inspect "$image" >/dev/null 2>&1; then
                return 0
            fi
            log "Pulling backend image: $image"
            docker pull "$image" >/dev/null
            ;;
        never)
            if ! docker image inspect "$image" >/dev/null 2>&1; then
                error "Backend image is not present locally and TENANT_IMAGE_PULL_POLICY=never: $image"
                exit 1
            fi
            ;;
        *)
            error "TENANT_IMAGE_PULL_POLICY must be 'always', 'missing', or 'never' (got: $TENANT_IMAGE_PULL_POLICY)"
            exit 1
            ;;
    esac
}

backend_config_value() {
    local key="$1"
    dokku config:get "$BACKEND_APP" "$key" 2>/dev/null | awk 'NF { print; exit }' || true
}

tenant_db_setting() {
    local key="$1" fallback="${2:-}" value
    value="$(env_value "$key")"
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi
    value="$(backend_config_value "$key")"
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi
    printf '%s' "$fallback"
}

tenant_db_host() {
    local host
    host="$(tenant_db_setting DB_HOST "")"
    if [ -z "$host" ]; then
        host="$(tenant_db_setting HOST "")"
        host="${host%%:*}"
    fi
    printf '%s' "${host:-${MYSQL_HOST:-host.docker.internal}}"
}

tenant_db_port() {
    local port host_value
    port="$(tenant_db_setting DB_PORT "")"
    if [ -z "$port" ]; then
        host_value="$(tenant_db_setting HOST "")"
        if [[ "$host_value" == *:* ]]; then
            port="${host_value##*:}"
        fi
    fi
    printf '%s' "${port:-${MYSQL_PORT:-3306}}"
}

resolve_mysql_host_for_client() {
    local host="$1"
    case "$host" in
        localhost|127.0.0.1|::1)
            if [ "$_MYSQL_VIA" = "docker" ]; then
                echo "host.docker.internal"
            else
                echo "127.0.0.1"
            fi
            ;;
        host.docker.internal)
            if [ "$_MYSQL_VIA" = "host" ]; then
                echo "127.0.0.1"
            else
                echo "host.docker.internal"
            fi
            ;;
        *) echo "$host" ;;
    esac
}

tenant_db_user() {
    local user
    user="$(tenant_db_setting DB_USER "")"
    [ -n "$user" ] || user="$(tenant_db_setting DBUSER "usr_${TENANT_NAME//-/_}")"
    printf '%s' "$user"
}

tenant_db_password() {
    local password
    password="$(tenant_db_setting DB_PASSWORD "")"
    [ -n "$password" ] || password="$(tenant_db_setting PASSWORD "")"
    printf '%s' "$password"
}

run_tenant_mysql() {
    local db="${1:-$TENANT_DB_NAME}"
    shift || true

    local user password host port
    user="$(tenant_db_user)"
    password="$(tenant_db_password)"
    host="$(tenant_db_host)"
    port="$(tenant_db_port)"

    if [ -z "$password" ]; then
        error "Tenant DB password is missing from ${BACKEND_APP} config; cannot connect as tenant user."
        exit 1
    fi

    if [ "$_MYSQL_VIA" = "host" ]; then
        MYSQL_PWD="$password" mysql --protocol=TCP -h "$(resolve_mysql_host_for_client "$host")" -P "$port" -u "$user" "$db" "$@"
    else
        docker run --rm -i \
            --add-host=host.docker.internal:host-gateway \
            -e "MYSQL_PWD=$password" \
            mysql:8.0 \
            mysql --protocol=TCP -h "$(resolve_mysql_host_for_client "$host")" -P "$port" -u "$user" "$db" "$@"
    fi
}

apply_schema() {
    ensure_tenant_database

    local image
    image="$(resolve_backend_image)"
    ensure_backend_image_available "$image"

    log "Running goose migrations from ${image}: /app/migrate up"
    if $DRY_RUN; then
        info "Would run /app/migrate up from ${image} against ${TENANT_DB_NAME}"
    else
        goose_run "$image" up "$(tenant_db_host)" "$(tenant_db_port)" "$TENANT_DB_NAME" \
            "$(tenant_db_user)" "$(tenant_db_password)" || {
            error "goose migrations failed for ${TENANT_DB_NAME}; tenant DB is not initialized."
            exit 1
        }
    fi

    validate_tenant_schema
    seed_company_defaults
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

    # The backend refuses to start without company.tenant_key. Copy it from the
    # zatca_master registry; it is never generated here.
    local tenant_key tenant_key_sql
    tenant_key="$(tenant_registry_key "$TENANT_DB_NAME")" || exit 1
    tenant_key_sql="$(sql_escape "$tenant_key")"

    run_tenant_mysql "$TENANT_DB_NAME" <<SQLEOF
INSERT INTO company (id, state, name, vat_number, vat_registration_number, commercial_registration_number, name_ar, business_category, tenant_key)
VALUES (1, 0, '${company_sql}', '300000000000003', '300000000000003', '1010000000', '${company_sql}', 'Supply activities', '${tenant_key_sql}')
ON DUPLICATE KEY UPDATE name=VALUES(name), name_ar=VALUES(name_ar), tenant_key=VALUES(tenant_key);

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
    # Backend routes are mounted under BASEURL (default /api/v2 — set by
    # create-tenant.sh). Use the same prefix so this matches the deployed backend.
    local basepath="${BASEURL:-/api/v2}"
    # Hit the backend container DIRECTLY via the tenant docker network,
    # bypassing Dokku's nginx + the frontend Go proxy. The frontend enforces
    # a session-based CSRF token check on /api/* that the seed sidecar cannot
    # satisfy (no browser session, no prior GET to obtain the token). The
    # backend itself puts /register on nonAuthGroup with no CSRF middleware,
    # so a direct hit succeeds.
    local network="${TENANT_APP_NETWORK:-${TENANT_NETWORK:-web}}"
    local backend_port="${BACKEND_PORT:-8090}"
    local url="http://${BACKEND_APP}.web:${backend_port}${basepath}/register"
    if [ "${DASHBOARD_ENV:-}" = "dev" ]; then
        info "[dev-diag] http_post_register url=${url} network=${network}"
    fi
    local -a args=(-sS -w $'\n%{http_code}' -H "Content-Type: application/json" --data "$payload" "$url")

    if ! command -v docker >/dev/null 2>&1; then
        error "docker is required to register seed users via the tenant network."
        return 1
    fi
    docker run --rm --network "$network" \
        curlimages/curl:8.10.1 \
        "${args[@]}"
    return $?
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
    user_id="$(run_tenant_mysql "$TENANT_DB_NAME" -N -B -e "SELECT id FROM \`user\` WHERE username='${username_sql}' LIMIT 1;" | awk 'NF { print $1; exit }')"
    if [ -z "$user_id" ]; then
        error "Seed user '$username' was not found after registration."
        exit 1
    fi

    run_tenant_mysql "$TENANT_DB_NAME" <<SQLEOF
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

    # Backend requires password >= 8 characters. Pad short passwords with a suffix
    # so the seed doesn't fail silently with HTTP 400.
    if [ "${#password}" -lt 8 ]; then
        warn "Password for '${username}' is shorter than 8 characters (required by backend). Appending suffix."
        password="${password}Pass1!"
    fi

    local email payload response status body attempt
    email="${username}@${TENANT_DOMAIN}"
    payload="{\"username\":\"$(json_escape "$username")\",\"email\":\"$(json_escape "$email")\",\"password\":\"$(json_escape "$password")\",\"full_name\":\"$(json_escape "$full_name")\",\"phone\":\"\"}"

    log "Registering ${role} seed user: $username"
    if $DRY_RUN; then
        info "Would POST ${BASEURL:-/api/v2}/register for '$username' on $TENANT_DOMAIN"
        return 0
    fi

    for attempt in {1..30}; do
        response="$(http_post_register "$payload" 2>&1 || true)"
        status="${response##*$'\n'}"
        body="${response%$'\n'$status}"
        if [ "${DASHBOARD_ENV:-}" = "dev" ]; then
            info "[dev-diag] register attempt=${attempt} status='${status}' body_len=${#body} body_head=$(printf '%.120s' "$body")"
        fi

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