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
out="$(bash scripts/dev-shell.sh --cmd 'echo hi' 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit=2, got $rc"
echo "$out" | grep -q "refused" && pass "prints refusal message" || fail "no refusal message: $out"

DASHBOARD_ENV=prod
out="$(bash scripts/dev-shell.sh --cmd 'echo hi' 2>&1)" || rc=$?
echo "$out" | grep -q "refused" && pass "refuses when DASHBOARD_ENV=prod" || fail "did not refuse for prod"

echo ""
echo "=== runs when DASHBOARD_ENV=dev ==="
export DASHBOARD_ENV=dev
out="$(bash scripts/dev-shell.sh --cmd 'echo hello-world' 2>&1)"
echo "$out" | grep -q "hello-world" && pass "runs command and captures output" || fail "no output: $out"
echo "$out" | grep -q "exit=0" && pass "records exit code 0" || fail "no exit line: $out"

echo ""
echo "=== surfaces non-zero exit ==="
rc=0
out="$(bash scripts/dev-shell.sh --cmd 'exit 42' 2>&1)" || rc=$?
[ "$rc" -eq 42 ] && pass "propagates exit 42" || fail "expected exit=42, got $rc"
echo "$out" | grep -q "exit=42" && pass "logs exit=42" || fail "no exit=42 in output: $out"

echo ""
echo "=== rejects empty --cmd ==="
rc=0
out="$(bash scripts/dev-shell.sh 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "usage error exits 2" || fail "expected exit=2, got $rc"

echo ""
echo "=== all dev-shell.sh tests passed ==="
