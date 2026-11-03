#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

source scripts/lib.sh
source scripts/tenant-provenance.sh

IMAGE_DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

echo "=== deployment state writes go to deployment_state, never zatca_master ==="
sql_calls_file="$(mktemp)"
trap 'rm -f "$sql_calls_file"' EXIT
run_mysql() {
    printf '%s\n' "$*" >> "$sql_calls_file"
}
tenant_record_identity acme backend example/api:v1 example/api:v1 "$IMAGE_DIGEST" \
    stable v1.2.3 abc1234 abc1234 1 https://github.com/example/api/actions/runs/1 2026-01-01T00:00:00Z
tenant_record_audit acme backend example/api:v1 example/api:v1 "$IMAGE_DIGEST" \
    stable v1.2.3 abc1234 abc1234 1 https://github.com/example/api/actions/runs/1 2026-01-01T00:00:00Z \
    "" "" started "" "" ""
grep -q '^deployment_state -e INSERT INTO tenant_identity' "$sql_calls_file" ||
    fail "identity is not written to deployment_state.tenant_identity"
grep -q '^deployment_state -e INSERT INTO tenant_deployment_audit' "$sql_calls_file" ||
    fail "audit is not written to deployment_state.tenant_deployment_audit"
! grep -q 'zatca_master\|UPDATE tenant ' "$sql_calls_file" ||
    fail "provenance writes still touch the zatca_master tenant table"
! grep -R -n 'ALTER TABLE' scripts/*.sh >/dev/null 2>&1 ||
    fail "a script still issues ALTER TABLE"
pass "provenance writes target deployment_state; no ALTER TABLE in scripts"

unset -f run_mysql

docker() {
    local format=""
    for arg in "$@"; do
        case "$arg" in --format=*) format="${arg#--format=}" ;; esac
    done
    case "$format" in
        *RepoDigests*) echo "example/api@${IMAGE_DIGEST}" ;;
        *channel*) echo "release" ;;
        *workflow_run_url*) echo "https://github.com/example/api/actions/runs/42" ;;
        *workflow_run_id*|*workflow*) echo "42" ;;
        *source*) echo "https://github.com/example/api" ;;
        *image_ref*|*ref.name*) echo "example/api:v1.2.3" ;;
        *created*|*built*) echo "2026-09-07T10:00:00Z" ;;
        *version*) echo "v1.2.3" ;;
        *revision*|*commit*) echo "0123456789abcdef0123456789abcdef01234567" ;;
        *digest*) echo "$IMAGE_DIGEST" ;;
        *) echo "" ;;
    esac
}

echo "=== missing labels fail closed ==="
docker() {
    local format=""
    for arg in "$@"; do
        case "$arg" in --format=*) format="${arg#--format=}" ;; esac
    done
    case "$format" in *RepoDigests*) echo "example/api@${IMAGE_DIGEST}" ;; *) echo "" ;; esac
}
if resolve_build_identity example/api:v1.2.3; then
    fail "missing OCI labels were accepted"
else
    pass "missing OCI labels are rejected"
fi

echo "=== mismatched digest fails closed ==="
docker() {
    local format=""
    for arg in "$@"; do
        case "$arg" in --format=*) format="${arg#--format=}" ;; esac
    done
    case "$format" in
        *RepoDigests*) echo "example/api@${IMAGE_DIGEST}" ;;
        *channel*) echo "release" ;;
        *workflow_run_url*) echo "https://github.com/example/api/actions/runs/42" ;;
        *workflow_run_id*|*workflow*) echo "42" ;;
        *source*) echo "https://github.com/example/api" ;;
        *image_ref*|*ref.name*) echo "example/api:v1.2.3" ;;
        *created*|*built*) echo "2026-09-07T10:00:00Z" ;;
        *version*) echo "v1.2.3" ;;
        *revision*|*commit*) echo "0123456789abcdef0123456789abcdef01234567" ;;
        *digest*) echo "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ;;
        *) echo "" ;;
    esac
}
if resolve_build_identity example/api:v1.2.3; then
    fail "mismatched digest label was accepted"
else
    pass "mismatched digest label is rejected"
fi

echo "=== successful identity and /version verification ==="
docker() {
    local format=""
    for arg in "$@"; do
        case "$arg" in --format=*) format="${arg#--format=}" ;; esac
    done
    case "$format" in
        *RepoDigests*) echo "example/api@${IMAGE_DIGEST}" ;;
        *channel*) echo "release" ;;
        *workflow_run_url*) echo "https://github.com/example/api/actions/runs/42" ;;
        *workflow_run_id*|*workflow*) echo "42" ;;
        *source*) echo "https://github.com/example/api" ;;
        *image_ref*|*ref.name*) echo "example/api:v1.2.3" ;;
        *created*|*built*) echo "2026-09-07T10:00:00Z" ;;
        *version*) echo "v1.2.3" ;;
        *revision*|*commit*) echo "0123456789abcdef0123456789abcdef01234567" ;;
        *digest*) echo "$IMAGE_DIGEST" ;;
        *) echo "" ;;
    esac
}
resolve_build_identity example/api:v1.2.3 || fail "valid BuildIdentity was rejected"
app_version_response() {
    printf '%s' '{"version":"v1.2.3","commit":"0123456789abcdef0123456789abcdef01234567","digest":"'"$IMAGE_DIGEST"'","image_ref":"example/api:v1.2.3","channel":"release","workflow_run_id":"42","workflow_run_url":"https://github.com/example/api/actions/runs/42","built_at":"2026-09-07T10:00:00Z"}'
}
verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" \
    || fail "matching /version identity was rejected"
pass "matching /version identity is accepted"
app_version_response() {
    printf '%s' '{"version":"v1.2.3","commit":"ffffffffffffffffffffffffffffffffffffffff","digest":"'"$IMAGE_DIGEST"'","image_ref":"example/api:v1.2.3","channel":"release","workflow_run_id":"42","built_at":"2026-09-07T10:00:00Z"}'
}
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
    fail "mismatched /version commit was accepted"
else
    pass "mismatched /version commit is rejected"
fi

echo "=== app probes use the container listening port ==="
docker() {
    case "$*" in
        *"config:get api-app SERVER_PORT"*) printf '8090\n' ;;
        *"config:get frontend-app SERVER_PORT"*) printf '\n' ;;
        *"config:get frontend-app PORT"*) printf '8000\n' ;;
        *"config:get legacy-app SERVER_PORT"*) printf '\n' ;;
        *"config:get legacy-app PORT"*) printf '\n' ;;
        *"ports:report legacy-app"*) printf 'Ports map: http:80:8123\n' ;;
        *"config:get fallback-app"*|*"ports:report fallback-app"*) exit 1 ;;
        *) printf '\n' ;;
    esac
}
assert_probe_port() {
    local app="$1" expected="$2" actual
    actual="$(dokku_app_port "$app")"
    [ "$actual" = "$expected" ] || fail "${app} probe port: expected ${expected}, got ${actual}"
}
assert_probe_port api-app 8090
assert_probe_port frontend-app 8000
assert_probe_port legacy-app 8123
assert_probe_port fallback-app 80
pass "runtime probes resolve backend, frontend, and legacy ports"

echo "=== migration, rollback, and component-only guards ==="
grep -q 'init-tenant-db.sh' scripts/update-tenant.sh &&
grep -q -- '--schema-only' scripts/update-tenant.sh \
    || fail "backend migration replay guard missing"
grep -q 'rollback_component' scripts/update-tenant.sh \
    || fail "partial swap rollback guard missing"
grep -q 'APP_VERSION=' scripts/update-tenant.sh \
    || fail "APP_VERSION runtime identity missing"
grep -q 'APP_COMMIT=' scripts/update-tenant.sh \
    || fail "APP_COMMIT runtime identity missing"
grep -q 'APP_IMAGE_CHANNEL=' scripts/update-tenant.sh \
    || fail "APP_IMAGE_CHANNEL runtime identity missing"
grep -q 'APP_WORKFLOW_RUN_ID=' scripts/update-tenant.sh \
    || fail "APP_WORKFLOW_RUN_ID runtime identity missing"
grep -q 'frontend' scripts/update-tenant.sh \
    || fail "component-only frontend update path missing"
grep -q 'IFS=.*workflow_url.*image_ref' scripts/create-tenant.sh \
    || fail "create-tenant must preserve workflow URL and image ref field order"
grep -q 'APP_IMAGE_VERSION="\$version"' scripts/create-tenant.sh \
    || fail "create-tenant must keep semantic version separate from Docker tag"
grep -q 'APP_IMAGE_TAG=' scripts/create-tenant.sh \
    || fail "create-tenant must persist the Docker tag separately"
! grep -R -q '/api/health' scripts/*.sh templates REQUIREMENTS.md \
    || fail "legacy /api/health deployment probe remains"
[ "$(grep -c '"workflow_run_id":"%s"' scripts/status.sh)" -eq 1 ] \
    || fail "status JSON does not have one canonical identity serialization"
pass "migration, rollback, and component-only guards are present"

echo "ALL TENANT PROVENANCE TESTS PASSED"
