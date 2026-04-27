#!/usr/bin/env bash
# =============================================================================
# verify-mysql.sh — Quick check that MYSQL_ROOT_USER can connect from a container
# =============================================================================
# Reads credentials from install.env so nothing is typed on the command line.
# Run AFTER you've created the dokku_admin user in MySQL.
#
#   sudo bash scripts/verify-mysql.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_ENV="${INSTALL_ENV:-$PROJECT_DIR/install.env}"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"

if [ -f "$INSTALL_ENV" ]; then
    set -a; source "$INSTALL_ENV"; set +a
elif [ -f "$CONFIG_FILE" ]; then
    set -a; source "$CONFIG_FILE"; set +a
else
    echo "[!] Neither install.env nor config.env found." >&2
    exit 1
fi

: "${MYSQL_HOST:?MYSQL_HOST not set}"
: "${MYSQL_PORT:=3306}"
: "${MYSQL_ROOT_USER:?MYSQL_ROOT_USER not set}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD not set}"

# host.docker.internal is normally added on Docker Desktop. On Linux we add it
# explicitly so the container can reach the bridge gateway.
docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    mysql:8.0 \
    mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_ROOT_USER" \
        -e "SELECT user() AS connected_as, @@hostname AS server, @@version AS version;"
