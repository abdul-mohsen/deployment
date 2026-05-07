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

# Detect whether host has mysql client
if command -v mysql &>/dev/null; then
    _MYSQL_VIA="host"
else
    _MYSQL_VIA="docker"
fi

# MySQL client (supports stdin/heredocs)
run_mysql() {
    if [ "$_MYSQL_VIA" = "host" ]; then
        MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-}" \
            mysql -h "${MYSQL_HOST:-127.0.0.1}" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_ROOT_USER:-root}" "$@"
    else
        docker run --rm -i \
            --add-host=host.docker.internal:host-gateway \
            -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD:-}" \
            mysql:8.0 \
            mysql -h "${MYSQL_HOST:-host.docker.internal}" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_ROOT_USER:-root}" "$@"
    fi
}

# mysqldump (stdout flows to host for piping)
run_mysqldump() {
    if [ "$_MYSQL_VIA" = "host" ]; then
        MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-}" \
            mysqldump -h "${MYSQL_HOST:-127.0.0.1}" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_ROOT_USER:-root}" "$@"
    else
        docker run --rm \
            --add-host=host.docker.internal:host-gateway \
            -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD:-}" \
            mysql:8.0 \
            mysqldump -h "${MYSQL_HOST:-host.docker.internal}" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_ROOT_USER:-root}" "$@"
    fi
}

# Run a shell command inside the Dokku container
dokku_shell() {
    docker exec -i dokku bash -c "$*"
}

# Wrapper for the `dokku` CLI. Dokku always runs as a Docker container in this
# setup; defining this as a shell function means every script that sources
# lib.sh gets a working `dokku` even when /usr/local/bin/dokku is missing
# (e.g. setup.sh died before it wrote the wrapper, or PATH is sanitized by
# sudo). The function takes precedence over any binary on PATH within this
# shell, so behavior stays consistent across hosts.
dokku() {
    docker exec -i dokku dokku "$@"
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
