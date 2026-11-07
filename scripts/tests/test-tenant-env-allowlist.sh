#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-tenant-env-allowlist.sh â€” tenant env override contract
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

source scripts/lib.sh

assert_allowed() {
    local assignment="$1"
    validate_tenant_env_override "$assignment" >/dev/null 2>&1 ||
        fail "legitimate tenant env override was rejected: ${assignment%%=*}"
    pass "allows ${assignment%%=*}"
}

assert_rejected() {
    local assignment="$1" output
    if output="$(validate_tenant_env_override "$assignment" 2>&1)"; then
        fail "reserved or malformed tenant env override was accepted: ${assignment%%=*}"
    fi
    [ -n "$output" ] || fail "rejection did not explain ${assignment%%=*}"
    pass "rejects ${assignment%%=*}"
}

echo "=== syntax and wiring ==="
bash -n scripts/lib.sh scripts/create-tenant.sh scripts/init-tenant-db.sh scripts/update-tenant.sh
for script in scripts/create-tenant.sh scripts/update-tenant.sh scripts/init-tenant-db.sh; do
    grep -Fq 'validate_tenant_env_overrides' "$script" ||
        fail "$script does not validate --env overrides before use"
    pass "$script validates --env overrides"
done

echo
echo "=== legitimate tenant application keys ==="
assert_allowed "FEATURE_FLAG=enabled"
assert_allowed "ADMIN_PASSWORD=seed-password"
assert_allowed "JWT_SECERT_KEY=tenant-signing-key"

echo
echo "=== reserved deployment and tenant-connection keys ==="
for assignment in \
    "BASE_DOMAIN=evil.example" \
    "TENANT_ID=other-tenant" \
    "DATABASE_URL=mysql://user:pass@example.test/db" \
    "DB_HOST=host.docker.internal" \
    "DB_PORT=3306" \
    "DB_NAME=tenant_acme" \
    "DB_USER=usr_acme" \
    "DB_PASSWORD=tenant-password" \
    "HOST=host.docker.internal:3306" \
    "DBUSER=usr_acme" \
    "PASSWORD=tenant-password" \
    "DBNAME=tenant_acme" \
    "TENANT_KEY=other-tenant" \
    "MYSQL_ADMIN_PASSWORD=admin-secret" \
    "MIGRATION_DB_PASSWORD=migration-secret" \
    "MIGRATE_CMD=drop-everything" \
    "DOCKER_HOST=tcp://attacker:2375" \
    "DOCKERHUB_TOKEN=registry-secret" \
    "DOKKU_CONTAINER=other-dokku" \
    "OPENOBSERVE_TENANT_OTLP_TOKEN=telemetry-secret" \
    "OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic%20attacker" \
    "METRICS_TOKEN=telemetry-secret" \
    "NATS_URL=nats://unapproved-host:4222"; do
    assert_rejected "$assignment"
done

echo
echo "=== malformed keys ==="
assert_rejected "not-a-key=value"
assert_rejected "NO_EQUALS"

echo
echo "=== database and NATS configuration validation ==="
validate_database_identifier deployment_state
if validate_database_identifier 'deployment-state'; then
    fail "hyphenated database identifier was accepted"
fi
validate_nats_url nats://host.docker.internal:4222
validate_nats_url tls://nats.example.test
if validate_nats_url 'http://unapproved-host:4222'; then
    fail "non-NATS URL was accepted"
fi
if validate_nats_url 'nats://user:pass@host:4222'; then
    fail "credential-bearing NATS URL was accepted"
fi
pass "configuration overrides fail closed"

echo
echo "All tenant env allow-list checks passed."
