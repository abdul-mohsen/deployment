#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

source scripts/lib.sh
source scripts/tenant-provenance.sh

IMAGE_DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

echo "=== registry tenant_key guard is read-only ==="
run_mysql() {
    local args="$*"
    if [[ "$args" == *"information_schema.columns"* ]]; then
        printf '1\n'
    elif [[ "$args" == *"information_schema.triggers"* ]]; then
        printf '1\n'
    elif [[ "$args" == *"SELECT IFNULL(tenant_key"* ]]; then
        printf 'tenant-key-marker\n'
    fi
}
require_registry_tenant_key || fail "migrated registry was rejected"
[ "$(tenant_registry_key tenant_acme)" = "tenant-key-marker" ] \
    || fail "tenant_key was not read from the registry"
pass "registry readiness and tenant_key provenance are read-only"
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
EXPECTED_IMAGE_ID="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
STALE_IMAGE_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RUNTIME_IMAGE_ID="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
RUNTIME_IMAGE_DIGEST="$IMAGE_DIGEST"
docker() {
    if [ "$1" = "ps" ]; then
        printf 'tenant-api-container\n'
        return 0
    fi
    local format=""
    local format_next=0
    for arg in "$@"; do
        if [ "$format_next" -eq 1 ]; then
            format="$arg"
            format_next=0
            continue
        fi
        case "$arg" in
            --format=*) format="${arg#--format=}" ;;
            --format|-f) format_next=1 ;;
        esac
    done
    case "$*" in
        *"inspect -f"*|*"inspect --format"*)
            if [[ "$*" == *"image inspect"* && "$format" == *".Id"* ]]; then
                echo "$EXPECTED_IMAGE_ID"
                return 0
            fi
            if [[ "$format" == *".Image"* ]]; then
                echo "$RUNTIME_IMAGE_ID"
                return 0
            fi
            if [[ "$format" == *"RepoDigests"* ]]; then
                echo "example/api@${RUNTIME_IMAGE_DIGEST}"
                return 0
            fi
            ;;
    esac
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
[ "${BUILD_IMAGE_ID:-}" = "$EXPECTED_IMAGE_ID" ] ||
    fail "resolved BuildIdentity did not capture the immutable image ID"
grep -q 'docker image inspect --format.*"\$BUILD_RESOLVED_REF"' scripts/tenant-provenance.sh ||
    fail "expected image ID is not captured from the resolved immutable ref"
VERSION_RESPONSE_AVAILABLE=true
VERSION_RESPONSE_JSON='{"version":"v1.2.3","commit":"0123456789abcdef0123456789abcdef01234567","digest":"'"$IMAGE_DIGEST"'","image_ref":"example/api:v1.2.3","channel":"release","workflow_run_id":"42","workflow_run_url":"https://github.com/example/api/actions/runs/42","built_at":"2026-09-07T10:00:00Z"}'
app_version_response() {
    [ "$VERSION_RESPONSE_AVAILABLE" = true ] || return 1
    printf '%s' "$VERSION_RESPONSE_JSON"
}
RUNTIME_IDENTITY_DIAGNOSTIC="stale verification failure"
verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" \
    || fail "matching /version identity was rejected"
[ -z "${RUNTIME_IDENTITY_DIAGNOSTIC:-}" ] ||
    fail "successful verification retained a stale failure diagnostic"
pass "matching /version identity is accepted"

echo "=== missing RepoDigest uses only the captured immutable image ID ==="
RUNTIME_IMAGE_DIGEST=""
RUNTIME_IMAGE_ID="$EXPECTED_IMAGE_ID"
if ! verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" "$BUILD_IMAGE_ID"; then
    fail "matching captured image ID did not cover missing runtime RepoDigest: ${RUNTIME_IDENTITY_DIAGNOSTIC:-no diagnostic}"
fi
pass "missing runtime RepoDigest is accepted only with the captured image ID"

echo "=== missing RepoDigest with a different image ID fails before /version ==="
RUNTIME_IMAGE_ID="$STALE_IMAGE_DIGEST"
VERSION_RESPONSE_AVAILABLE=false
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" "$BUILD_IMAGE_ID"; then
    fail "different runtime image ID was accepted without RepoDigest"
fi
fallback_failure="${RUNTIME_IDENTITY_DIAGNOSTIC:-}"
[[ "$fallback_failure" == *"image_id"* && "$fallback_failure" == *"$EXPECTED_IMAGE_ID"* && "$fallback_failure" == *"$STALE_IMAGE_DIGEST"* ]] ||
    fail "different image ID failure omitted safe expected/actual IDs"
[[ "$fallback_failure" != *"response unavailable"* ]] ||
    fail "missing RepoDigest image-ID mismatch reached /version"
pass "missing RepoDigest with a different image ID fails closed"

echo "=== missing RepoDigest fails when no expected image ID was captured ==="
RUNTIME_IMAGE_ID="$EXPECTED_IMAGE_ID"
VERSION_RESPONSE_AVAILABLE=false
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" ""; then
    fail "missing expected image ID was accepted when runtime RepoDigest was absent"
fi
[[ "${RUNTIME_IDENTITY_DIAGNOSTIC:-}" == *"image_id expected=<missing>"* ]] ||
    fail "missing expected image ID was not reported safely"
[[ "${RUNTIME_IDENTITY_DIAGNOSTIC:-}" != *"response unavailable"* ]] ||
    fail "missing expected image ID reached /version"
VERSION_RESPONSE_AVAILABLE=true

echo "=== present digest mismatch is not bypassed by a matching image ID ==="
RUNTIME_IMAGE_ID="$EXPECTED_IMAGE_ID"
RUNTIME_IMAGE_DIGEST="$STALE_IMAGE_DIGEST"
VERSION_RESPONSE_AVAILABLE=false
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" "$BUILD_IMAGE_ID"; then
    fail "image ID fallback bypassed a present digest mismatch"
fi
[[ "${RUNTIME_IDENTITY_DIAGNOSTIC:-}" == *"digest expected=$IMAGE_DIGEST actual=$STALE_IMAGE_DIGEST"* ]] ||
    fail "present digest mismatch was not reported"
[[ "${RUNTIME_IDENTITY_DIAGNOSTIC:-}" != *"response unavailable"* ]] ||
    fail "present digest mismatch reached /version"
VERSION_RESPONSE_AVAILABLE=true
RUNTIME_IMAGE_DIGEST="$IMAGE_DIGEST"
pass "present digest mismatch remains a hard failure"

echo "=== moved tag cannot hide a digest mismatch ==="
RUNTIME_IMAGE_ID="$EXPECTED_IMAGE_ID"
RUNTIME_IMAGE_DIGEST="$STALE_IMAGE_DIGEST"
if verify_runtime_image_identity api-app "$IMAGE_DIGEST" "$BUILD_IMAGE_REF"; then
    fail "moved tag was accepted when the running image digest mismatched"
else
    pass "moved tag is rejected when the running image digest mismatches"
fi
RUNTIME_IMAGE_DIGEST="$IMAGE_DIGEST"
echo "=== running image mismatch is distinct and stops before /version ==="
RUNTIME_IMAGE_DIGEST="$STALE_IMAGE_DIGEST"
VERSION_RESPONSE_AVAILABLE=false
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
    fail "runtime image mismatch was accepted"
fi
image_failure="${RUNTIME_IDENTITY_DIAGNOSTIC:-}"
[[ "$image_failure" == *"image identity"* ]] ||
    fail "runtime image failure did not identify its failure category"
[[ "$image_failure" != *"/version"* ]] ||
    fail "runtime image failure was mislabeled as a /version failure"
pass "running image mismatch is distinct and short-circuits /version"
RUNTIME_IMAGE_DIGEST="$IMAGE_DIGEST"

echo "=== unavailable /version response is distinct ==="
VERSION_RESPONSE_AVAILABLE=false
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
    fail "unavailable /version response was accepted"
fi
response_failure="${RUNTIME_IDENTITY_DIAGNOSTIC:-}"
[[ "$response_failure" == *"response"* && "$response_failure" == *"unavailable"* ]] ||
    fail "missing /version response did not have a distinct diagnostic"
VERSION_RESPONSE_AVAILABLE=true
pass "unavailable /version response has its own failure category"

echo "=== stale environment identity cannot hide the running image ==="
RUNTIME_IMAGE_ID="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RUNTIME_IMAGE_DIGEST="$STALE_IMAGE_DIGEST"
VERSION_RESPONSE_AVAILABLE=false
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
    fail "stale running image was accepted when /version matched injected values"
else
    [[ "${RUNTIME_IDENTITY_DIAGNOSTIC:-}" == *"image identity"* ]] ||
        fail "stale running image failure did not retain the image failure category"
    pass "stale running image is rejected independently of /version values"
fi
RUNTIME_IMAGE_ID="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
RUNTIME_IMAGE_DIGEST="$IMAGE_DIGEST"
VERSION_RESPONSE_AVAILABLE=true
app_version_response() {
    printf '%s' '{"version":"v1.2.3","commit":"ffffffffffffffffffffffffffffffffffffffff","digest":"'"$IMAGE_DIGEST"'","image_ref":"example/api:v1.2.3","channel":"release","workflow_run_id":"42","built_at":"2026-09-07T10:00:00Z"}'
}
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
    fail "mismatched /version commit was accepted"
else
    field_failure="${RUNTIME_IDENTITY_DIAGNOSTIC:-}"
    [[ "$field_failure" == *"commit"* ]] ||
        fail "field mismatch diagnostic omitted the commit field"
    pass "mismatched /version commit is rejected"
fi

echo "=== field diagnostics include only validated identity values ==="
BUILD_WORKFLOW_RUN_URL="https://expected-user:expected-secret-sentinel@ci.example/actions/runs/42"
app_version_response() {
    printf '%s' '{"commit":"runtime-secret-sentinel","digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","image_ref":"https://runtime-user:runtime-secret-sentinel@example/api:v9","channel":"runtime-secret-sentinel","workflow_run_id":"43","workflow_run_url":"https://runtime-user:runtime-secret-sentinel@ci.example/actions/runs/43","built_at":"runtime-secret-sentinel"}'
}
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
    fail "multiple missing/mismatching identity fields were accepted"
fi
field_failure="${RUNTIME_IDENTITY_DIAGNOSTIC:-}"
for field in version commit digest image_ref channel workflow_run_id workflow_run_url built_at; do
    [[ "$field_failure" == *"$field"* ]] ||
        fail "field mismatch diagnostic omitted $field"
done
[[ "$field_failure" == *"version expected=v1.2.3 actual=<missing>"* ]] ||
    fail "missing version did not show safe expected/actual values"
[[ "$field_failure" == *"digest expected=$IMAGE_DIGEST actual=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"* ]] ||
    fail "digest mismatch did not show safe expected/actual values"
[[ "$field_failure" == *"workflow_run_id expected=42 actual=43"* ]] ||
    fail "workflow ID mismatch did not show safe expected/actual values"
[[ "$field_failure" == *"commit expected=0123456789abcdef0123456789abcdef01234567 actual=<omitted>"* ]] ||
    fail "unsafe commit value was not omitted"
[[ "$field_failure" == *"workflow_run_url expected=<omitted> actual=<omitted>"* ]] ||
    fail "workflow URLs were not omitted"
[[ "$field_failure" != *"secret-sentinel"* && "$field_failure" != *"runtime-secret-sentinel"* ]] ||
    fail "identity diagnostic exposed a credential-bearing value"
[[ "$field_failure" != *'"commit":"runtime-secret-sentinel"'* ]] ||
    fail "identity diagnostic exposed raw /version JSON"
pass "field names are explicit and untrusted values are filtered"

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
grep -q 'require_registry_tenant_key' scripts/create-tenant.sh \
    || fail "create-tenant must gate provisioning on registry tenant_key readiness"
grep -q 'tenant_registry_key' scripts/init-tenant-db.sh scripts/lib.sh \
    || fail "tenant_key must be copied from the registry during initialization"
! grep -R -q '/api/health' scripts/*.sh templates REQUIREMENTS.md \
    || fail "legacy /api/health deployment probe remains"
pass "migration, rollback, and component-only guards are present"

echo "ALL TENANT PROVENANCE TESTS PASSED"
