#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]-}"
if [ -z "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$PWD/scripts/tests/test-create-tenant-image-rollback.sh"
fi
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() {
    local file="$1" pattern="$2" message="$3"
    grep -Fq "$pattern" "$file" || fail "$message"
}
load_function() {
    local name="$1" file="$2"
    eval "$(
        awk -v function_name="$name" '
            $0 ~ "^" function_name "\\(\\) \\{" {
                in_function=1
                depth=1
                print
                next
            }
            in_function {
                line=$0
                opens=gsub(/\{/, "", line)
                closes=gsub(/\}/, "", line)
                depth += opens - closes
                print
                if (depth == 0) {
                    exit
                }
            }
        ' "$file" | tr -d '\r'
    )"
}

CREATE=scripts/create-tenant.sh

echo "=== create-tenant captures and rolls back candidate images ==="
for pattern in \
    'declare -A PREVIOUS_IMAGE=()' \
    'declare -A IMAGE_SWAP_ATTEMPTED=()' \
    'current_app_image() {' \
    'rollback_previous_image() {' \
    'IMAGE_SWAP_ATTEMPTED["backend"]=true' \
    'IMAGE_SWAP_ATTEMPTED["frontend"]=true' \
    'MIGRATIONS_APPLIED=true'; do
    contains "$CREATE" "$pattern" "create-tenant is missing $pattern"
done
contains "$CREATE" 'previous image linkage is preserved in the failed audit' \
    "unsafe image rollback does not document recovery linkage"
pass "candidate image and migration rollback state are tracked"

source <(tr -d '\r' < scripts/lib.sh)
source <(tr -d '\r' < scripts/tenant-provenance.sh)
RUNTIME_IDENTITY_KEYS=(APP_TEST APP_MISSING)
declare -A PREVIOUS_CONFIG=()
PREVIOUS_CONFIG["acme-frontend:APP_TEST"]="old-config"
PREVIOUS_CONFIG["acme-frontend:APP_MISSING"]=""
load_function restore_runtime_config "$CREATE"
load_function rollback_previous_image "$CREATE"

TENANT_NAME=acme
MIGRATIONS_APPLIED=false
declare -A PREVIOUS_IMAGE=()
declare -A IMAGE_SWAP_ATTEMPTED=()
OLD_FRONTEND_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
OLD_BACKEND_DIGEST="sha256:2222222222222222222222222222222222222222222222222222222222222222"
ROLLBACK_CALLS=()
log() { :; }
error() { ROLLBACK_CALLS+=("error:$*"); }
dokku() {
    case "$1" in
        config:set) ROLLBACK_CALLS+=("config:set") ;;
        config:unset) ROLLBACK_CALLS+=("config:unset") ;;
    esac
    return 0
}
dokku_git_from_image() {
    ROLLBACK_CALLS+=("image:$1:$2")
    return 0
}
verify_runtime_immutable_image() {
    ROLLBACK_CALLS+=("verify:$1:$2")
    return 0
}

PREVIOUS_IMAGE[frontend]="registry/web@${OLD_FRONTEND_DIGEST}"
IMAGE_SWAP_ATTEMPTED[frontend]=true
rollback_previous_image frontend || fail "safe frontend rollback failed"
printf '%s\n' "${ROLLBACK_CALLS[@]}" |
    grep -Fqx "image:acme-frontend:registry/web@${OLD_FRONTEND_DIGEST}" ||
    fail "safe frontend rollback did not restore the previous image"
printf '%s\n' "${ROLLBACK_CALLS[@]}" |
    grep -Fqx "verify:acme-frontend:registry/web@${OLD_FRONTEND_DIGEST}" ||
    fail "safe frontend rollback did not verify the running immutable image"
config_line="$(printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -nF 'config:set' | head -1 | cut -d: -f1)"
image_line="$(printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -nF 'image:acme-frontend:' | head -1 | cut -d: -f1)"
[ -n "$config_line" ] && [ -n "$image_line" ] && [ "$config_line" -lt "$image_line" ] ||
    fail "safe frontend rollback restarted before restoring runtime identity"
if printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -Fq 'registry/web:old'; then
    fail "safe frontend rollback followed the moved mutable tag"
fi
pass "safe rollback restores and verifies the previous immutable frontend image"

echo "=== update and fleet rollback restore runtime identity before restart ==="
UPDATE=scripts/update-tenant.sh
DEPLOY_ALL=scripts/deploy-all.sh
load_function rollback_component "$UPDATE"
load_function rollback_previous_image "$DEPLOY_ALL"
load_function restore_previous_identity "$DEPLOY_ALL"
load_function restore_previous_state "$DEPLOY_ALL"

declare -A PREVIOUS_DB_IDENTITY=()
PREVIOUS_DB_IDENTITY[frontend]=$'registry/web:stable\t'"${OLD_FRONTEND_DIGEST}"$'\tstable\tv1.0.0\told-commit\told-sh\t42\thttps://ci.example/actions/runs/42\t2026-01-01T00:00:00Z'
PREVIOUS_IMAGE[frontend]="registry/web@${OLD_FRONTEND_DIGEST}"
PREVIOUS_CONFIG["acme-frontend:APP_TEST"]="old-config"
PREVIOUS_CONFIG["acme-frontend:APP_MISSING"]=""
MIGRATIONS_APPLIED=false
ROLLBACK_CALLS=()
tenant_record_identity() { ROLLBACK_CALLS+=("identity:$2"); return 0; }
tenant_clear_identity() { ROLLBACK_CALLS+=("clear-identity:$2"); return 0; }
rollback_component frontend || fail "update-tenant rollback failed"
config_line="$(printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -nF 'config:set' | head -1 | cut -d: -f1)"
image_line="$(printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -nF 'image:acme-frontend:' | head -1 | cut -d: -f1)"
[ -n "$config_line" ] && [ -n "$image_line" ] && [ "$config_line" -lt "$image_line" ] ||
    fail "update-tenant restarted before restoring runtime identity"

PREVIOUS_CONFIG["acme-frontend:APP_TEST"]="old-config"
PREVIOUS_CONFIG["acme-frontend:APP_MISSING"]=""
ROLLBACK_CALLS=()
restore_previous_state acme frontend acme-frontend \
    "${PREVIOUS_IMAGE[frontend]}" "${PREVIOUS_DB_IDENTITY[frontend]}" ||
    fail "deploy-all rollback failed"
config_line="$(printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -nF 'config:set' | head -1 | cut -d: -f1)"
image_line="$(printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -nF 'image:acme-frontend:' | head -1 | cut -d: -f1)"
[ -n "$config_line" ] && [ -n "$image_line" ] && [ "$config_line" -lt "$image_line" ] ||
    fail "deploy-all restarted before restoring runtime identity"
pass "all rollback paths restore runtime identity before image restart"

echo "=== moved tags never replace the captured immutable prior image ==="
load_function rollback_previous_image "$CREATE"
PREVIOUS_CONFIG["acme-frontend:APP_IMAGE_RESOLVED_REF"]="registry/web@${OLD_FRONTEND_DIGEST}"
captured_previous="$(
    provenance_previous_image_ref \
        "registry/web:stable" "$OLD_FRONTEND_DIGEST" \
        "${PREVIOUS_CONFIG["acme-frontend:APP_IMAGE_RESOLVED_REF"]}" \
        "registry/web:stable"
)"
[ "$captured_previous" = "registry/web@${OLD_FRONTEND_DIGEST}" ] ||
    fail "moved tag replaced the captured immutable prior image"
pass "moved tag is ignored in favor of the captured immutable prior image"

ROLLBACK_CALLS=()
MIGRATIONS_APPLIED=true
PREVIOUS_IMAGE[backend]="registry/api@${OLD_BACKEND_DIGEST}"
IMAGE_SWAP_ATTEMPTED[backend]=true
if rollback_previous_image backend; then
    fail "backend rollback after migrations was not refused"
else
    rollback_rc=$?
fi
[ "$rollback_rc" -eq 2 ] || fail "unsafe backend rollback returned $rollback_rc, expected 2"
if printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -q '^image:'; then
    fail "unsafe backend rollback reached Dokku"
fi
printf '%s\n' "${ROLLBACK_CALLS[@]}" |
    grep -Fq 'automatic image rollback refused after migrations' ||
    fail "unsafe backend rollback did not report the refusal"
pass "unsafe rollback refuses image changes explicitly"

echo "=== failed deployment restores image, config, and durable identity ==="
load_function restore_runtime_config "$CREATE"
load_function restore_previous_identity "$CREATE"
load_function record_deployment_failure "$CREATE"

RUNTIME_IDENTITY_KEYS=(APP_TEST APP_MISSING)
declare -A PREVIOUS_CONFIG=()
declare -A PREVIOUS_IDENTITY=()
PREVIOUS_CONFIG["acme-frontend:APP_TEST"]="old-config"
PREVIOUS_CONFIG["acme-frontend:APP_MISSING"]=""
PREVIOUS_IDENTITY[frontend]=$'registry/web:stable\t'"${OLD_FRONTEND_DIGEST}"$'\tstable\tv1.0.0\told-commit\told-sh\t42\thttps://ci.example/actions/runs/42\t2026-01-01T00:00:00Z'
PREVIOUS_IMAGE[frontend]="registry/web@${OLD_FRONTEND_DIGEST}"
IMAGE_SWAP_ATTEMPTED[frontend]=true
MIGRATIONS_APPLIED=false
BUILD_DIGEST="sha256:candidate"
BUILD_CHANNEL="stable"
BUILD_VERSION="v2.0.0"
BUILD_COMMIT="new-commit"
BUILD_COMMIT_SHORT="new-sh"
BUILD_WORKFLOW_RUN_ID="43"
BUILD_WORKFLOW_RUN_URL="https://ci.example/actions/runs/43"
BUILD_BUILT_AT="2026-01-02T00:00:00Z"
BUILD_IMAGE_REF="registry/web:new"
ROLLBACK_CALLS=()
dokku() {
    case "$1" in
        config:set) ROLLBACK_CALLS+=("config:set") ;;
        config:unset) ROLLBACK_CALLS+=("config:unset") ;;
    esac
    return 0
}
tenant_record_identity() {
    ROLLBACK_CALLS+=("identity:$2:$3")
    return 0
}
tenant_clear_identity() {
    ROLLBACK_CALLS+=("clear-identity:$2")
    return 0
}
tenant_record_failure() {
    ROLLBACK_CALLS+=("failure:$3")
    return 0
}
tenant_record_audit() {
    ROLLBACK_CALLS+=("audit:${13}:${14}:${16}")
    return 0
}

record_deployment_failure frontend "registry/web:new" "health check failed" ||
    fail "safe deployment failure was reported as restore failure"
printf '%s\n' "${ROLLBACK_CALLS[@]}" |
    grep -Fqx "image:acme-frontend:registry/web@${OLD_FRONTEND_DIGEST}" ||
    fail "failed deployment did not roll back the image"
printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -Fqx 'config:set' ||
    fail "failed deployment did not restore populated runtime config"
printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -Fqx 'config:unset' ||
    fail "failed deployment did not clear previously absent runtime config"
printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -Fqx 'identity:frontend:registry/web:stable' ||
    fail "failed deployment did not restore durable identity"
printf '%s\n' "${ROLLBACK_CALLS[@]}" |
    grep -Fqx "audit:registry/web@${OLD_FRONTEND_DIGEST}:${OLD_FRONTEND_DIGEST}:health check failed" ||
    fail "failed deployment did not preserve previous image linkage"
pass "safe failure restores image, config, durable identity, and immutable audit linkage"

ROLLBACK_CALLS=()
MIGRATIONS_APPLIED=true
PREVIOUS_IMAGE[backend]="registry/api@${OLD_BACKEND_DIGEST}"
IMAGE_SWAP_ATTEMPTED[backend]=true
PREVIOUS_CONFIG["acme-backend:APP_TEST"]="old-config"
PREVIOUS_CONFIG["acme-backend:APP_MISSING"]=""
PREVIOUS_IDENTITY[backend]=$'registry/api:stable\t'"${OLD_BACKEND_DIGEST}"$'\tstable\tv1.0.0\told-commit\told-sh\t42\t\t2026-01-01T00:00:00Z'
if record_deployment_failure backend "registry/api:new" "version check failed"; then
    fail "unsafe deployment failure was not reported"
else
    failure_rc=$?
fi
[ "$failure_rc" -eq 2 ] || fail "unsafe deployment failure returned $failure_rc, expected 2"
printf '%s\n' "${ROLLBACK_CALLS[@]}" |
    grep -Fq 'automatic image rollback refused after migrations' ||
    fail "unsafe failure did not preserve an explicit rollback refusal"
printf '%s\n' "${ROLLBACK_CALLS[@]}" | grep -Fqx 'config:set' ||
    fail "unsafe failure did not restore runtime config"
printf '%s\n' "${ROLLBACK_CALLS[@]}" |
    grep -Fqx 'identity:backend:registry/api:stable' ||
    fail "unsafe failure did not restore durable identity metadata"
printf '%s\n' "${ROLLBACK_CALLS[@]}" |
    grep -Fq "audit:registry/api@${OLD_BACKEND_DIGEST}:${OLD_BACKEND_DIGEST}:version check failed; automatic image rollback refused" ||
    fail "unsafe failure did not preserve previous image recovery linkage"
pass "unsafe failure restores metadata while preserving explicit recovery linkage"

echo "ALL CREATE-TENANT IMAGE ROLLBACK TESTS PASSED"
