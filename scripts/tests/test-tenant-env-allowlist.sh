#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-tenant-env-allowlist.sh — tenant env override contract
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck disable=SC1091
source scripts/lib.sh

assert_allowed() {
    local assignment="$1"
    validate_tenant_env_override "$assignment" >/dev/null 2>&1 \
        || fail "legitimate tenant env override was rejected: ${assignment%%=*}"
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
bash -n scripts/lib.sh scripts/create-tenant.sh scripts/update-tenant.sh
for script in scripts/create-tenant.sh scripts/update-tenant.sh; do
    grep -Fq 'validate_tenant_env_overrides' "$script" \
        || fail "$script does not validate --env overrides before use"
    pass "$script validates --env overrides"
done

create_validation_line="$(grep -n 'validate_tenant_env_overrides' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
create_dokku_line="$(grep -n 'create_dokku_app "\$BACKEND_APP"' scripts/create-tenant.sh | head -1 | cut -d: -f1)"
[ "$create_validation_line" -lt "$create_dokku_line" ] \
    || fail "create-tenant validates --env after creating a Dokku app"
pass "create-tenant validates before Dokku side effects"

update_validation_line="$(grep -n 'validate_tenant_env_overrides' scripts/update-tenant.sh | head -1 | cut -d: -f1)"
update_routing_line="$(grep -n 'reconcile_tenant_routing "\$TENANT_NAME"' scripts/update-tenant.sh | head -1 | cut -d: -f1)"
[ "$update_validation_line" -lt "$update_routing_line" ] \
    || fail "update-tenant validates --env after routing reconciliation"
pass "update-tenant validates before Dokku side effects"

echo
echo "=== legitimate tenant application keys ==="
assert_allowed "FEATURE_FLAG=enabled"
assert_allowed "DATABASE_URL=mysql://tenant:password@db/tenant"
assert_allowed "DB_HOST=host.docker.internal"
assert_allowed "DB_PORT=3306"
assert_allowed "DB_NAME=tenant_acme"
assert_allowed "DB_USER=usr_acme"
assert_allowed "DB_PASSWORD=tenant-password"
assert_allowed "HOST=host.docker.internal:3306"
assert_allowed "DBUSER=usr_acme"
assert_allowed "PASSWORD=tenant-password"
assert_allowed "DBNAME=tenant_acme"
assert_allowed "ADMIN_PASSWORD=seed-password"
assert_allowed "JWT_SECERT_KEY=tenant-signing-key"

echo
echo "=== reserved deployment keys ==="
assert_rejected "BASE_DOMAIN=evil.example"
assert_rejected "TENANT_ID=other-tenant"
assert_rejected "MYSQL_ADMIN_PASSWORD=admin-secret"
assert_rejected "MIGRATION_DB_PASSWORD=migration-secret"
assert_rejected "MIGRATE_CMD=drop-everything"
assert_rejected "DOCKER_HOST=tcp://attacker:2375"
assert_rejected "DOCKERHUB_TOKEN=registry-secret"
assert_rejected "DOKKU_CONTAINER=other-dokku"
assert_rejected "OPENOBSERVE_TENANT_OTLP_TOKEN=telemetry-secret"
assert_rejected "OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic%20attacker"
assert_rejected "METRICS_TOKEN=telemetry-secret"
assert_rejected "NATS_URL=nats://unapproved-host:4222"

echo
echo "=== malformed keys ==="
assert_rejected "not-a-key=value"
assert_rejected "NO_EQUALS"

echo
echo "All tenant env allow-list checks passed."
