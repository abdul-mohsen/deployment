#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-dev-shell.sh — unit tests for dev-shell.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== syntax ==="
bash -n scripts/dev-shell.sh && pass "syntax dev-shell.sh"

echo ""
echo "=== refuses to run without DASHBOARD_ENV=dev ==="
unset DASHBOARD_ENV
rc=0
out="$(bash scripts/dev-shell.sh --cmd 'docker ps' 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit=2, got $rc"
echo "$out" | grep -q "refused" && pass "prints refusal message" || fail "no refusal message"

DASHBOARD_ENV=prod
rc=0
out="$(bash scripts/dev-shell.sh --cmd 'docker ps' 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit=2 in prod, got $rc"
echo "$out" | grep -q "refused" && pass "refuses when DASHBOARD_ENV=prod" || fail "did not refuse for prod"

echo ""
echo "=== only allows docker as first token ==="
export DASHBOARD_ENV=dev
rc=0
out="$(bash scripts/dev-shell.sh --cmd 'echo hello' 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "rejects 'echo' as first token" || fail "did not reject echo (rc=$rc)"
echo "$out" | grep -q "only 'docker" && pass "prints docker-only refusal" || fail "no docker-only message"

rc=0
out="$(bash scripts/dev-shell.sh --cmd 'ls /' 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "rejects 'ls' as first token" || fail "did not reject ls"

echo ""
echo "=== rejects shell metacharacters ==="
for evil in 'docker ps; rm -rf /' 'docker ps | cat' 'docker ps && echo hi' 'docker ps `whoami`' 'docker ps $HOME' 'docker ps > /tmp/x'; do
    rc=0
    out="$(bash scripts/dev-shell.sh --cmd "$evil" 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] && pass "rejects: $evil" || fail "did NOT reject: $evil (rc=$rc)"
done

echo ""
echo "=== accepts a safe docker command ==="
# Since docker may not be installed in the test env, we just check the
# script gets past the validation and attempts to run. Use docker --version
# which either succeeds (docker installed) or fails with 'command not found'
# — either way the validation passed and the run stage was reached.
rc=0
out="$(bash scripts/dev-shell.sh --cmd 'docker --version' 2>&1)" || rc=$?
echo "$out" | grep -q "\[dev-shell\] running:" && pass "reaches run stage for 'docker --version'" || fail "did not reach run stage"
echo "$out" | grep -q "exit=" && pass "records exit code" || fail "no exit line"

echo ""
echo "=== rejects empty --cmd ==="
rc=0
out="$(bash scripts/dev-shell.sh 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "usage error exits 2" || fail "expected exit=2, got $rc"

echo ""
echo "=== all dev-shell.sh tests passed ==="
