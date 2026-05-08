#!/usr/bin/env bash
# Print the address an EDGE host nginx should proxy *.<base-domain> to,
# plus a copy-paste-ready server block.
#
# This repo's setup-dokku.sh ALWAYS runs the dokku container with:
#     docker run ... --name dokku -p ${DOKKU_PORT}:80 -p 443:443 ...
# with DOKKU_PORT defaulting to 8080. So when you run a host nginx in front
# (NGINX_MODE=behind-nginx), Dokku's HTTP is at  127.0.0.1:${DOKKU_PORT}.
#
# The script:
#   1. Reads DOKKU_PORT from install.env / config.env (falls back to 8080).
#   2. Reads BASE_DOMAIN from dokku itself (or env override).
#   3. Confirms dokku nginx really answers there.
#   4. Prints the edge-nginx server block.
set -euo pipefail

CONTAINER="${DOKKU_CONTAINER:-dokku}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# ---- 1. DOKKU_PORT ----
load_env() {
    local f="$1"
    [ -f "$f" ] || return 0
    # shellcheck disable=SC1090
    set -a; . "$f"; set +a
}
load_env "${REPO_DIR}/install.env"
load_env "${REPO_DIR}/config.env"
DOKKU_PORT="${DOKKU_PORT:-8080}"

# ---- 2. BASE_DOMAIN ----
if [ -z "${BASE_DOMAIN:-}" ] && docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    BASE_DOMAIN="$(docker exec "$CONTAINER" dokku domains:report --global 2>/dev/null \
        | awk -F': ' '/Domains global vhosts:/ {print $2; exit}' | awk '{print $1}')"
fi
BASE_DOMAIN="${BASE_DOMAIN:-dev.example.com}"

TARGET="127.0.0.1:${DOKKU_PORT}"
echo "[+] Edge nginx target  : http://${TARGET}"
echo "    base domain        : ${BASE_DOMAIN}"
echo "    (DOKKU_PORT from install.env / default 8080)"
echo

# ---- 3. Confirm ----
echo "[+] Probing ${TARGET} ..."
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
    -H "Host: tenant.${BASE_DOMAIN}" "http://${TARGET}/" 2>/dev/null || echo 000)"
case "$status" in
    000)
        echo "    ! No response. Check that the dokku container is running and"
        echo "      that 'docker port ${CONTAINER} 80/tcp' shows '0.0.0.0:${DOKKU_PORT}'."
        echo "      If it shows a different host port, set DOKKU_PORT in install.env."
        ;;
    *)
        # Find what 'Server' header is — should be 'nginx' from dokku, NOT the host nginx.
        srv="$(curl -s -o /dev/null -D - --max-time 3 \
            -H "Host: tenant.${BASE_DOMAIN}" "http://${TARGET}/" 2>/dev/null \
            | awk -F': ' 'tolower($1)=="server"{gsub(/\r/,"",$2); print $2; exit}')"
        echo "    HTTP ${status}   Server: ${srv:-<none>}"
        echo "    (any HTTP code means dokku nginx answered — including 502 for an unknown tenant)"
        ;;
esac
echo

# ---- 4. Edge nginx block ----
cat <<NGINX
# ---- Add to your edge nginx (e.g. /etc/nginx/sites-available/${BASE_DOMAIN}-tenants.conf) ----
# This catches ONLY tenant subdomains. Your existing ${BASE_DOMAIN} server
# block stays untouched (nginx prefers exact server_name over wildcards).
server {
    listen 80;
    listen [::]:80;
    server_name *.${BASE_DOMAIN};

    client_max_body_size 50m;

    proxy_http_version 1.1;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade           \$http_upgrade;
    proxy_set_header Connection        \$http_connection;

    proxy_buffer_size       128k;
    proxy_buffers           4 256k;
    proxy_busy_buffers_size 256k;
    proxy_read_timeout      300s;

    location / {
        proxy_pass http://${TARGET};
    }
}
# Then:
#   sudo ln -sf /etc/nginx/sites-available/${BASE_DOMAIN}-tenants.conf /etc/nginx/sites-enabled/
#   sudo nginx -t && sudo systemctl reload nginx
# DNS: add wildcard A record  *.${BASE_DOMAIN}  ->  <this server's public IP>
NGINX
