#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() {
    local file="$1" pattern="$2" message="$3"
    grep -Fq "$pattern" "$file" || fail "$message"
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
source scripts/lib.sh
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
pass "empty tab-delimited fields are preserved"

echo "=== restore failures are surfaced ==="
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
pass "runtime and durable identity restore failures are visible"
