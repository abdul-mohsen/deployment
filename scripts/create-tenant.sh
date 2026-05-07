#!/usr/bin/env bash
# =============================================================================
# create-tenant.sh — Provision a new tenant on Dokku
# =============================================================================
# Creates a complete tenant with:
#   - Backend app (API) at <tenant>.<domain>/api
#   - Frontend app at <tenant>.<domain>
#   - Persistent storage for uploads/data
#   - Auto-SSL via Let's Encrypt
#   - Health checks and auto-restart
#
# Usage:
#   ./scripts/create-tenant.sh <tenant-name> [options]
#
# Options:
#   --backend-image <image>   Docker image for backend (or deploy via git later)
#   --frontend-image <image>  Docker image for frontend (or deploy via git later)
#   --backend-port <port>     Port the backend listens on (default: 3000)
#   --frontend-port <port>    Port the frontend listens on (default: 80)
#   --no-database             Skip database creation
#   --env KEY=VALUE           Set env var (repeatable)
#   --git-only                Create apps without deploying (deploy via git push)
#   --dry-run                 Show plan without executing
#   --migrate <cmd>           Run migration after initial deploy (e.g. "npm run migrate")
#   --config <path>           Path to config.env file (default: ../config.env)
#
# Examples:
#   ./scripts/create-tenant.sh acme --git-only
#   ./scripts/create-tenant.sh acme --backend-image myregistry/api:v1
#   ./scripts/create-tenant.sh acme --backend-image myregistry/api:v1 --env SECRET_KEY=abc123
#   ./scripts/create-tenant.sh acme --config /opt/deployment/config.dev.env
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
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

# ---- Load config ----
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    error "Config file not found: $CONFIG_FILE"
    error "Run setup.sh first, or specify --config <path>."
    exit 1
fi

# ---- Parse arguments ----
TENANT_NAME=""
BACKEND_IMAGE=""
FRONTEND_IMAGE=""
BACKEND_PORT="3000"
FRONTEND_PORT="80"
NO_DATABASE=false
GIT_ONLY=false
DRY_RUN=false
MIGRATE_CMD=""
declare -a ENV_VARS=()

has_env_var() {
    local key="$1"
    local ev
    for ev in "${ENV_VARS[@]+${ENV_VARS[@]}}"; do
        if [[ "$ev" == "$key="* ]]; then
            return 0
        fi
    done
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend-image)  BACKEND_IMAGE="$2"; shift 2 ;;
        --frontend-image) FRONTEND_IMAGE="$2"; shift 2 ;;
        --backend-port)   BACKEND_PORT="$2"; shift 2 ;;
        --frontend-port)  FRONTEND_PORT="$2"; shift 2 ;;
        --no-database)    NO_DATABASE=true; shift ;;
        --env)            ENV_VARS+=("$2"); shift 2 ;;
        --git-only)       GIT_ONLY=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --migrate)        MIGRATE_CMD="$2"; shift 2 ;;
        --config)         CONFIG_FILE="$2"; shift 2 ;;
        -*)               error "Unknown option: $1"; exit 1 ;;
        *)
            if [ -z "$TENANT_NAME" ]; then
                TENANT_NAME="$1"
            else
                error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# ---- Validate ----
if [ -z "$TENANT_NAME" ]; then
    echo "Usage: $0 <tenant-name> [options]"
    echo ""
    echo "Run with --help or see script header for all options."
    exit 1
fi

# Sanitize: lowercase, alphanumeric + hyphens
TENANT_NAME="$(echo "$TENANT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/^-//;s/-$//')"

if [ -z "$TENANT_NAME" ] || [ ${#TENANT_NAME} -gt 63 ]; then
    error "Invalid tenant name (must be 1-63 chars, lowercase alphanumeric + hyphens)."
    exit 1
fi

BASE_DOMAIN="${BASE_DOMAIN:?BASE_DOMAIN not set in config.env}"
STORAGE_ROOT="${STORAGE_ROOT:-/opt/tenant-data}"

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
HAS_DATABASE_URL=false
HAS_DB_PARTS=false
if has_env_var "DATABASE_URL"; then
    HAS_DATABASE_URL=true
fi
if has_env_var "DB_HOST" && has_env_var "DB_PORT" && has_env_var "DB_NAME" && has_env_var "DB_USER" && has_env_var "DB_PASSWORD"; then
    HAS_DB_PARTS=true
fi

BACKEND_APP="${TENANT_NAME}-backend"
FRONTEND_APP="${TENANT_NAME}-frontend"
TENANT_DOMAIN="${TENANT_NAME}.${BASE_DOMAIN}"

if [ -n "$BACKEND_IMAGE" ] && ! $HAS_DATABASE_URL && ! $HAS_DB_PARTS; then
    if $NO_DATABASE; then
        error "Backend image deploy requires database settings, but --no-database was set and no DATABASE_URL/DB_* env vars were provided."
        error "Either remove --no-database and configure MySQL, or provide explicit DB env vars."
        exit 1
    fi
    if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" = "changeme" ]; then
        error "Backend image deploy requires database provisioning, but MYSQL_ROOT_PASSWORD is not configured in config.env."
        error "Set MYSQL_ROOT_PASSWORD, run scripts/verify-mysql.sh, then retry; or provide DATABASE_URL/DB_* via --env; or use --git-only."
        exit 1
    fi
fi

# Check if apps already exist
if dokku apps:exists "$BACKEND_APP" 2>/dev/null; then
    error "App '$BACKEND_APP' already exists. Tenant may already be provisioned."
    exit 1
fi

# ---- Show plan ----
echo ""
info "=== Tenant Provisioning Plan ==="
info "  Tenant:         $TENANT_NAME"
info "  Domain:         $TENANT_DOMAIN"
info "  Backend app:    $BACKEND_APP  → $TENANT_DOMAIN/api"
info "  Frontend app:   $FRONTEND_APP → $TENANT_DOMAIN"
info "  Backend port:   $BACKEND_PORT"
info "  Frontend port:  $FRONTEND_PORT"
info "  Storage:        $STORAGE_ROOT/$TENANT_NAME/{uploads,data}"
if ! $NO_DATABASE; then
    info "  Database:       MySQL → tenant_${TENANT_NAME} on ${MYSQL_HOST:-127.0.0.1}"
else
    info "  Database:       skipped (--no-database)"
fi
if [ -n "$BACKEND_IMAGE" ]; then
    info "  Backend image:  $BACKEND_IMAGE"
fi
if [ -n "$FRONTEND_IMAGE" ]; then
    info "  Frontend image: $FRONTEND_IMAGE"
fi
if $GIT_ONLY; then
    info "  Deploy method:  git push (no image deploy now)"
fi
for ev in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    info "  Env var:        $ev"
done
echo ""

if $DRY_RUN; then
    warn "Dry run — no changes made."
    exit 0
fi

# =============================================================================
# PROVISION
# =============================================================================

# ---- 1. Create Dokku apps ----
log "Creating backend app: $BACKEND_APP"
dokku apps:create "$BACKEND_APP"

log "Creating frontend app: $FRONTEND_APP"
dokku apps:create "$FRONTEND_APP"

# ---- 2. Set domains ----
log "Configuring domains..."
# Remove default domain, set tenant subdomain
dokku domains:clear "$BACKEND_APP"
dokku domains:add "$BACKEND_APP" "$TENANT_DOMAIN"

dokku domains:clear "$FRONTEND_APP"
dokku domains:add "$FRONTEND_APP" "$TENANT_DOMAIN"

# ---- 3. Configure nginx routing ----
# Backend handles /api/* , frontend handles everything else
log "Configuring URL routing..."

# Backend: /api prefix
dokku nginx:set "$BACKEND_APP" proxy-buffer-size "128k"

# Create custom nginx config for path-based routing
# Frontend is the main app, backend is proxied at /api
dokku_shell "mkdir -p /home/dokku/${FRONTEND_APP}/nginx.conf.d"
docker exec -i dokku bash -c "cat > /home/dokku/${FRONTEND_APP}/nginx.conf.d/api-proxy.conf" <<NGINX_CONF
# Proxy /api requests to the backend app
location /api {
    proxy_pass http://${BACKEND_APP}-web:${BACKEND_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Request-Start "t=\${msec}";
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_read_timeout 300s;
}
NGINX_CONF
dokku_shell "chown -R dokku:dokku /home/dokku/${FRONTEND_APP}/nginx.conf.d"

# ---- 4. Set ports ----
NGINX_MODE="${NGINX_MODE:-standalone}"
DOKKU_PORT="${DOKKU_PORT:-8080}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/dokku-tenants}"

if [ "$NGINX_MODE" = "behind-nginx" ]; then
    LISTEN_PORT="$DOKKU_PORT"
else
    LISTEN_PORT=80
fi

log "Setting container ports..."
dokku ports:set "$BACKEND_APP" "http:${LISTEN_PORT}:${BACKEND_PORT}"
dokku ports:set "$FRONTEND_APP" "http:${LISTEN_PORT}:${FRONTEND_PORT}"

# ---- 5. Persistent storage ----
log "Creating persistent storage..."
mkdir -p "$STORAGE_ROOT/$TENANT_NAME/uploads"
mkdir -p "$STORAGE_ROOT/$TENANT_NAME/data"
chown -R 32767:32767 "$STORAGE_ROOT/$TENANT_NAME" 2>/dev/null || true

dokku storage:mount "$BACKEND_APP" "$STORAGE_ROOT/$TENANT_NAME/uploads:/app/uploads"
dokku storage:mount "$BACKEND_APP" "$STORAGE_ROOT/$TENANT_NAME/data:/app/data"

# ---- 6. Environment variables ----
log "Setting environment variables..."
dokku config:set --no-restart "$BACKEND_APP" \
    TENANT_ID="$TENANT_NAME" \
    NODE_ENV=production

# Determine protocol based on SSL setting
PROTOCOL="http"
if [ "$NGINX_MODE" = "standalone" ] && [ "${ENABLE_SSL:-false}" = "true" ]; then
    PROTOCOL="https"
fi

dokku config:set --no-restart "$FRONTEND_APP" \
    TENANT_ID="$TENANT_NAME" \
    API_URL="${PROTOCOL}://$TENANT_DOMAIN/api"

# Message service (if configured)
MSG_HOST="${MSG_HOST:-}"
MSG_PORT="${MSG_PORT:-}"
if [ -n "$MSG_HOST" ]; then
    log "Configuring message service: $MSG_HOST:${MSG_PORT:-default}"
    dokku config:set --no-restart "$BACKEND_APP" \
        MSG_HOST="$MSG_HOST" \
        ${MSG_PORT:+MSG_PORT="$MSG_PORT"}
fi

# Docker host access — ensure containers can reach host services
dokku docker-options:add "$BACKEND_APP" deploy,run "--add-host=host.docker.internal:host-gateway" 2>/dev/null || true

# User-provided env vars
for ev in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    if [[ "$ev" == *"="* ]]; then
        dokku config:set --no-restart "$BACKEND_APP" "$ev"
    fi
done

# ---- 7. External MySQL database ----
MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"
# Restrict tenant DB users to the docker bridge subnet (defaults to 172.%).
# Override with MYSQL_TENANT_HOST in config.env if your bridge is elsewhere.
MYSQL_TENANT_HOST="${MYSQL_TENANT_HOST:-172.%}"

TENANT_DB_NAME="tenant_${TENANT_NAME//-/_}"
TENANT_DB_USER="usr_${TENANT_NAME//-/_}"

if ! $NO_DATABASE; then
    if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ "$MYSQL_ROOT_PASSWORD" = "changeme" ]; then
        warn "MYSQL_ROOT_PASSWORD not set in config.env — skipping database creation."
    else
        # Generate a random password for the tenant DB user
        TENANT_DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)

        log "Creating MySQL database: $TENANT_DB_NAME (user: $TENANT_DB_USER@'$MYSQL_TENANT_HOST')"
        run_mysql <<SQLEOF
CREATE DATABASE IF NOT EXISTS \`${TENANT_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}' IDENTIFIED BY '${TENANT_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${TENANT_DB_NAME}\`.* TO '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}';
FLUSH PRIVILEGES;
SQLEOF

        # Register in master database
        log "Registering tenant in master database..."
        run_mysql "$MYSQL_MASTER_DB" <<SQLEOF
INSERT INTO tenant (name, db_name)
VALUES ('${TENANT_NAME}', '${TENANT_DB_NAME}')
ON DUPLICATE KEY UPDATE enabled=1;
SQLEOF

        # Inject DATABASE_URL into the backend container
        DATABASE_URL="mysql://${TENANT_DB_USER}:${TENANT_DB_PASS}@${MYSQL_HOST}:${MYSQL_PORT}/${TENANT_DB_NAME}"
        dokku config:set --no-restart "$BACKEND_APP" \
            DATABASE_URL="$DATABASE_URL" \
            DB_HOST="$MYSQL_HOST" \
            DB_PORT="$MYSQL_PORT" \
            DB_NAME="$TENANT_DB_NAME" \
            DB_USER="$TENANT_DB_USER" \
            DB_PASSWORD="$TENANT_DB_PASS"

        log "Database ready: $TENANT_DB_NAME"
    fi
fi

# ---- 8. Health checks ----
# Modern Dokku (>= 0.30) uses an app-root CHECKS file or app.json for HTTP
# path checks; the legacy `checks:set <app> web http-path=...` form was
# removed (only `wait-to-retire` is now valid for checks:set). We write a
# CHECKS file into each app's working dir on the dokku host so health checks
# are configured before first deploy.
log "Configuring health checks..."
dokku_shell "mkdir -p /home/dokku/${BACKEND_APP} && echo '/api/health' > /home/dokku/${BACKEND_APP}/CHECKS" || warn "could not seed backend CHECKS"
dokku_shell "mkdir -p /home/dokku/${FRONTEND_APP} && echo '/' > /home/dokku/${FRONTEND_APP}/CHECKS" || warn "could not seed frontend CHECKS"

# ---- 9. Deploy (if images provided) ----
if ! $GIT_ONLY; then
    if [ -n "$BACKEND_IMAGE" ]; then
        log "Deploying backend from image: $BACKEND_IMAGE"
        dokku git:from-image "$BACKEND_APP" "$BACKEND_IMAGE"
    else
        info "No backend image — deploy later with: git push dokku@${BASE_DOMAIN}:${BACKEND_APP} main"
    fi

    if [ -n "$FRONTEND_IMAGE" ]; then
        log "Deploying frontend from image: $FRONTEND_IMAGE"
        dokku git:from-image "$FRONTEND_APP" "$FRONTEND_IMAGE"
    else
        info "No frontend image — deploy later with: git push dokku@${BASE_DOMAIN}:${FRONTEND_APP} main"
    fi
fi

# ---- 10. SSL / External nginx ----
if [ "$NGINX_MODE" = "standalone" ] && [ "${ENABLE_SSL:-false}" = "true" ]; then
    if [ -n "$BACKEND_IMAGE" ] || [ -n "$FRONTEND_IMAGE" ]; then
        log "Enabling SSL via Let's Encrypt..."
        dokku letsencrypt:enable "$FRONTEND_APP" 2>/dev/null || warn "SSL setup deferred (app may need a deploy first)."
    fi
else
    info "ENABLE_SSL=false — skipping Let's Encrypt (HTTP only)."
fi

# ---- 11. Run database migration ----
if [ -n "$MIGRATE_CMD" ] && [ -n "$BACKEND_IMAGE" ]; then
    log "Running database migration: $MIGRATE_CMD"
    if dokku run "$BACKEND_APP" $MIGRATE_CMD; then
        log "Migration completed successfully."
    else
        warn "Migration failed. You may need to run it manually:"
        warn "  dokku run $BACKEND_APP $MIGRATE_CMD"
    fi
elif [ -n "$MIGRATE_CMD" ] && [ -z "$BACKEND_IMAGE" ]; then
    warn "--migrate specified but no backend image deployed yet. Skipping migration."
    warn "Run manually after deploy: dokku run $BACKEND_APP $MIGRATE_CMD"
fi

# ---- Done ----
echo ""
log "============================================"
log "  Tenant '$TENANT_NAME' created!"
log ""
log "  Frontend: ${PROTOCOL}://${TENANT_DOMAIN}"
log "  API:      ${PROTOCOL}://${TENANT_DOMAIN}/api"
log "  Storage:  ${STORAGE_ROOT}/${TENANT_NAME}/"
log ""
log "  Dashboard: http://localhost:8088 (Apps page)"
log "  View logs:  dokku logs ${BACKEND_APP} --tail"
log "  Status:     dokku ps:report ${BACKEND_APP}"
log "============================================"
echo ""
