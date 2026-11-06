#!/usr/bin/env bash
# Stub-harness contract for rollback-tenant.sh. The real script runs against a
# stub docker (lib.sh reaches Dokku only through `docker exec`) and a logging
# init-tenant-db.sh, the goose entry point. Needs no Docker, Dokku or MySQL.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/repo/scripts" "$tmpdir/bin"
cp scripts/*.sh "$tmpdir/repo/scripts/"
cat > "$tmpdir/repo/scripts/init-tenant-db.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GOOSE_LOG:?}"
STUB
cat > "$tmpdir/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$1" in
    ps) echo dokku ;;
esac
STUB
chmod +x "$tmpdir/repo/scripts/init-tenant-db.sh" "$tmpdir/bin/docker"

cat > "$tmpdir/config.env" <<'CONFIG'
BASE_DOMAIN=example.com
PUBLIC_PROTOCOL=https
CONFIG

export DOCKER_LOG="$tmpdir/docker.log"
export GOOSE_LOG="$tmpdir/goose.log"
export PATH="$tmpdir/bin:$PATH"
ROLLBACK="$tmpdir/repo/scripts/rollback-tenant.sh"
REFUSAL="backend rollback runs an older image on the current schema: restore from backup first if a schema change needs it, then pass --confirm-schema-compatible"

# run_rollback <args...>: runs the script with empty logs; sets RC and OUTPUT.
run_rollback() {
    : > "$DOCKER_LOG"
    : > "$GOOSE_LOG"
    RC=0
    OUTPUT="$(bash "$ROLLBACK" "$@" --config "$tmpdir/config.env" 2>&1)" || RC=$?
}

echo "=== backend rollback without --confirm-schema-compatible ==="
run_rollback acme --to repo/ifritah-api:old
[ "$RC" -eq 1 ] || fail "backend rollback without the flag exited $RC, expected 1"
grep -qF "$REFUSAL" <<< "$OUTPUT" || fail "refusal message is missing or changed"
[ ! -s "$DOCKER_LOG" ] || fail "refused backend rollback reached Dokku: $(cat "$DOCKER_LOG")"
[ ! -s "$GOOSE_LOG" ] || fail "refused backend rollback ran goose"
pass "backend rollback without the flag exits 1 and makes no Dokku call"

echo
echo "=== --all backend rollback without --confirm-schema-compatible ==="
run_rollback --all --to repo/ifritah-api:old
[ "$RC" -eq 1 ] || fail "--all backend rollback without the flag exited $RC, expected 1"
grep -qF "$REFUSAL" <<< "$OUTPUT" || fail "--all refusal message is missing or changed"
[ ! -s "$DOCKER_LOG" ] || fail "refused --all rollback reached Dokku"
pass "--all backend rollback without the flag is refused before any Dokku call"

echo
echo "=== backend rollback with --confirm-schema-compatible ==="
run_rollback acme --to repo/ifritah-api:old --confirm-schema-compatible
[ "$RC" -eq 0 ] || fail "backend rollback with the flag exited $RC: $OUTPUT"
grep -qxF 'exec -i dokku dokku git:from-image acme-backend repo/ifritah-api:old' "$DOCKER_LOG" \
    || fail "backend rollback with the flag did not swap the image"
[ ! -s "$GOOSE_LOG" ] || fail "backend rollback ran goose"
! grep -q '/app/migrate' "$DOCKER_LOG" || fail "backend rollback started the goose container"
pass "backend rollback with the flag swaps the image and makes no goose call"

echo
echo "=== frontend rollback needs no flag ==="
run_rollback acme --type frontend --to repo/ifritah-web:old
[ "$RC" -eq 0 ] || fail "frontend rollback exited $RC: $OUTPUT"
grep -qxF 'exec -i dokku dokku git:from-image acme-frontend repo/ifritah-web:old' "$DOCKER_LOG" \
    || fail "frontend rollback did not swap the image"
[ ! -s "$GOOSE_LOG" ] || fail "frontend rollback ran goose"
pass "frontend rollback is unchanged: swaps the image, no goose"

echo
echo "ALL ROLLBACK TENANT TESTS PASSED"
