#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]-}"
if [ -z "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$PWD/scripts/tests/test-runtime-identity-restore.sh"
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
            $0 ~ "^" function_name "\\(\\) \\{" { in_function=1 }
            in_function { print }
            in_function && /^}/ { exit }
        ' "$file" | tr -d '\r'
    )"
}

echo "=== runtime identity snapshots include image tag and short commit ==="
for file in scripts/create-tenant.sh scripts/update-tenant.sh scripts/deploy-all.sh; do
    contains "$file" "APP_IMAGE_TAG" "$file omits APP_IMAGE_TAG"
    contains "$file" "APP_IMAGE_COMMIT_SHORT" "$file omits APP_IMAGE_COMMIT_SHORT"
    if grep -Fq "IFS=\$'\\t' read" "$file"; then
        fail "$file parses tab-delimited identity with collapsing IFS/read"
    fi
done
pass "runtime identity metadata is configured and parsed without IFS/read collapse"

echo "=== tab-delimited identity fields preserve empties ==="
# shellcheck source=../lib.sh
source <(tr -d '\r' < scripts/lib.sh)
split_tab_fields $'ref\t\tcommit\t\t\tbuilt'
[ "${#TAB_FIELDS[@]}" -eq 6 ] || fail "empty tab fields were discarded"
[ "${TAB_FIELDS[0]}" = "ref" ] || fail "first tab field changed"
[ -z "${TAB_FIELDS[1]}" ] || fail "first empty tab field was not preserved"
[ "${TAB_FIELDS[2]}" = "commit" ] || fail "commit field shifted"
[ -z "${TAB_FIELDS[3]}" ] || fail "middle empty tab field was not preserved"
[ -z "${TAB_FIELDS[4]}" ] || fail "second middle empty tab field was not preserved"
[ "${TAB_FIELDS[5]}" = "built" ] || fail "last tab field changed"
split_tab_fields $'\tvalue\t'
[ "${#TAB_FIELDS[@]}" -eq 3 ] || fail "leading/trailing empty fields were discarded"
[ -z "${TAB_FIELDS[0]}" ] || fail "leading empty field was not preserved"
[ "${TAB_FIELDS[1]}" = "value" ] || fail "value field shifted"
[ -z "${TAB_FIELDS[2]}" ] || fail "trailing empty field was not preserved"
split_tab_fields $'ref\tsha256:abc\trelease\tv1\tcommit\tshort\t42\t\t2026-11-07T10:00:00Z'
[ "${#TAB_FIELDS[@]}" -eq 9 ] || fail "missing workflow URL shifted identity fields"
[ "${TAB_FIELDS[6]}" = "42" ] || fail "workflow run field shifted"
[ -z "${TAB_FIELDS[7]}" ] || fail "missing workflow URL was not preserved"
[ "${TAB_FIELDS[8]}" = "2026-11-07T10:00:00Z" ] ||
    fail "built-at field shifted after missing workflow URL"
pass "empty tab-delimited fields are preserved"

echo "=== config:get, config:keys, and restore failures are surfaced ==="
for file in scripts/create-tenant.sh scripts/update-tenant.sh scripts/deploy-all.sh; do
    contains "$file" '! dokku config:set --no-restart "$app"' \
        "$file does not check runtime config restore failures"
    contains "$file" 'return 1' \
        "$file does not return on restore failure"
    if grep -Fq 'restore_runtime_config "$app" || true' "$file"; then
        fail "$file suppresses runtime identity restore failures"
    fi
done
if grep -Fq 'rollback_component "$component" || true' scripts/update-tenant.sh; then
    fail "update-tenant suppresses rollback identity restore failures"
fi

echo "=== missing runtime identity keys are captured as unset ==="
RUNTIME_IDENTITY_KEYS=(APP_VERSION APP_WORKFLOW_RUN_URL)
for file in scripts/create-tenant.sh scripts/update-tenant.sh scripts/deploy-all.sh; do
    unset PREVIOUS_CONFIG
    declare -A PREVIOUS_CONFIG=()
    load_function capture_runtime_config "$file"
    dokku() {
        case "$1" in
            config:keys)
                printf 'APP_VERSION\n'
                ;;
            config:get)
                [ "$3" = "APP_VERSION" ] || return 17
                printf 'previous-version\n'
                ;;
            *)
                return 0
                ;;
        esac
    }
    if ! capture_runtime_config test-app; then
        fail "$file treated a missing config key as a command failure"
    fi
    [ "${PREVIOUS_CONFIG["test-app:APP_VERSION"]}" = "previous-version" ] ||
        fail "$file did not capture the configured runtime identity key"
    [ "${PREVIOUS_CONFIG["test-app:APP_WORKFLOW_RUN_URL"]+set}" = "set" ] ||
        fail "$file did not record the missing runtime identity key"
    [ -z "${PREVIOUS_CONFIG["test-app:APP_WORKFLOW_RUN_URL"]}" ] ||
        fail "$file recorded a non-empty value for the missing runtime identity key"
done
pass "missing runtime identity keys are recorded as unset"

error() { :; }
RUNTIME_IDENTITY_KEYS=(APP_WORKFLOW_RUN_URL)
for file in scripts/create-tenant.sh scripts/update-tenant.sh scripts/deploy-all.sh; do
    unset PREVIOUS_CONFIG
    declare -A PREVIOUS_CONFIG=()
    load_function capture_runtime_config "$file"
    dokku() {
        case "$1" in
            config:keys)
                printf 'APP_WORKFLOW_RUN_URL\n'
                ;;
            config:get)
                return 17
                ;;
            *)
                return 0
                ;;
        esac
    }
    if capture_runtime_config test-app; then
        fail "$file swallowed config:get failure"
    fi

    unset PREVIOUS_CONFIG
    declare -A PREVIOUS_CONFIG=()
    dokku() {
        [ "$1" = "config:keys" ] && return 23
        return 0
    }
    if capture_runtime_config test-app; then
        fail "$file swallowed config:keys failure"
    fi

    PREVIOUS_CONFIG["test-app:APP_WORKFLOW_RUN_URL"]="https://example.test/workflow"
    dokku() {
        [ "$1" = "config:set" ] && return 19
        return 0
    }
    load_function restore_runtime_config "$file"
    if restore_runtime_config test-app; then
        fail "$file swallowed config restore failure"
    fi
done
load_function current_app_image scripts/update-tenant.sh
dokku() {
    case "$1" in
        git:report) return 1 ;;
        config:get) return 23 ;;
        *) return 0 ;;
    esac
}
if current_app_image test-app; then
    fail "update-tenant swallowed APP_IMAGE_REF config:get failure"
fi
pass "config:get, config:keys, and runtime identity restore failures propagate"

echo "=== durable identity reads propagate database failures ==="
source <(tr -d '\r' < scripts/tenant-provenance.sh)
run_mysql() { return 73; }
if tenant_current_identity tenant_acme backend >/dev/null; then
    fail "tenant_current_identity converted a database read failure to empty identity"
fi
for file in scripts/create-tenant.sh scripts/update-tenant.sh scripts/deploy-all.sh; do
    if grep -Fq 'tenant_current_identity "$TENANT_NAME" backend || true' "$file" ||
        grep -Fq 'tenant_current_identity "$TENANT_NAME" frontend || true' "$file" ||
        grep -Fq 'tenant_current_identity "$TENANT_NAME" "$component" || true' "$file" ||
        grep -Fq 'tenant_current_identity "$tenant" "$APP_TYPE" || true' "$file"; then
        fail "$file suppresses durable identity read failures"
    fi
done
pass "durable identity read failures remain visible"
