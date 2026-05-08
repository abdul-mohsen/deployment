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
    # 1. Container IP on the default bridge (empty if --network host).
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$CONTAINER" | awk '{print $1}')"

    # 2. Detect host networking explicitly.
    netmode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER" 2>/dev/null || echo '')"

    # 3. Is port 80 published to the host?
    pub="$(docker port "$CONTAINER" 80/tcp 2>/dev/null | head -1 || true)"

    if [ -n "$pub" ]; then
        port="${pub##*:}"
        host_target="127.0.0.1:${port}"
        mode="published-port"
    elif [ "$netmode" = "host" ] || [ -z "$ip" ]; then
        # Container shares the host network namespace -> nginx is on host's :80.
        host_target="127.0.0.1:80"
        port=80
        mode="host-network"
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

# Sanity check.
# We may be running INSIDE a container (the dashboard) — in that case 127.0.0.1
# means "this container", not the host. Try the dokku container itself first
# (it's always on the same network as the host's :80 when --network=host),
# then fall back to host.docker.internal.
echo "[+] curl test (Host: tenant.${BASE_DOMAIN})"
test_targets=()
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    test_targets+=("docker:exec ${CONTAINER}")
fi
test_targets+=("local:host.docker.internal:${port}" "local:${host_target}")

reached=""
for t in "${test_targets[@]}"; do
    case "$t" in
        docker:*)
            if status="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: tenant.${BASE_DOMAIN}" "http://127.0.0.1:${port}/" 2>/dev/null)" \
               && [ -n "$status" ] && [ "$status" != "000" ]; then
                echo "    HTTP $status   (from inside the dokku container -> 127.0.0.1:${port})"
                reached=1; break
            fi
            ;;
        local:*)
            addr="${t#local:}"
            if status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: tenant.${BASE_DOMAIN}" "http://${addr}/" 2>/dev/null)" \
               && [ -n "$status" ] && [ "$status" != "000" ]; then
                echo "    HTTP $status   (from this script's container -> ${addr})"
                reached=1; break
            fi
            ;;
    esac
done
[ -n "$reached" ] || echo "    ! could not reach Dokku nginx from any vantage point — but ${host_target} is still the right edge-nginx target on the host."
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
