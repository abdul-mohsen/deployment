#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-no-git-push-and-master-grants.sh — deploy-flow guards
# =============================================================================
# Tenant apps are created and deployed from Docker Hub images by the scripts only.
# This test fails if a git-push deploy path comes back (--git-only or a
# "git push dokku" hint), or if a doc or an example grants ALL PRIVILEGES on the
# zatca_master registry.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

self="./scripts/tests/test-no-git-push-and-master-grants.sh"

echo "=== no git-push deploy path ==="
push_hits="$(grep -R -I -n -F -e '--git-only' -e 'git push dokku' --exclude-dir=.git . \
    | grep -v "^${self}:" || true)"
if [ -n "$push_hits" ]; then
    printf '%s\n' "$push_hits" >&2
    fail "a git-push deploy path is still in the repo (--git-only or 'git push dokku')"
fi
pass "no --git-only and no 'git push dokku' in the repo"

echo ""
echo "=== no ALL PRIVILEGES on zatca_master in docs or examples ==="
grant_hits="$(grep -R -I -n -i -E '\bALL( +PRIVILEGES)? +ON +[`"]?(zatca_master|MYSQL_MASTER_DB)' \
    --exclude-dir=.git . | grep -v "^${self}:" || true)"
if [ -n "$grant_hits" ]; then
    printf '%s\n' "$grant_hits" >&2
    fail "docs or examples grant ALL PRIVILEGES on zatca_master"
fi
pass "no ALL PRIVILEGES grant on zatca_master in the repo"

echo ""
echo "ALL NO-GIT-PUSH AND MASTER-GRANT TESTS PASSED"
