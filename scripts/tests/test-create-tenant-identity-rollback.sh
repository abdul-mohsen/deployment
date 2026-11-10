#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() {
    local pattern="$1" message="$2"
    grep -Fq "$pattern" scripts/create-tenant.sh || fail "$message"
}

echo "=== failed create-tenant image paths restore candidate identity ==="
bash -n scripts/create-tenant.sh

for helper in \
    capture_runtime_config \
    restore_runtime_config \
    restore_previous_identity \
    record_deployment_failure; do
    contains "${helper}()" "create-tenant is missing ${helper}"
done
contains 'dokku config:unset --no-restart "$app"' \
    "failed create-tenant paths do not clear unset APP_* identity"
contains 'tenant_clear_identity "$TENANT_NAME" "$app_type"' \
    "failed create-tenant paths do not clear durable candidate identity"
contains 'restore_runtime_config "$app"' \
    "failed create-tenant paths do not restore runtime identity"
contains 'restore_previous_identity "$app_type"' \
    "failed create-tenant paths do not restore durable identity"
contains 'tenant_record_failure "$TENANT_NAME" "$app_type" "$message"' \
    "failed create-tenant paths do not persist failed state"
contains 'tenant_record_audit "$TENANT_NAME" "$app_type" "$image"' \
    "failed create-tenant paths do not record failed audit state"

backend_failures="$(grep -cF 'record_deployment_failure backend "$BACKEND_IMAGE"' scripts/create-tenant.sh)"
[ "$backend_failures" -ge 5 ] ||
    fail "backend swap/health/verification/audit failures do not all roll back identity"
frontend_failures="$(grep -cF 'record_deployment_failure frontend "$FRONTEND_IMAGE"' scripts/create-tenant.sh)"
[ "$frontend_failures" -ge 6 ] ||
    fail "frontend swap/health/verification/audit failures do not all roll back identity"

backend_capture="$(grep -nF 'capture_runtime_config "$BACKEND_APP"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
backend_set="$(grep -nF 'set_runtime_build_identity "$BACKEND_APP" "$BACKEND_IMAGE"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
frontend_capture="$(grep -nF 'capture_runtime_config "$FRONTEND_APP"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
frontend_set="$(grep -nF 'set_runtime_build_identity "$FRONTEND_APP" "$FRONTEND_IMAGE"' scripts/create-tenant.sh | tail -1 | cut -d: -f1)"
[ "$backend_capture" -lt "$backend_set" ] ||
    fail "backend candidate identity is set before the previous APP_* values are captured"
[ "$frontend_capture" -lt "$frontend_set" ] ||
    fail "frontend candidate identity is set before the previous APP_* values are captured"

contains 'if ! record_verified_image_identity backend "$BACKEND_IMAGE"; then' \
    "backend success path no longer persists verified identity"
contains 'if ! record_verified_image_identity frontend "$FRONTEND_IMAGE"; then' \
    "frontend success path no longer persists verified identity"
pass "failed image swap/health/audit paths roll back identity and successful paths persist it"
