#!/usr/bin/env bash
# =============================================================================
# test-backups.sh — Unit tests for the backup lifecycle helpers and the
# manage-backups.sh policy behavior. Runs entirely offline (no MySQL/Dokku):
# it seeds a temporary BACKUP_DIR with manifests + artifacts and asserts the
# retention/ownership/verification rules.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
source scripts/lib.sh

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

BD="$REPO_DIR/.test-backups.$$"
CFG="$REPO_DIR/.test-backups-noconfig.$$.env"   # intentionally does not exist
trap 'rm -rf "$BD"' EXIT
rm -rf "$BD"; mkdir -p "$BD/src/acme"
echo data > "$BD/src/acme/f.txt"

seed_set() {
    # seed_set <ts> <origin> <owner> <age-days>
    local ts="$1" origin="$2" owner="$3" age="$4"
    local tar="$BD/acme_files_${ts}.tar.gz"
    tar czf "$tar" -C "$BD/src" acme
    write_backup_manifest "$BD/acme_${ts}.meta.json" acme "$ts" "$origin" "$owner" "$tar" - true
    touch -d "${age} days ago" "$BD/acme_${ts}.meta.json"
}

mb() { BACKUP_DIR="$BD" bash scripts/manage-backups.sh --config "$CFG" "$@"; }

echo "=== manage-backups syntax ==="
bash -n scripts/manage-backups.sh && pass "syntax manage-backups"
bash -n scripts/backup-tenant.sh && pass "syntax backup-tenant"
bash -n scripts/restore-tenant.sh && pass "syntax restore-tenant"

echo
echo "=== retention protects user backups, prunes old auto backups ==="
seed_set 20200101_000000 user  alice  400
seed_set 20200102_000000 auto  system 400
seed_set 20990101_000000 auto  system 0     # fresh auto — must survive
mb prune --retention-days 30 >/dev/null
[ -f "$BD/acme_20200101_000000.meta.json" ] || fail "user backup was deleted by policy"
pass "user backup protected from prune"
[ ! -f "$BD/acme_20200102_000000.meta.json" ] || fail "old auto backup was not pruned"
pass "old auto backup pruned"
[ -f "$BD/acme_20990101_000000.meta.json" ] || fail "fresh auto backup was wrongly pruned"
pass "fresh auto backup retained"

echo
echo "=== artifacts removed with their manifest on prune ==="
[ ! -f "$BD/acme_files_20200102_000000.tar.gz" ] || fail "pruned auto artifact left behind"
pass "pruned auto artifact removed"

echo
echo "=== delete ownership rules ==="
if mb delete acme_20200101_000000 >/dev/null 2>&1; then
    fail "user backup deleted without owner/force"
fi
pass "user backup delete refused without owner"
mb delete acme_20200101_000000 --owner bob >/dev/null 2>&1 && fail "wrong owner allowed delete" || pass "wrong owner refused"
mb delete acme_20200101_000000 --owner alice >/dev/null
[ ! -f "$BD/acme_20200101_000000.meta.json" ] || fail "owner-authorized delete did not remove backup"
pass "owner-authorized delete works"

echo
echo "=== force override deletes protected user backup ==="
seed_set 20200103_000000 user carol 10
mb delete acme_20200103_000000 --force >/dev/null
[ ! -f "$BD/acme_20200103_000000.meta.json" ] || fail "--force did not delete user backup"
pass "force override deletes user backup"

echo
echo "=== verify detects corruption ==="
seed_set 20200104_000000 auto system 1
mb verify acme_20200104_000000 >/dev/null && pass "verify passes for good artifact" || fail "verify failed on good artifact"
# Corrupt the artifact and re-verify
echo "not a gzip" > "$BD/acme_files_20200104_000000.tar.gz"
if mb verify acme_20200104_000000 >/dev/null 2>&1; then
    fail "verify passed on corrupt artifact"
fi
pass "verify detects corrupt artifact"

echo
echo "=== json listing is well-formed ==="
seed_set 20200105_000000 user dave 1
out="$(mb list --json)"
echo "$out" | grep -q '"origin": "user"' || fail "json missing user origin"
echo "$out" | grep -q '"owner": "dave"' || fail "json missing owner"
pass "json listing includes manifest fields"

echo
echo "ALL BACKUP TESTS PASSED"
