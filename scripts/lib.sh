#!/usr/bin/env bash
# =============================================================================
# lib.sh — Shared helpers
# =============================================================================
# Uses host mysql/mysqldump if available, otherwise falls back to Docker.
# Dokku always runs as a Docker container.
#
# Source this file in scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# =============================================================================

# Detect whether this shell should use a local mysql client or a mysql helper
# container. MYSQL_CLIENT_MODE=docker is used by the dashboard runner so MySQL
# grants scoped to Docker bridge clients keep working even if the runner image
# happens to include a mysql binary.
case "${MYSQL_CLIENT_MODE:-auto}" in
    host|docker) _MYSQL_VIA="$MYSQL_CLIENT_MODE" ;;
    auto|"")
        if command -v mysql &>/dev/null; then
            _MYSQL_VIA="host"
        else
            _MYSQL_VIA="docker"
        fi
        ;;
    *)
        echo "[!] Unknown MYSQL_CLIENT_MODE='${MYSQL_CLIENT_MODE}'; using auto detection." >&2
        if command -v mysql &>/dev/null; then
            _MYSQL_VIA="host"
        else
            _MYSQL_VIA="docker"
        fi
        ;;
esac

# Resolve the MySQL host for the *current* execution context.
# `host.docker.internal` is a Docker-only DNS name and does NOT resolve on
# the host itself, so when we shell out to the host's mysql client we must
# translate it to a loopback address. Inside a container the original name
# is preserved (with `--add-host=host.docker.internal:host-gateway`).
_resolve_mysql_host() {
    local h="${1:-${MYSQL_HOST:-127.0.0.1}}"
    case "$h" in
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
        *) echo "$h" ;;
    esac
}

# Hostname to inject into app containers. A container's localhost is the app
# container itself, so local host aliases must become Docker's host gateway.
mysql_host_for_container() {
    local h="${1:-${MYSQL_HOST:-host.docker.internal}}"
    case "$h" in
        localhost|127.0.0.1|::1) echo "host.docker.internal" ;;
        *) echo "$h" ;;
    esac
}

sanitize_tenant_name() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/^-*//;s/-*$//'
}

tenant_name_prefix() {
    local prefix
    prefix="$(sanitize_tenant_name "${TENANT_NAME_PREFIX_OVERRIDE:-${TENANT_NAME_PREFIX:-}}")"
    [ -z "$prefix" ] && return 0
    case "$prefix" in
        *-) printf '%s' "$prefix" ;;
        *)  printf '%s-' "$prefix" ;;
    esac
}

tenant_full_name() {
    local tenant prefix
    tenant="$(sanitize_tenant_name "$1")"
    prefix="$(tenant_name_prefix)"
    if [ -n "$prefix" ] && [[ "$tenant" != "$prefix"* ]]; then
        tenant="${prefix}${tenant}"
    fi
    if [ -z "$tenant" ] || [ ${#tenant} -gt 63 ]; then
        echo "Invalid tenant name after applying TENANT_NAME_PREFIX: $tenant" >&2
        return 1
    fi
    printf '%s' "$tenant"
}

tenant_in_scope() {
    local tenant prefix
    tenant="$(sanitize_tenant_name "$1")"
    prefix="$(tenant_name_prefix)"
    [ -z "$prefix" ] || [[ "$tenant" == "$prefix"* ]]
}

tenant_from_app_name() {
    local app="$1"
    case "$app" in
        *-backend)  printf '%s' "${app%-backend}" ;;
        *-frontend) printf '%s' "${app%-frontend}" ;;
        *)          printf '%s' "$app" ;;
    esac
}

# MySQL client (supports stdin/heredocs)
run_mysql() {
    local host
    host="$(_resolve_mysql_host)"
    if [ "$_MYSQL_VIA" = "host" ]; then
        MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-}" \
            mysql --protocol=TCP -h "$host" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_ROOT_USER:-root}" "$@"
    else
        docker run --rm -i \
            --add-host=host.docker.internal:host-gateway \
            -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD:-}" \
            mysql:8.0 \
            mysql --protocol=TCP -h "$host" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_ROOT_USER:-root}" "$@"
    fi
}

# mysqldump (stdout flows to host for piping)
run_mysqldump() {
    local host
    host="$(_resolve_mysql_host)"
    if [ "$_MYSQL_VIA" = "host" ]; then
        MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-}" \
            mysqldump --protocol=TCP -h "$host" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_ROOT_USER:-root}" "$@"
    else
        docker run --rm \
            --add-host=host.docker.internal:host-gateway \
            -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD:-}" \
            mysql:8.0 \
            mysqldump --protocol=TCP -h "$host" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_ROOT_USER:-root}" "$@"
    fi
}

# Ensure the Dokku container exists and is running. If it's missing or
# stopped, try to (re)create / start it via setup-dokku.sh, sourcing
# install.env / config.env first so DOKKU_PORT and DOKKU_HOSTNAME come from
# the operator's configuration. On failure, dump the last 200 lines of
# `docker logs dokku` so the caller doesn't have to dig for the reason.
#
# Idempotent and cheap: a running container short-circuits in O(1).
ensure_dokku_running() {
    [ -n "${_DOKKU_ENSURED:-}" ] && return 0
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'dokku'; then
        export _DOKKU_ENSURED=1
        return 0
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_dir
    repo_dir="$(dirname "$script_dir")"

    # Source config.env first then install.env so the operator's install.env
    # wins over the auto-generated config.env (matches setup-dokku.sh).
    local f
    for f in "$repo_dir/config.env" "$repo_dir/install.env"; do
        if [ -f "$f" ]; then
            # shellcheck disable=SC1090
            set -a; . "$f"; set +a
        fi
    done

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'dokku'; then
        echo "[+] dokku container exists but is not running — starting it..." >&2
        if docker start dokku >/dev/null 2>&1; then
            export _DOKKU_ENSURED=1
            return 0
        fi
        echo "[✗] Failed to start existing dokku container. Last 200 log lines:" >&2
        docker logs --tail 200 dokku 2>&1 | sed 's/^/    /' >&2
        return 1
    fi

    echo "[+] dokku container not found — bootstrapping via setup-dokku.sh" >&2
    if ! bash "$script_dir/setup-dokku.sh" >&2; then
        echo "[✗] setup-dokku.sh failed. Last 200 log lines from dokku container (if any):" >&2
        docker logs --tail 200 dokku 2>&1 | sed 's/^/    /' >&2 || true
        return 1
    fi
    export _DOKKU_ENSURED=1
    return 0
}

# Run a shell command inside the Dokku container
dokku_shell() {
    ensure_dokku_running || return 1
    _dokku_fix_hostname
    docker exec -i dokku bash -c "$*"
}

# Wrapper for the `dokku` CLI. Dokku always runs as a Docker container in this
# setup; defining this as a shell function means every script that sources
# lib.sh gets a working `dokku` even when /usr/local/bin/dokku is missing
# (e.g. setup.sh died before it wrote the wrapper, or PATH is sanitized by
# sudo). The function takes precedence over any binary on PATH within this
# shell, so behavior stays consistent across hosts.
dokku() {
    ensure_dokku_running || return 1
    _dokku_fix_hostname
    docker exec -i dokku dokku "$@"
}

# Deploy an app from a Docker image. Dokku's git:from-image returns non-zero
# when the image reference string did not change, even if the tag was re-pushed
# and already pulled locally. In that case, rebuild the existing image source so
# same-version rollouts are still deployable.
dokku_git_from_image() {
    local app="$1" image="$2" out rc
    if out="$(dokku git:from-image "$app" "$image" 2>&1)"; then
        printf '%s\n' "$out"
        return 0
    fi
    rc=$?
    printf '%s\n' "$out"
    if printf '%s\n' "$out" | grep -qi 'No changes detected'; then
        echo "[!] No source image ref change for $app; rebuilding existing Dokku image source." >&2
        dokku ps:rebuild "$app"
        return $?
    fi
    return "$rc"
}

# Silence the harmless but noisy "sudo: unable to resolve host <containerid>"
# warning that Dokku's internal sudo calls produce when the dokku container
# was started without --hostname. Idempotent: only writes /etc/hosts once per
# shell, and only if the entry is actually missing inside the container.
_dokku_fix_hostname() {
    [ -n "${_DOKKU_HOSTS_FIXED:-}" ] && return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^dokku$' || return 0
    local h
    h=$(docker exec dokku hostname 2>/dev/null) || return 0
    [ -n "$h" ] || return 0
    if ! docker exec dokku grep -q "[[:space:]]${h}\$" /etc/hosts 2>/dev/null; then
        docker exec -u root dokku sh -c "echo '127.0.1.1 ${h}' >> /etc/hosts" 2>/dev/null || true
    fi
    export _DOKKU_HOSTS_FIXED=1
}

# =============================================================================
# Host port allocation (used in NGINX_MODE=behind-nginx)
# =============================================================================
# _collect_used_ports
#   Prints, one per line, every TCP port we want to avoid when allocating a
#   new host-side port for a tenant app:
#     1. Host-side ports already mapped by any existing Dokku app
#     2. Ports currently listening on this host (best-effort; the dashboard
#        sidecar's network namespace may differ from the real host, but Dokku
#        port-map dedup is the critical invariant)
_collect_used_ports() {
    local apps app
    apps="$(dokku --quiet apps:list 2>/dev/null || true)"
    for app in $apps; do
        # `dokku ports:report <app> --proxy-port-map` returns
        #   "http:18000:8000 https:18443:8000 ..."
        dokku ports:report "$app" --proxy-port-map 2>/dev/null \
            | tr ' ' '\n' \
            | awk -F: '/^[a-zA-Z]+:[0-9]+:[0-9]+$/ {print $2}'
    done
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}'
    elif command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | awk 'NR>2 {n=split($4,a,":"); print a[n]}'
    fi
}

# allocate_host_port <range_start> <range_end> [exclude_csv]
#   Echoes the lowest free port in [range_start, range_end] not in the used
#   set or in the comma-separated exclusion list. Returns 1 if none free.
allocate_host_port() {
    local start="$1" end="$2" exclude_csv="${3:-}"
    local used p x skip
    used="$(_collect_used_ports | sort -un)"
    for ((p=start; p<=end; p++)); do
        if echo "$used" | grep -qx "$p"; then continue; fi
        skip=0
        if [ -n "$exclude_csv" ]; then
            local IFS=','
            for x in $exclude_csv; do
                if [ "$x" = "$p" ]; then skip=1; break; fi
            done
        fi
        [ "$skip" -eq 1 ] && continue
        echo "$p"
        return 0
    done
    return 1
}

# Get remote Docker Hub image digest (public, anonymous)
get_remote_digest() {
    local image="$1"
    local tag="${2:-latest}"
    local repo="$image"
    [[ "$repo" != *"/"* ]] && repo="library/$repo"

    local token
    token=$(curl -sf "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | \
        grep -o '"token":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
    [ -z "$token" ] && return 1

    curl -sf -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        -I "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" 2>/dev/null | \
        grep -i "docker-content-digest" | awk '{print $2}' | tr -d '\r'
}
