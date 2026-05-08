#!/usr/bin/env bash
# Discover where Dokku's nginx is reachable from the host, and print a ready-to-use
# upstream-nginx server block that proxies *.<base-domain> to it.
#
# Strategy: probe every candidate address (published port, every bridge IP,
# host.docker.internal, 127.0.0.1) and pick the first that returns an HTTP
# status code. Even 502 means nginx answered.
set -euo pipefail

CONTAINER="${DOKKU_CONTAINER:-dokku}"
BASE_DOMAIN="${BASE_DOMAIN:-}"

have_dokku=0
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    have_dokku=1
fi

# Autodetect base domain from dokku.
if [ -z "$BASE_DOMAIN" ] && [ "$have_dokku" = 1 ]; then
    BASE_DOMAIN="$(docker exec "$CONTAINER" dokku domains:report --global 2>/dev/null \
        | awk -F': ' '/Domains global vhosts:/ {print $2; exit}' | awk '{print $1}')"
fi
BASE_DOMAIN="${BASE_DOMAIN:-dev.example.com}"
PROBE_HOST="tenant.${BASE_DOMAIN}"

# ---- Build candidate list (label|address) ----
candidates=()

if [ "$have_dokku" = 1 ]; then
    netmode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER" 2>/dev/null || echo '')"

    # Published port 80?
    pub80="$(docker port "$CONTAINER" 80/tcp 2>/dev/null | head -1 || true)"
    if [ -n "$pub80" ]; then
        port="${pub80##*:}"
        candidates+=("published-port|127.0.0.1:${port}")
    fi

    # Each bridge IP (works even when ports aren't published).
    while read -r net ip; do
        [ -n "${ip:-}" ] && candidates+=("network:${net}|${ip}:80")
    done < <(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{"\n"}}{{end}}' "$CONTAINER")

    if [ "$netmode" = "host" ]; then
        candidates+=("host-network|127.0.0.1:80")
    fi
fi

candidates+=("native-or-fallback|127.0.0.1:80")

# ---- Probe ----
echo "[+] Probing dokku nginx (Host: ${PROBE_HOST})"
working=""
for c in "${candidates[@]}"; do
    label="${c%%|*}"
    addr="${c#*|}"

    status=000
    if [ "$have_dokku" = 1 ]; then
        status="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
            --max-time 3 -H "Host: ${PROBE_HOST}" "http://${addr}/" 2>/dev/null || echo 000)"
    fi
    if [ "$status" = "000" ]; then
        status="$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time 3 -H "Host: ${PROBE_HOST}" "http://${addr}/" 2>/dev/null || echo 000)"
    fi

    if [ "$status" != "000" ]; then
        echo "    [OK]  ${label}  http://${addr}  ->  HTTP ${status}"
        [ -z "$working" ] && working="$addr"
    else
        echo "    [--]  ${label}  http://${addr}  (no response)"
    fi
done
echo

if [ -z "$working" ]; then
    cat <<MSG
[!] No candidate answered. On the host, check:
    docker ps                       # is dokku running?
    docker inspect $CONTAINER       # bridge IP / published ports
    docker exec $CONTAINER ss -tlnp # nginx listening?
MSG
    exit 1
fi

cat <<INFO
[+] Working target  : http://${working}
    base domain     : ${BASE_DOMAIN}

INFO

cat <<NGINX
# ---- Edge nginx config (e.g. /etc/nginx/sites-available/${BASE_DOMAIN}-tenants.conf) ----
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
        proxy_pass http://${working};
    }
}
# Then:
#   sudo ln -sf /etc/nginx/sites-available/${BASE_DOMAIN}-tenants.conf /etc/nginx/sites-enabled/
#   sudo nginx -t && sudo systemctl reload nginx
# DNS: add wildcard A record  *.${BASE_DOMAIN}  ->  <this server's public IP>
NGINX
