#!/usr/bin/env bash
# =============================================================================
# scripts/tests/run-all.sh — run every local test in the repo.
# =============================================================================
# Runs shell-script tests + Go tests + syntax checks. Exit 0 if all pass.
# Meant to be the single command to run before opening a PR.
#
# Usage:
#   bash scripts/tests/run-all.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

echo "========================================"
echo " Running all local tests"
echo "========================================"

FAILED=0
RAN=0

echo ""
echo "--- syntax check every .sh in scripts/ ---"
for f in scripts/*.sh scripts/tests/*.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f"; then
        echo "  ok: $f"
    else
        echo "  FAIL: $f"
        FAILED=$((FAILED + 1))
    fi
    RAN=$((RAN + 1))
done

echo ""
echo "--- shell test scripts (scripts/tests/test-*.sh) ---"
for t in scripts/tests/test-*.sh; do
    [ -f "$t" ] || continue
    echo ">>> $t"
    if bash "$t"; then
        echo "  ok: $t"
    else
        echo "  FAIL: $t"
        FAILED=$((FAILED + 1))
    fi
    RAN=$((RAN + 1))
done

echo ""
echo "--- go build (dashboard) ---"
(cd dashboard && go build ./...) && echo "  ok: go build" || { echo "  FAIL: go build"; FAILED=$((FAILED + 1)); }
RAN=$((RAN + 1))

echo ""
echo "--- go vet (dashboard) ---"
(cd dashboard && go vet ./...) && echo "  ok: go vet" || { echo "  FAIL: go vet"; FAILED=$((FAILED + 1)); }
RAN=$((RAN + 1))

echo ""
echo "--- go test (dashboard) ---"
(cd dashboard && go test ./...) && echo "  ok: go test" || { echo "  FAIL: go test"; FAILED=$((FAILED + 1)); }
RAN=$((RAN + 1))

echo ""
echo "========================================"
if [ "$FAILED" -eq 0 ]; then
    echo " ALL $RAN CHECKS PASSED"
    exit 0
else
    echo " $FAILED / $RAN CHECKS FAILED"
    exit 1
fi
