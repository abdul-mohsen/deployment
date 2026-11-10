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
                if [ "$RUNTIME_IMAGE_ID" = "$EXPECTED_IMAGE_ID" ]; then
                    echo "example/api@${IMAGE_DIGEST}"
                else
                    echo "example/api@${STALE_IMAGE_DIGEST}"
                fi
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
app_version_response() {
    printf '%s' '{"version":"v1.2.3","commit":"0123456789abcdef0123456789abcdef01234567","digest":"'"$IMAGE_DIGEST"'","image_ref":"example/api:v1.2.3","channel":"release","workflow_run_id":"42","workflow_run_url":"https://github.com/example/api/actions/runs/42","built_at":"2026-09-07T10:00:00Z"}'
}
verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT" \
    || fail "matching /version identity was rejected"
pass "matching /version identity is accepted"
echo "=== stale environment identity cannot hide the running image ==="
RUNTIME_IMAGE_ID="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
if verify_runtime_identity api-app "$BUILD_VERSION" "$BUILD_COMMIT" "$BUILD_DIGEST" \
    "$BUILD_IMAGE_REF" "$BUILD_CHANNEL" "$BUILD_WORKFLOW_RUN_ID" "$BUILD_WORKFLOW_RUN_URL" "$BUILD_BUILT_AT"; then
    fail "stale running image was accepted when /version matched injected values"
else
    pass "stale running image is rejected independently of /version values"
fi
RUNTIME_IMAGE_ID="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
grep -q 'require_registry_tenant_key' scripts/create-tenant.sh \
    || fail "create-tenant must gate provisioning on registry tenant_key readiness"
grep -q 'tenant_registry_key' scripts/init-tenant-db.sh scripts/lib.sh \
    || fail "tenant_key must be copied from the registry during initialization"
! grep -R -q '/api/health' scripts/*.sh templates REQUIREMENTS.md \
    || fail "legacy /api/health deployment probe remains"
pass "migration, rollback, and component-only guards are present"

echo "ALL TENANT PROVENANCE TESTS PASSED"
