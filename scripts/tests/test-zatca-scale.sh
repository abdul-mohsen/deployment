#!/usr/bin/env bash
# Focused deployment contract for T033 tenant reload, worker bounds, and queue health.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

CREATE_SCRIPT="scripts/create-tenant.sh"
RELOAD_SCRIPT="scripts/reload-zatca-daemon.sh"
HEALTH_SCRIPT="scripts/health-zatca-daemon.sh"
SETUP_SCRIPT="scripts/setup-zatca-daemon.sh"
COMPOSE_FILE="dashboard/docker-compose.zatca.yml"

[ -f "$RELOAD_SCRIPT" ] || fail "tenant creation reload helper is missing"
[ -f "$HEALTH_SCRIPT" ] || fail "daemon queue-health helper is missing"

bash -n "$CREATE_SCRIPT" "$RELOAD_SCRIPT" "$HEALTH_SCRIPT" "$SETUP_SCRIPT" \
    || fail "changed deployment scripts do not pass shell syntax"
pass "T033 shell syntax"

grep -qF 'verify_zatca_tenant_registration' "$CREATE_SCRIPT" \
    || fail "tenant creation does not verify daemon registry access"
grep -qF 'reload-zatca-daemon.sh' "$CREATE_SCRIPT" \
    || fail "tenant creation does not trigger daemon reload"
grep -qF 'ZATCA_DAEMON_ENABLED' "$CREATE_SCRIPT" \
    || fail "tenant reload is not opt-in"
pass "tenant registration and opt-in reload contract"

grep -qF '/healthz' "$COMPOSE_FILE" \
    || fail "daemon readiness contract is missing"
grep -qF 'health-zatca-daemon.sh' "$SETUP_SCRIPT" \
    || fail "daemon setup does not gate on queue health"
grep -qF 'ZATCA' "$HEALTH_SCRIPT" \
    || fail "queue health does not select the ZATCA stream"
grep -qF '/jsz' "$HEALTH_SCRIPT" \
    || fail "queue health does not inspect JetStream state"
grep -qF '/jsz?accounts=true&streams=true&consumers=true' "$HEALTH_SCRIPT" \
    || fail "queue health does not request NATS account stream/consumer details"
grep -qF 'num_pending' "$HEALTH_SCRIPT" \
    || fail "queue health does not expose consumer pending state"
grep -qF 'num_ack_pending' "$HEALTH_SCRIPT" \
    || fail "queue health does not expose acknowledgement-pending state"
pass "readiness, stream, consumer, and pending health contract"

for key in \
    'ZATCA_MAX_WORKERS_PER_TENANT' \
    'ZATCA_MAX_WORKERS_PER_BRANCH' \
    'ZATCA_MAX_PENDING' \
    'ZATCA_MAX_ACK_PENDING'; do
    grep -qF "$key" "$COMPOSE_FILE" \
        || fail "compose overlay does not forward $key"
    grep -qF "$key" scripts/setup-zatca-daemon.sh \
        || fail "setup script does not validate $key"
done
for key in \
    'MAX_WORKERS_PER_TENANT' \
    'MAX_WORKERS_PER_BRANCH' \
    'MAX_PENDING' \
    'MAX_ACK_PENDING'; do
    grep -qF "$key" "$COMPOSE_FILE" \
        || fail "compose overlay does not map daemon input $key"
done
pass "finite worker and backlog bounds"

grep -qF 'profiles: ["zatca"]' "$COMPOSE_FILE" \
    || fail "T009 opt-in daemon profile was removed"
grep -qF 'restart: unless-stopped' "$COMPOSE_FILE" \
    || fail "T009 daemon restart policy was removed"
grep -qF '"${NATS_PORT:-4222}:4222"' "$COMPOSE_FILE" \
    || fail "T009 NATS client port contract was removed"
grep -qF '127.0.0.1:${NATS_MONITOR_PORT:-8222}:8222' "$COMPOSE_FILE" \
    || fail "T009 loopback monitor contract was removed"
pass "T009 service compatibility"

planned="$(bash scripts/deployctl.sh --plan setup zatca-health 2>/dev/null || true)"
[ "$planned" = "bash scripts/health-zatca-daemon.sh" ] \
    || fail "deployctl does not expose setup zatca-health"
pass "deployctl queue-health command"

pass "T033 deployment contract"
