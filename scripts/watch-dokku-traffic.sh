#!/usr/bin/env bash
# Watch traffic hitting Dokku's nginx, prefixed with the tenant (vhost) name.
# Useful for confirming that traffic for *.<base-domain> is actually reaching
# the right backend.
#
# Per-vhost access log : /var/log/nginx/<app>-access.log   (matched server block)
# Default log          : /var/log/nginx/access.log         (no server block matched)
set -euo pipefail

CONTAINER="${DOKKU_CONTAINER:-dokku}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[!] dokku container '$CONTAINER' not running"; exit 1
fi

echo "[+] tailing Dokku nginx logs in container '$CONTAINER' (Ctrl-C to stop)"
echo "    format: <tenant> | <client> - <user> [<time>] \"<method> <path> <proto>\" <status> ..."
echo

# Pick only regular log files (skip symlinks like access.log -> /dev/stdout
# in some base images, which would make tail -F exit immediately).
# tail -F -v prints "==> file <==" headers; awk turns each header into a
# per-line prefix. (default) is the catch-all log when no vhost matched.
docker exec "$CONTAINER" sh -c '
    cd /var/log/nginx 2>/dev/null || { echo "[!] /var/log/nginx missing in container" >&2; exit 1; }
    files=""
    for f in access.log *-access.log; do
        [ -f "$f" ] && [ ! -L "$f" ] && files="$files $f"
    done
    if [ -z "$files" ]; then
        echo "[!] no nginx access logs found in $CONTAINER:/var/log/nginx" >&2
        exit 1
    fi
    exec tail -n 0 -F -v $files
' | awk '
    /^==> .* <==$/ {
        f = $0
        sub(/^==> /, "", f); sub(/ <==$/, "", f)
        sub(/-access\.log$/, "", f)
        sub(/^access\.log$/, "(default)", f)
        prefix = f
        next
    }
    NF > 0 { printf "%-20s | %s\n", prefix, $0; fflush() }
'
