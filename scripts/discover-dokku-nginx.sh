#!/usr/bin/env bash
# Discover where Dokku's nginx is reachable from the host, and print a ready-to-use
# upstream-nginx server block that proxies *.<base-domain> to it.
#
# Works whether dokku runs in a docker container (default in this repo) or natively.
set -euo pipefail

CONTAINER="${DOKKU_CONTAINER:-dokku}"
BASE_DOMAIN="${BASE_DOMAIN:-}"

# Try to autodetect base domain from Dokku itself.
if [ -z "$BASE_DOMAIN" ] && docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    BASE_DOMAIN="$(docker exec "$CONTAINER" dokku domains:report --global 2>/dev/null \
        | awk -F': ' '/Domains global vhosts:/ {print $2; exit}' | awk '{print $1}')"
fi
BASE_DOMAIN="${BASE_DOMAIN:-dev.example.com}"

mode=""
ip=""
port=""

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    # 1. Container IP on the default bridge.
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$CONTAINER" | awk '{print $1}')"

    # 2. Is port 80 published to the host?
    pub="$(docker port "$CONTAINER" 80/tcp 2>/dev/null | head -1 || true)"
    if [ -n "$pub" ]; then
        # e.g. "0.0.0.0:80" -> use 127.0.0.1
        port="${pub##*:}"
        host_target="127.0.0.1:${port}"
        mode="published-port"
    else
        port=80
        host_target="${ip}:80"
        mode="container-ip"
    fi
else
    # Native dokku — nginx runs on the host directly.
    host_target="127.0.0.1:80"
    port=80
    mode="native"
fi

echo "[+] Dokku nginx discovery"
echo "    container : $CONTAINER ($mode)"
[ -n "$ip" ]   && echo "    container IP : $ip"
echo "    proxy target : $host_target"
echo "    base domain  : $BASE_DOMAIN"
echo

# Sanity check: should answer with an HTTP status (404/200/whatever — anything but timeout).
echo "[+] curl test (Host: tenant.${BASE_DOMAIN})"
if status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: tenant.${BASE_DOMAIN}" "http://${host_target}/" 2>/dev/null)"; then
    echo "    HTTP $status   (any non-zero response means the address is reachable)"
else
    echo "    ! could not reach $host_target — fix this before adding the nginx block"
fi
echo

cat <<NGINX
# ---- Add this to your edge nginx (e.g. /etc/nginx/sites-available/${BASE_DOMAIN}-tenants.conf) ----
server {
    listen 80;
    listen [::]:80;
    server_name *.${BASE_DOMAIN};   # wildcard ONLY — does not touch ${BASE_DOMAIN}

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
        proxy_pass http://${host_target};
    }
}
# Then:
#   sudo ln -sf /etc/nginx/sites-available/${BASE_DOMAIN}-tenants.conf /etc/nginx/sites-enabled/
#   sudo nginx -t && sudo systemctl reload nginx
# DNS: add wildcard A record  *.${BASE_DOMAIN} -> <this server's public IP>
NGINX
