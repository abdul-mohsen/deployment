#!/usr/bin/env bash
# =============================================================================
# create-tenant.sh — Provision a new tenant on Dokku
# =============================================================================
# Creates a complete tenant with:
#   - Backend app (API) at <tenant>.<domain>/api
#   - Frontend app at <tenant>.<domain>
#   - Persistent storage for uploads/data
#   - Health checks and auto-restart
#
# TLS is NOT handled here. The host nginx in front of Dokku is owned by the
# operator and is expected to terminate TLS and forward plain HTTP to
# 127.0.0.1:DOKKU_PORT with the original Host header preserved.
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
# ifritah-go listens on 8090; templates expose 8000 for the frontend.
BACKEND_PORT="8090"
FRONTEND_PORT="8000"
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

# ---- Logging: tee everything to a per-run log file -------------------------
# So we (and the dashboard) can read what happened after the fact.
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/create-tenant-${TENANT_NAME}-$(date +%Y%m%d-%H%M%S).log"
if [ -w "$LOG_DIR" ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Logging to: $LOG_FILE"
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
info "  Backend app:    $BACKEND_APP  → internal only (${BACKEND_APP}.web:${BACKEND_PORT})"
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
# The frontend owns the public tenant domain. The backend is reached only from
# the frontend over the per-tenant Docker network; giving both apps the same
# public domain makes Dokku generate duplicate nginx server_name blocks.
dokku domains:clear "$BACKEND_APP"

dokku domains:clear "$FRONTEND_APP"
dokku domains:add "$FRONTEND_APP" "$TENANT_DOMAIN"

# ---- 3. Inter-app networking ----
# /api routing happens INSIDE the frontend Go app (it reads BACKEND_URL and
# proxies HTTP itself). We do NOT write a Dokku nginx /api snippet here —
# referencing a sibling app from a custom nginx.conf.d snippet breaks
# `nginx:validate-config` (the upstream alias doesn't resolve from the
# dokku-nginx context), which silently blocks reloads for ALL tenants.
#
# Instead: attach both apps to a per-tenant docker network so the frontend
# container can reach the backend by Dokku's auto-alias "<app>.web".

DOKKU_PORT="${DOKKU_PORT:-8080}"
NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE:-50m}"
TENANT_NETWORK="tenant-${TENANT_NAME}"

log "Creating per-tenant docker network: $TENANT_NETWORK"
dokku network:create "$TENANT_NETWORK" 2>/dev/null || info "Network $TENANT_NETWORK already exists"

log "Attaching apps to $TENANT_NETWORK"
# Dokku 0.30+ rejects setting attach-post-create AND attach-post-deploy for the
# same network on the same app ("Network name already associated with this app").
# attach-post-create alone is enough: it attaches on container create which
# covers both image deploys (ps:rebuild) and git-push deploys.
dokku network:set "$BACKEND_APP"  attach-post-create "$TENANT_NETWORK"
dokku network:set "$FRONTEND_APP" attach-post-create "$TENANT_NETWORK"

# ---- 4. Set ports ----
# Dokku edge nginx listens on :80 inside its own network; host nginx (if any)
# just forwards to DOKKU_PORT.
LISTEN_PORT=80
log "Setting container ports (Dokku edge listens on :${LISTEN_PORT})..."
dokku ports:set "$BACKEND_APP"  "http:${LISTEN_PORT}:${BACKEND_PORT}"
dokku ports:set "$FRONTEND_APP" "http:${LISTEN_PORT}:${FRONTEND_PORT}"

log "Disabling public proxy for backend app (internal-only)..."
dokku proxy:disable "$BACKEND_APP" 2>/dev/null || true

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
    PORT="$BACKEND_PORT" \
    SERVER_PORT="$BACKEND_PORT" \
    NATS_URL="${NATS_URL:-nats://host.docker.internal:4222}" \
    BASEURL="${BASEURL:-/api/v2}" \
    JWT_SECERT_KEY="${JWT_SECERT_KEY:-$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)}"

# Public URL scheme is set by the operator's host nginx (TLS is external).
# Default to http; override with PUBLIC_PROTOCOL=https when host nginx terminates TLS.
PROTOCOL="${PUBLIC_PROTOCOL:-http}"

# Frontend speaks to backend over the per-tenant docker network. Dokku exposes
# each web container under the alias "<app>.web" inside attached networks.
dokku config:set --no-restart "$FRONTEND_APP" \
    TENANT_ID="$TENANT_NAME" \
    PORT="$FRONTEND_PORT" \
    APP_DOMAIN="$TENANT_DOMAIN" \
    BACKEND_URL="http://${BACKEND_APP}.web:${BACKEND_PORT}" \
    API_URL="${PROTOCOL}://${TENANT_DOMAIN}/api"

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
        # ALTER USER ensures the password matches what we just generated even
        # if the user already exists from a previous failed run.
        run_mysql <<SQLEOF
CREATE DATABASE IF NOT EXISTS \`${TENANT_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}' IDENTIFIED BY '${TENANT_DB_PASS}';
ALTER USER '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}' IDENTIFIED BY '${TENANT_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${TENANT_DB_NAME}\`.* TO '${TENANT_DB_USER}'@'${MYSQL_TENANT_HOST}';
SQLEOF

        # Register in master database
        log "Registering tenant in master database..."
        run_mysql "$MYSQL_MASTER_DB" <<SQLEOF
INSERT INTO tenant (name, db_name)
VALUES ('${TENANT_NAME}', '${TENANT_DB_NAME}')
ON DUPLICATE KEY UPDATE enabled=1;
SQLEOF

        # Inject DB env vars into the backend container.
        # Both naming conventions: modern (DB_HOST/DB_USER/...) and legacy
        # ifritah-go (HOST/DBUSER/PASSWORD/DBNAME — HOST is host:port).
        DATABASE_URL="mysql://${TENANT_DB_USER}:${TENANT_DB_PASS}@${MYSQL_HOST}:${MYSQL_PORT}/${TENANT_DB_NAME}"
        dokku config:set --no-restart "$BACKEND_APP" \
            DATABASE_URL="$DATABASE_URL" \
            DB_HOST="$MYSQL_HOST" \
            DB_PORT="$MYSQL_PORT" \
            DB_NAME="$TENANT_DB_NAME" \
            DB_USER="$TENANT_DB_USER" \
            DB_PASSWORD="$TENANT_DB_PASS" \
            HOST="${MYSQL_HOST}:${MYSQL_PORT}" \
            DBUSER="$TENANT_DB_USER" \
            PASSWORD="$TENANT_DB_PASS" \
            DBNAME="$TENANT_DB_NAME"

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

# ---- 10. External nginx ----
info "Host nginx (operator-managed) wildcards *.${BASE_DOMAIN} → 127.0.0.1:${DOKKU_PORT}; nothing to do per-tenant."
info "Verify once on the host that the wildcard vhost forwards with 'Host \$host' preserved, then: sudo nginx -t && sudo systemctl reload nginx"

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
log "  Routing: host nginx (operator-managed TLS) → 127.0.0.1:${DOKKU_PORT} → Dokku → ${TENANT_DOMAIN}"
log "  No per-tenant host port; Dokku routes by Host header."
log ""
log "  Dashboard: http://localhost:8088 (Apps page)"
log "  View logs:  dokku logs ${BACKEND_APP} --tail"
log "  Status:     dokku ps:report ${BACKEND_APP}"
log "============================================"
echo ""
