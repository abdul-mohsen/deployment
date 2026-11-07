#!/usr/bin/env bash
# Focused deployment contract for the daemon-owned runtime.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

COMPOSE_FILE="dashboard/docker-compose.zatca.yml"
SETUP_SCRIPT="scripts/setup-zatca-daemon.sh"
HEALTH_SCRIPT="scripts/health-zatca-daemon.sh"
RELOAD_SCRIPT="scripts/reload-zatca-daemon.sh"

echo "=== ZATCA runtime shell syntax ==="
bash -n "$SETUP_SCRIPT" "$HEALTH_SCRIPT" "$RELOAD_SCRIPT" \
    scripts/create-tenant.sh scripts/remove-tenant.sh scripts/cleanup-broken-tenant.sh \
    scripts/restart-stack.sh scripts/setup-nats.sh scripts/deployctl.sh \
    || fail "changed deployment scripts do not pass shell syntax"
pass "shell syntax"

echo
echo "=== daemon Compose contract ==="
[ -f "$COMPOSE_FILE" ] || fail "daemon Compose overlay is missing"
grep -qF 'profiles: ["zatca"]' "$COMPOSE_FILE" || fail "daemon overlay is not opt-in"
grep -qF 'image: ${ZATCA_DAEMON_IMAGE:?ZATCA_DAEMON_IMAGE must be set}' "$COMPOSE_FILE" \
    || fail "daemon image is not required"
grep -qF 'restart: unless-stopped' "$COMPOSE_FILE" || fail "restart recovery is not configured"
grep -qF '"${ZATCA_NATS_PORT:-4222}:4222"' "$COMPOSE_FILE" \
    || fail "daemon NATS client port is not published"
grep -qF '"127.0.0.1:${ZATCA_NATS_MONITOR_PORT:-8222}:8222"' "$COMPOSE_FILE" \
    || fail "daemon monitor is not loopback-only"
grep -qF 'ZATCA_XML_ROOT:-/opt/zatca-xml}:/data/zatca-xml' "$COMPOSE_FILE" \
    || fail "XML storage is not persistent"
grep -qF 'ZATCA_NATS_DATA_ROOT:-/opt/zatca-nats}:/data/nats' "$COMPOSE_FILE" \
    || fail "JetStream storage is not persistent"
grep -qF 'DB_USER: ${ZATCA_DB_USER:?ZATCA_DB_USER must be set}' "$COMPOSE_FILE" \
    || fail "daemon DB user contract is missing"
grep -qF 'MASTER_DB: ${MYSQL_MASTER_DB:-zatca_master}' "$COMPOSE_FILE" \
    || fail "master DB contract is missing"
grep -qF 'ENCRYPT_KEY: ${ZATCA_ENCRYPT_KEY:?ZATCA_ENCRYPT_KEY must be set}' "$COMPOSE_FILE" \
    || fail "daemon encryption key is not required"
grep -qF 'MONITOR_PASS: ${ZATCA_MONITOR_PASSWORD:?ZATCA_MONITOR_PASSWORD must be set}' "$COMPOSE_FILE" \
    || fail "daemon monitor password is not required"
grep -qF '"--nats-monitor=8222"' "$COMPOSE_FILE" || fail "daemon monitor flag is not consumed"
grep -qF '"--nats-data=/data/nats"' "$COMPOSE_FILE" || fail "daemon data flag is not consumed"
grep -qF '/healthz' "$COMPOSE_FILE" || fail "container readiness probe is missing"
if grep -qE 'MAX_WORKERS|MAX_PENDING|MAX_ACK_PENDING' "$COMPOSE_FILE"; then
    fail "Compose advertises limits the daemon does not consume"
fi
pass "Compose uses only the actual daemon contract"

echo
echo "=== readiness and reconciliation signals ==="
grep -qF '/jsz?accounts=true&streams=true&consumers=true' "$HEALTH_SCRIPT" \
    || fail "health script does not inspect JetStream consumers"
grep -qF 'fail-with-body' "$HEALTH_SCRIPT" \
    || fail "health script discards actionable daemon readiness failures"
grep -qF 'readiness_payload' "$HEALTH_SCRIPT" \
    || fail "health script does not preserve daemon readiness diagnostics"
grep -qF 'num_pending' "$HEALTH_SCRIPT" || fail "pending signal is missing"
grep -qF 'num_ack_pending' "$HEALTH_SCRIPT" || fail "ack-pending signal is missing"
grep -qF 'num_redelivered' "$HEALTH_SCRIPT" || fail "redelivery signal is missing"
grep -qF 'reconciliation_signal' "$HEALTH_SCRIPT" || fail "reconciliation signal is missing"
grep -qF 'ZATCA_MAX_PENDING' "$HEALTH_SCRIPT" || fail "pending threshold is not enforced"
grep -qF 'ZATCA_MAX_ACK_PENDING' "$HEALTH_SCRIPT" || fail "ack-pending threshold is not enforced"
if grep -qE 'MAX_WORKERS|MAX_PENDING|MAX_ACK_PENDING' "$SETUP_SCRIPT" "$COMPOSE_FILE"; then
    fail "daemon setup forwards unsupported worker/backlog environment knobs"
fi
pass "health and bounded queue signals"

echo
echo "=== tenant reload and recovery wiring ==="
grep -qF -- '--recreate' "$RELOAD_SCRIPT" || fail "reload does not recreate startup-loaded daemon"
grep -qF 'ZATCA_XML_ROOT' "$RELOAD_SCRIPT" "$SETUP_SCRIPT" "$COMPOSE_FILE" \
    || fail "reload path does not retain XML volume contract"
grep -qF 'ZATCA_NATS_DATA_ROOT' "$SETUP_SCRIPT" "$COMPOSE_FILE" \
    || fail "reload path does not retain JetStream volume contract"
grep -qF 'reload-zatca-daemon.sh' scripts/create-tenant.sh \
    || fail "tenant creation does not refresh daemon discovery"
grep -qF 'reload-zatca-daemon.sh' scripts/remove-tenant.sh \
    || fail "tenant removal does not refresh daemon discovery"
grep -qF 'reload-zatca-daemon.sh' scripts/cleanup-broken-tenant.sh \
    || fail "broken-tenant cleanup does not refresh daemon discovery"
grep -qF 'setup-zatca-daemon.sh' scripts/restart-stack.sh \
    || fail "stack restart does not recover the enabled daemon"
grep -qF 'ZATCA_DAEMON_ENABLED' scripts/setup-nats.sh \
    || fail "legacy NATS setup does not avoid a duplicate broker"
pass "reload and restart/recovery wiring"

echo
echo "=== deployctl command mapping ==="
[ "$(bash scripts/deployctl.sh --plan setup zatca-daemon)" = \
    "bash scripts/setup-zatca-daemon.sh" ] || fail "setup zatca-daemon mapping"
[ "$(bash scripts/deployctl.sh --plan setup zatca-health)" = \
    "bash scripts/health-zatca-daemon.sh" ] || fail "setup zatca-health mapping"
[ "$(bash scripts/deployctl.sh --plan setup zatca-reload)" = \
    "bash scripts/reload-zatca-daemon.sh" ] || fail "setup zatca-reload mapping"
[ "$(bash scripts/deployctl.sh --plan --config /opt/deployment/config.env setup zatca-health)" = \
    "bash scripts/health-zatca-daemon.sh --config /opt/deployment/config.env" ] \
    || fail "daemon config forwarding"
pass "deployctl mappings"

echo
echo "=== configuration contract ==="
grep -qF 'ZATCA_DAEMON_ENABLED=0' config.env.example \
    || fail "daemon opt-in is not documented in config example"
grep -qF 'ZATCA_MAX_PENDING=1000' config.env.example \
    || fail "pending threshold is not documented"
grep -qF 'ZATCA_MAX_ACK_PENDING=100' config.env.example \
    || fail "ack-pending threshold is not documented"
if grep -qE 'ZATCA_MAX_WORKERS|MAX_WORKERS_PER_' config.env.example; then
    fail "config example claims unsupported worker limits"
fi
pass "configuration contract"
