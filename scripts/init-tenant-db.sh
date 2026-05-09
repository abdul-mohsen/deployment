#!/usr/bin/env bash
# =============================================================================
# init-tenant-db.sh - Initialize or repair a tenant database
# =============================================================================
# Applies schema/migrations from the backend image used for the tenant. The
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
  --backend-image <image> Backend image containing schema/migrations
  --env KEY=VALUE         Seed value; supports ADMIN_USER, ADMIN_PASSWORD,
                          MANAGER_USER, MANAGER_PASSWORD, COMPANY_NAME
  --schema-only           Apply schema/migrations only
  --seed-only             Seed users/company only
  --dry-run               Show planned work without executing
  --config <path>         Path to config.env file (default: ../config.env)

Environment overrides:
    BACKEND_IMAGE                Backend image containing schema/migrations
    TENANT_IMAGE_PULL_POLICY     always | missing | never (default: always)
    TENANT_SCHEMA_IMAGE_PATH     Schema path inside backend image
    TENANT_MIGRATIONS_IMAGE_DIR  Migrations directory inside backend image
    TENANT_IGNORED_SCHEMA_FILES  Comma-separated schema files to skip
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
TENANT_SCHEMA_IMAGE_PATH="${TENANT_SCHEMA_IMAGE_PATH:-/app/db/schema/schema.sql}"
TENANT_MIGRATIONS_IMAGE_DIR="${TENANT_MIGRATIONS_IMAGE_DIR:-/app/db/migrations}"
TENANT_IMAGE_PULL_POLICY="${TENANT_IMAGE_PULL_POLICY:-always}"
TENANT_IGNORED_SCHEMA_FILES="${TENANT_IGNORED_SCHEMA_FILES:-car_part.sql}"

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

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
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

    error "Backend image is required to apply schema from image. Pass --backend-image <image>."
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

image_has_file() {
    local image="$1" path="$2"
    docker run --rm --entrypoint sh "$image" -c "test -f $(shell_quote "$path")" >/dev/null 2>&1
}

image_has_dir() {
    local image="$1" path="$2"
    docker run --rm --entrypoint sh "$image" -c "test -d $(shell_quote "$path")" >/dev/null 2>&1
}

find_image_file() {
    local image="$1" path
    shift
    if $DRY_RUN; then
        echo "$TENANT_SCHEMA_IMAGE_PATH"
        return 0
    fi
    for path in "$@"; do
        if image_has_file "$image" "$path"; then
            if schema_file_is_ignored "$path"; then
                warn "Ignoring backend schema file: $path"
                continue
            fi
            echo "$path"
            return 0
        fi
    done
    return 1
}

schema_file_is_ignored() {
    local base
    base="$(basename "$1")"
    case ",$TENANT_IGNORED_SCHEMA_FILES," in
        *,"$base",*) return 0 ;;
        *) return 1 ;;
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
    if [ "$_MYSQL_VIA" = "host" ] && [ "$host" = "host.docker.internal" ]; then
        echo "127.0.0.1"
    else
        echo "$host"
    fi
}

run_tenant_mysql() {
    local db="${1:-$TENANT_DB_NAME}"
    shift || true

    local user password host port
    user="$(tenant_db_setting DB_USER "")"
    [ -n "$user" ] || user="$(tenant_db_setting DBUSER "usr_${TENANT_NAME//-/_}")"
    password="$(tenant_db_setting DB_PASSWORD "")"
    [ -n "$password" ] || password="$(tenant_db_setting PASSWORD "")"
    host="$(tenant_db_host)"
    port="$(tenant_db_port)"

    if [ -z "$password" ]; then
        error "Tenant DB password is missing from ${BACKEND_APP} config; cannot import schema as tenant user."
        exit 1
    fi

    if [ "$_MYSQL_VIA" = "host" ]; then
        MYSQL_PWD="$password" mysql -h "$(resolve_mysql_host_for_client "$host")" -P "$port" -u "$user" "$db" "$@"
    else
        docker run --rm -i \
            --add-host=host.docker.internal:host-gateway \
            -e "MYSQL_PWD=$password" \
            mysql:8.0 \
            mysql -h "$host" -P "$port" -u "$user" "$db" "$@"
    fi
}

find_image_dir() {
    local image="$1" path
    shift
    if $DRY_RUN; then
        echo "$TENANT_MIGRATIONS_IMAGE_DIR"
        return 0
    fi
    for path in "$@"; do
        if image_has_dir "$image" "$path"; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

mysql_compatible_sql_stream() {
    sed -E 's#/\*!50013 DEFINER=`[^`]+`@`[^`]+` SQL SECURITY DEFINER \*/#/\*!50013 SQL SECURITY INVOKER \*/#g' \
        | awk '
            function sql_literal(value, escaped) {
                escaped = value
                gsub(/\047/, "\047\047", escaped)
                return escaped
            }

            function capture_index_name(statement_line) {
                if (match(statement_line, /`[^`]+`/)) {
                    return substr(statement_line, RSTART + 1, RLENGTH - 2)
                }
                return ""
            }

            function capture_table_name(statement_line, table_name) {
                table_name = statement_line
                sub(/^.*[[:space:]]ON[[:space:]]+`/, "", table_name)
                sub(/`.*$/, "", table_name)
                return table_name
            }

            function emit_guarded_index(ddl) {
                if (index_name == "" || index_table == "") {
                    print index_statement
                    return
                }

                ddl = index_statement
                gsub(/[[:space:]]+/, " ", ddl)
                sub(/[[:space:]]*;[[:space:]]*$/, "", ddl)
                sub(/CREATE[[:space:]]+INDEX[[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+/, "CREATE INDEX ", ddl)

                print "SET @idx_exists = (SELECT COUNT(1) FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = \047" sql_literal(index_table) "\047 AND index_name = \047" sql_literal(index_name) "\047);"
                print "SET @ddl = IF(@idx_exists = 0, \047" sql_literal(ddl) "\047, \047SELECT 1\047);"
                print "PREPARE stmt FROM @ddl;"
                print "EXECUTE stmt;"
                print "DEALLOCATE PREPARE stmt;"
            }

            /^[[:space:]]*CREATE[[:space:]]+INDEX[[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+`/ {
                in_index_statement = 1
                index_statement = $0
                index_name = capture_index_name($0)
                index_table = ""
                if ($0 ~ /[[:space:]]ON[[:space:]]+`/) {
                    index_table = capture_table_name($0)
                }
                if ($0 ~ /;[[:space:]]*$/) {
                    emit_guarded_index()
                    in_index_statement = 0
                }
                next
            }

            in_index_statement {
                index_statement = index_statement "\n" $0
                if (index_table == "" && $0 ~ /[[:space:]]ON[[:space:]]+`/) {
                    index_table = capture_table_name($0)
                }
                if ($0 ~ /;[[:space:]]*$/) {
                    emit_guarded_index()
                    in_index_statement = 0
                }
                next
            }

            { print }

            END {
                if (in_index_statement) {
                    print index_statement
                }
            }
        '
}

apply_image_sql_file() {
    local image="$1" path="$2" label="$3"
    log "Applying ${label}: ${image}:${path}"
    if $DRY_RUN; then
        info "Would stream ${image}:${path} into ${TENANT_DB_NAME}"
        return 0
    fi
    docker run --rm --entrypoint sh "$image" -c "cat $(shell_quote "$path")" \
        | mysql_compatible_sql_stream \
        | run_tenant_mysql "$TENANT_DB_NAME"
}

list_image_migrations() {
    local image="$1" dir="$2"
    docker run --rm --entrypoint sh "$image" -c "find $(shell_quote "$dir") -maxdepth 1 -type f -name '*.sql' | sort"
}

apply_schema() {
    ensure_tenant_database

    local image count schema_path migrations_dir migration migrations_found
    image="$(resolve_backend_image)"
    ensure_backend_image_available "$image"

    count="$(tenant_table_count)"
    if [ "$count" != "0" ]; then
        info "Tenant DB already has $count tables; skipping base schema to avoid destructive DROP statements."
    else
        schema_path="$(find_image_file "$image" \
            "$TENANT_SCHEMA_IMAGE_PATH" \
            /app/pkg/db/schema/schema.sql \
            /app/schema.sql)" || {
            error "Backend image does not contain a tenant schema file."
            error "Expected ${TENANT_SCHEMA_IMAGE_PATH} (or set TENANT_SCHEMA_IMAGE_PATH)."
            error "Fix the backend Dockerfile to copy schema into the runtime image."
            exit 1
        }
        apply_image_sql_file "$image" "$schema_path" "base schema"
    fi

    migrations_dir="$(find_image_dir "$image" \
        "$TENANT_MIGRATIONS_IMAGE_DIR" \
        /app/pkg/db/migrations \
        /app/migrations)" || true
    if [ -z "$migrations_dir" ]; then
        warn "Backend image has no migrations directory; skipping migrations."
        return 0
    fi

    migrations_found=false
    if $DRY_RUN; then
        log "Applying migrations from ${image}:${migrations_dir}"
        info "Would apply all *.sql files in sorted order"
        return 0
    fi

    while IFS= read -r migration; do
        [ -n "$migration" ] || continue
        migrations_found=true
        apply_image_sql_file "$image" "$migration" "migration $(basename "$migration")"
    done < <(list_image_migrations "$image" "$migrations_dir")

    if ! $migrations_found; then
        warn "No *.sql migrations found in ${image}:${migrations_dir}."
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