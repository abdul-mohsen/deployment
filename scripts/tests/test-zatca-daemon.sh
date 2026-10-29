#!/usr/bin/env bash
# Focused deployment contract for the first-class ZATCA daemon service.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

COMPOSE_FILE="dashboard/docker-compose.zatca.yml"

[ -f "$COMPOSE_FILE" ] || fail "ZATCA daemon compose template is missing"
grep -qE '^  zatca-daemon:' "$COMPOSE_FILE" \
    || fail "compose template does not declare zatca-daemon"
grep -qF 'profiles: ["zatca"]' "$COMPOSE_FILE" \
    || fail "daemon overlay is not explicitly opt-in"
grep -qF 'image: ${ZATCA_DAEMON_IMAGE:?ZATCA_DAEMON_IMAGE must be set}' "$COMPOSE_FILE" \
    || fail "daemon image is not an operator-supplied required input"
grep -qF 'restart: unless-stopped' "$COMPOSE_FILE" \
    || fail "daemon restart policy is not unless-stopped"
grep -qF '"${NATS_PORT:-4222}:4222"' "$COMPOSE_FILE" \
    || fail "daemon does not publish its embedded NATS client port"
grep -qF 'ZATCA_XML_ROOT:-/opt/zatca-xml}:/data/zatca-xml' "$COMPOSE_FILE" \
    || fail "daemon XML storage is not persisted"
grep -qF 'ZATCA_NATS_DATA_ROOT:-/opt/zatca-nats}:/data/nats' "$COMPOSE_FILE" \
    || fail "daemon JetStream storage is not persisted"
grep -qF 'DB_HOST: ${MYSQL_HOST:-host.docker.internal}' "$COMPOSE_FILE" \
    || fail "daemon does not share configured MySQL host"
grep -qF 'MASTER_DB: ${MYSQL_MASTER_DB:-zatca_master}' "$COMPOSE_FILE" \
    || fail "daemon does not share configured master database"
grep -qF 'ENCRYPT_KEY: ${ZATCA_ENCRYPT_KEY:?ZATCA_ENCRYPT_KEY must be set}' "$COMPOSE_FILE" \
    || fail "daemon encryption key is not required through configuration"
grep -qF 'MONITOR_PASS: ${ZATCA_MONITOR_PASSWORD:?ZATCA_MONITOR_PASSWORD must be set}' "$COMPOSE_FILE" \
    || fail "daemon monitor password is not required through configuration"
grep -qF '/healthz' "$COMPOSE_FILE" \
    || fail "daemon readiness/health contract is missing"
grep -qF '"--nats-data=/data/nats"' "$COMPOSE_FILE" \
    || fail "daemon does not persist its embedded JetStream directory"
grep -qF '"--nats-monitor=8222"' "$COMPOSE_FILE" \
    || fail "daemon monitor port is not wired to the T008 runtime"
grep -qF 'NATS_URL="${NATS_URL:-${ZATCA_NATS_URL:-nats://host.docker.internal:4222}}"' scripts/create-tenant.sh \
    || fail "tenant backend does not use the daemon-owned NATS endpoint contract"
grep -qF 'NATS_URL: ${NATS_URL:-nats://host.docker.internal:4222}' templates/backend/docker-compose.yml \
    || fail "backend template does not document the shared NATS endpoint"
[ -f scripts/setup-zatca-daemon.sh ] \
    || fail "daemon lifecycle script is missing"
grep -qF 'setup-zatca-daemon.sh' scripts/deployctl.sh \
    || fail "deployctl does not expose daemon setup"
grep -qF 'start_zatca_daemon' scripts/restart-stack.sh \
    || fail "stack restart does not manage the enabled daemon"

pass "ZATCA daemon deployment contract"
