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
    scripts/verify-zatca-environment.sh \
    scripts/create-tenant.sh scripts/remove-tenant.sh scripts/cleanup-broken-tenant.sh \
    scripts/restart-stack.sh scripts/setup-nats.sh scripts/deployctl.sh \
    scripts/update-tenant.sh scripts/deploy-all.sh scripts/tests/test-dokku-host-gateway.sh \
    || fail "changed deployment scripts do not pass shell syntax"
pass "shell syntax"

echo
echo "=== daemon Compose contract ==="
[ -f "$COMPOSE_FILE" ] || fail "daemon Compose overlay is missing"
grep -qF 'profiles: ["zatca"]' "$COMPOSE_FILE" || fail "daemon overlay is not opt-in"
grep -qF 'image: ${ZATCA_DAEMON_IMAGE:?ZATCA_DAEMON_IMAGE must be set}' "$COMPOSE_FILE" \
    || fail "daemon image is not required"
grep -qF 'pull_policy: missing' "$COMPOSE_FILE" \
    || fail "daemon Compose service does not prefer the refreshed local image"
grep -qF 'restart: unless-stopped' "$COMPOSE_FILE" || fail "restart recovery is not configured"
grep -qF '"${ZATCA_NATS_PORT:-4222}:4222"' "$COMPOSE_FILE" \
    || fail "daemon NATS client port is not published"
grep -qF '"127.0.0.1:${ZATCA_NATS_MONITOR_PORT:-8222}:8222"' "$COMPOSE_FILE" \
    || fail "daemon monitor is not loopback-only"
grep -qF 'ZATCA_NATS_DATA_ROOT:-/opt/zatca-nats}:/data/nats' "$COMPOSE_FILE" \
    || fail "JetStream storage is not persistent"
grep -qF 'DB_USER: ${ZATCA_DB_USER:?ZATCA_DB_USER must be set}' "$COMPOSE_FILE" \
    || fail "daemon DB user contract is missing"
grep -qF 'MASTER_DB: ${MYSQL_MASTER_DB:-zatca_master}' "$COMPOSE_FILE" \
    || fail "master DB contract is missing"
grep -qF 'TENANT_NAME_PREFIX: ${TENANT_NAME_PREFIX:-}' "$COMPOSE_FILE" \
    || fail "daemon Compose overlay does not forward TENANT_NAME_PREFIX"
grep -qF 'TENANT_DB_PREFIX: ${TENANT_DB_PREFIX:-}' "$COMPOSE_FILE" \
    || fail "daemon Compose overlay does not forward TENANT_DB_PREFIX"
grep -qF 'resolve_zatca_tenant_db_prefix' "$SETUP_SCRIPT" \
    || fail "daemon setup does not validate tenant DB prefix scoping"
grep -qF 'ENCRYPT_KEY: ${ZATCA_ENCRYPT_KEY:?ZATCA_ENCRYPT_KEY must be set}' "$COMPOSE_FILE" \
    || fail "daemon encryption key is not required"
grep -qF 'MONITOR_PASS: ${ZATCA_MONITOR_PASSWORD:?ZATCA_MONITOR_PASSWORD must be set}' "$COMPOSE_FILE" \
    || fail "daemon monitor password is not required"
grep -qF 'NATS_MONITOR_HOST: "0.0.0.0"' "$COMPOSE_FILE" \
    || fail "daemon monitor must bind 0.0.0.0 inside container for loopback host port forwarding"
grep -qF 'NATS_USER: "${NATS_USER:?NATS_USER must be set}"' "$COMPOSE_FILE" \
    || fail "daemon NATS user is not required"
grep -qF 'NATS_PASSWORD: "${NATS_PASSWORD:?NATS_PASSWORD must be set}"' "$COMPOSE_FILE" \
    || fail "daemon NATS password is not required"
grep -qF 'NATS_PRIVATE_NETWORK_ONLY: "${NATS_PRIVATE_NETWORK_ONLY:?NATS_PRIVATE_NETWORK_ONLY must be set}"' "$COMPOSE_FILE" \
    || fail "daemon private-network mode is not configurable"
grep -qF 'NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED: "${NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED:-false}"' "$COMPOSE_FILE" \
    || fail "daemon does not receive the private-firewall confirmation"
grep -qF 'NATS_SHARED_CREDENTIALS_ACKNOWLEDGED: "${NATS_SHARED_CREDENTIALS_ACKNOWLEDGED:-false}"' "$COMPOSE_FILE" \
    || fail "daemon does not receive the shared-credential acknowledgment"
grep -qF 'NATS_SHARED_CREDENTIALS_APPROVAL_ID: "${NATS_SHARED_CREDENTIALS_APPROVAL_ID:-}"' "$COMPOSE_FILE" \
    || fail "daemon does not receive the shared-credential approval reference"
grep -qF 'NATS_SHARED_CREDENTIALS_EXPIRES: "${NATS_SHARED_CREDENTIALS_EXPIRES:-}"' "$COMPOSE_FILE" \
    || fail "daemon does not receive the shared-credential approval expiry"
grep -qF 'NATS_MONITOR_PRIVATE_NETWORK_ONLY: "${NATS_PRIVATE_NETWORK_ONLY:?NATS_PRIVATE_NETWORK_ONLY must be set}"' "$COMPOSE_FILE" \
    || fail "monitor private-network mode is not configured"
grep -qF ': "${NATS_USER:?NATS_USER must be set in ${CONFIG_FILE}}"' "$SETUP_SCRIPT" \
    || fail "daemon setup does not require the shared NATS user"
grep -qF ': "${NATS_PASSWORD:?NATS_PASSWORD must be set in ${CONFIG_FILE}}"' "$SETUP_SCRIPT" \
    || fail "daemon setup does not require the shared NATS password"
grep -qF 'NATS_PRIVATE_NETWORK_ONLY=true' "$SETUP_SCRIPT" \
    || fail "daemon setup does not require private-network mode for plaintext NATS"
grep -qF 'validate_zatca_daemon_security_gates' "$SETUP_SCRIPT" \
    || fail "daemon setup does not enforce the trust/firewall approval gates"
grep -qF '"--nats-mode=embedded"' "$COMPOSE_FILE" \
    || fail "daemon NATS ownership mode is not explicit"
grep -qF '"--nats-monitor=8222"' "$COMPOSE_FILE" || fail "daemon monitor flag is not consumed"
grep -qF '"--nats-data=/data/nats"' "$COMPOSE_FILE" || fail "daemon data flag is not consumed"
if grep -qE -- '--xml-dir|ZATCA_XML_ROOT|--nats-url|NATS_URL' "$COMPOSE_FILE"; then
    fail "Compose forwards flags or storage wiring removed from the daemon contract"
fi
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
grep -qF 'ZATCA_NATS_DATA_ROOT' "$SETUP_SCRIPT" "$COMPOSE_FILE" \
    || fail "reload path does not retain JetStream volume contract"
if grep -qE 'XML_ROOT|xml-dir|zatca-xml' "$SETUP_SCRIPT" "$RELOAD_SCRIPT" "$COMPOSE_FILE"; then
    fail "reload path retains removed XML storage wiring"
fi
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
[ "$(bash scripts/deployctl.sh --plan setup verify)" = \
    "bash scripts/verify-zatca-environment.sh" ] || fail "setup verify mapping"
[ "$(bash scripts/deployctl.sh --plan stack verify)" = \
    "bash scripts/verify-zatca-environment.sh" ] || fail "stack verify mapping"
[ "$(bash scripts/deployctl.sh --plan --config /opt/deployment/config.env setup verify)" = \
    "bash scripts/verify-zatca-environment.sh --config /opt/deployment/config.env" ] \
    || fail "setup verify config forwarding"
[ "$(bash scripts/deployctl.sh --plan --config /opt/deployment/config.env setup zatca-health)" = \
    "bash scripts/health-zatca-daemon.sh --config /opt/deployment/config.env" ] \
    || fail "daemon config forwarding"
pass "deployctl mappings"

echo
echo "=== configuration contract ==="
grep -qF 'ZATCA_DAEMON_ENABLED=0' config.env.example \
    || fail "daemon opt-in is not documented in config example"
(
    set -a
    # shellcheck disable=SC1091
    source config.env.example
    set +a
    [ "${ZATCA_DAEMON_ENABLED:-}" = "0" ] \
        || fail "documented configuration does not keep the daemon disabled"
    [ -z "${NATS_USER:-}" ] && [ -z "${NATS_PASSWORD:-}" ] \
        || fail "documented defaults must not pass a partial NATS credential pair"
)
pass "documented defaults keep both NATS credentials empty while the daemon is disabled"
grep -qF 'NATS_PRIVATE_NETWORK_ONLY=true' config.env.example \
    || fail "private NATS mode is not documented in config example"
grep -qF 'NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED=false' config.env.example \
    || fail "private-network firewall gate is not closed by default"
grep -qF 'NATS_SHARED_CREDENTIALS_ACKNOWLEDGED=false' config.env.example \
    || fail "shared-credential approval gate is not closed by default"
grep -qF 'NATS_SHARED_CREDENTIALS_APPROVAL_ID=' config.env.example \
    || fail "shared-credential approval reference is not documented"
grep -qF 'NATS_SHARED_CREDENTIALS_EXPIRES=' config.env.example \
    || fail "shared-credential approval expiry is not documented"
grep -qFx 'NATS_URL=' config.env.example \
    || fail "backend NATS URL should be derived from the published port by default"
grep -qF 'NATS_PORT=4222' config.env.example \
    || fail "legacy NATS port is not documented"
for script in scripts/create-tenant.sh scripts/update-tenant.sh scripts/deploy-all.sh; do
    grep -qF 'prepare_backend_nats_credentials' "$script" \
        || fail "$script does not validate NATS credentials before rollout"
    grep -qF 'BACKEND_NATS_CREDENTIALS' "$script" \
        || fail "$script does not use the prepared NATS credential pair"
    grep -qF 'ensure_dokku_host_gateway' "$script" \
        || fail "$script does not ensure the backend host-gateway route"
done
echo
echo "=== backend NATS credential pair validation ==="
source scripts/lib.sh
NATS_USER=""
NATS_PASSWORD=""
ZATCA_DAEMON_ENABLED=0
if ! prepare_backend_nats_credentials; then
    fail "empty credentials should be accepted while the daemon is disabled"
fi
[ "${BACKEND_NATS_CREDENTIALS[0]}" = "NATS_USER=" ] &&
    [ "${BACKEND_NATS_CREDENTIALS[1]}" = "NATS_PASSWORD=" ] \
    || fail "disabled daemon did not prepare an empty credential pair"

NATS_USER=zatca_daemon
NATS_PASSWORD=""
if prepare_backend_nats_credentials; then
    fail "partial credentials should be rejected while the daemon is disabled"
fi

NATS_USER=""
NATS_PASSWORD=contract-password
ZATCA_DAEMON_ENABLED=1
if prepare_backend_nats_credentials; then
    fail "partial credentials should be rejected while the daemon is enabled"
fi

NATS_USER=""
NATS_PASSWORD=""
ZATCA_DAEMON_ENABLED=1
if prepare_backend_nats_credentials; then
    fail "enabled daemon should require a complete credential pair"
fi

NATS_USER=zatca_daemon
NATS_PASSWORD=contract-password
NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED=false
NATS_SHARED_CREDENTIALS_ACKNOWLEDGED=true
NATS_SHARED_CREDENTIALS_APPROVAL_ID=TEST-123
NATS_SHARED_CREDENTIALS_EXPIRES=2099-12-31
if prepare_backend_nats_credentials; then
    fail "daemon-enabled configuration without firewall confirmation was accepted"
fi

NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED=true
NATS_SHARED_CREDENTIALS_ACKNOWLEDGED=false
if prepare_backend_nats_credentials; then
    fail "daemon-enabled configuration without trust acknowledgment was accepted"
fi

NATS_SHARED_CREDENTIALS_ACKNOWLEDGED=true
NATS_SHARED_CREDENTIALS_APPROVAL_ID=""
if prepare_backend_nats_credentials; then
    fail "daemon-enabled configuration without approval reference was accepted"
fi

NATS_SHARED_CREDENTIALS_APPROVAL_ID=TEST-123
NATS_SHARED_CREDENTIALS_EXPIRES=2000-01-01
if prepare_backend_nats_credentials; then
    fail "daemon-enabled configuration with expired approval was accepted"
fi

NATS_SHARED_CREDENTIALS_EXPIRES=2099-12-31
if ! prepare_backend_nats_credentials; then
    fail "complete credentials and approved security gates should be accepted when the daemon is enabled"
fi
[ "${BACKEND_NATS_CREDENTIALS[0]}" = "NATS_USER=zatca_daemon" ] &&
    [ "${BACKEND_NATS_CREDENTIALS[1]}" = "NATS_PASSWORD=contract-password" ] \
    || fail "complete credentials were not prepared as a pair"
pass "credential pairing is validated without logging values"

echo
echo "=== backend NATS URL and published-port contract ==="
NATS_URL=""
ZATCA_NATS_PORT=4333
ZATCA_DAEMON_ENABLED=1
if ! prepare_backend_nats_url; then
    fail "an omitted NATS_URL should derive from ZATCA_NATS_PORT"
fi
[ "$BACKEND_NATS_URL" = "nats://host.docker.internal:4333" ] \
    || fail "derived backend NATS URL does not use the published port"

NATS_URL=nats://host.docker.internal:4222
if prepare_backend_nats_url; then
    fail "explicit NATS_URL port mismatch was accepted with the daemon enabled"
fi

NATS_URL=nats://external-nats:5222
ZATCA_DAEMON_ENABLED=0
if ! prepare_backend_nats_url; then
    fail "explicit external NATS URL should remain valid while the daemon is disabled"
fi
[ "$BACKEND_NATS_URL" = "nats://external-nats:5222" ] \
    || fail "explicit external NATS URL was changed"

NATS_URL=""
NATS_PORT=4555
ZATCA_NATS_PORT=4333
if ! prepare_backend_nats_url; then
    fail "legacy NATS mode should derive the URL from NATS_PORT"
fi
[ "$BACKEND_NATS_URL" = "nats://host.docker.internal:4555" ] \
    || fail "legacy NATS URL did not use NATS_PORT"
pass "backend NATS URL stays consistent with the daemon's published port"

if grep -qF 'ZATCA_XML_ROOT' config.env.example; then
    fail "config example documents removed XML storage wiring"
fi
grep -qF 'ZATCA_MAX_PENDING=1000' config.env.example \
    || fail "pending threshold is not documented"
grep -qF 'ZATCA_MAX_ACK_PENDING=100' config.env.example \
    || fail "ack-pending threshold is not documented"
if grep -qE 'ZATCA_MAX_WORKERS|MAX_WORKERS_PER_' config.env.example; then
    fail "config example claims unsupported worker limits"
fi
pass "configuration contract"
