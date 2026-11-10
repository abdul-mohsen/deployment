#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

CAPTURE="$REPO_DIR/.test-deployment-state-migration.$$"
cleanup() {
    rm -f "$CAPTURE"
}
trap cleanup EXIT

source scripts/lib.sh

MYSQL_MASTER_DB=zatca_master
DEPLOY_STATE_DB=deployment_state

run_mysql() {
    local args="$*"
    if [[ "$args" == *"information_schema.tables"* ]]; then
        printf '1\n'
        return 0
    fi
    if [[ "$args" == *"information_schema.columns"* ]]; then
        printf '%s\n' \
            name backend_image frontend_image \
            backend_image_ref backend_image_digest backend_channel backend_version \
            backend_commit backend_commit_short backend_workflow_run backend_built_at \
            backend_deployed_at backend_deployment_status backend_deployment_error \
            frontend_image_ref frontend_image_digest frontend_channel frontend_version \
            frontend_commit frontend_commit_short frontend_workflow_run frontend_built_at \
            frontend_deployed_at frontend_deployment_status frontend_deployment_error
        return 0
    fi
    cat >> "$CAPTURE"
}

echo "=== legacy state migration copies pins and provenance ==="
migrate_legacy_deployment_state
grep -q 'INSERT INTO .*tenant_image' "$CAPTURE" ||
    fail "tenant image pins were not copied"
grep -q 'INSERT INTO .*tenant_identity' "$CAPTURE" ||
    fail "tenant provenance was not copied"
grep -q 'FROM .*zatca_master.*tenant' "$CAPTURE" ||
    fail "migration does not read the legacy registry"
grep -q 'ON DUPLICATE KEY UPDATE' "$CAPTURE" ||
    fail "migration is not idempotent"
[ "$(grep -c 'name=VALUES(name)' "$CAPTURE")" -ge 2 ] ||
    fail "existing pins or provenance rows are not preserved"
pass "legacy pins and provenance use idempotent, preserve-current upserts"

start_line="$(grep -n '^START TRANSACTION;$' "$CAPTURE" | cut -d: -f1)"
image_line="$(grep -n '^INSERT INTO .*tenant_image' "$CAPTURE" | cut -d: -f1)"
identity_line="$(grep -n '^INSERT INTO .*tenant_identity' "$CAPTURE" | cut -d: -f1)"
commit_line="$(grep -n '^COMMIT;$' "$CAPTURE" | cut -d: -f1)"
[ -n "$start_line" ] && [ -n "$image_line" ] &&
    [ -n "$identity_line" ] && [ -n "$commit_line" ] &&
    [ "$start_line" -lt "$image_line" ] &&
    [ "$image_line" -lt "$identity_line" ] &&
    [ "$identity_line" -lt "$commit_line" ] ||
    fail "tenant_image and tenant_identity writes are not ordered in one transaction"
pass "tenant image and identity writes share one transaction"

echo "=== setup and deploy paths run the upgrade before state reads ==="
grep -q 'ensure_deployment_state_schema' scripts/setup.sh ||
    fail "setup does not ensure and migrate deployment state"
grep -q 'migrate_legacy_deployment_state' scripts/lib.sh ||
    fail "deployment state migration helper is missing"
grep -q 'SELECT i\.\$col FROM' scripts/deploy-all.sh &&
grep -q 'tenant_image' scripts/deploy-all.sh ||
    fail "deploy-all does not read deployment-owned pins"
pass "setup and deploy paths use the deployment-state upgrade"

echo "ALL DEPLOYMENT STATE MIGRATION TESTS PASSED"
