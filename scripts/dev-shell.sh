#!/usr/bin/env bash
# =============================================================================
# scripts/dev-shell.sh — TEMPORARY diagnostic shell for the runner sidecar.
# =============================================================================
# ⚠  TEMPORARY. DELETE AS SOON AS THE TENANT PROVISIONING FLOW IS FIXED.
#
# Runs an arbitrary bash command inside the runner sidecar. Meant for one-off
# diagnostics like:
#   docker run --rm --network web curlimages/curl -sS ...
#   docker exec dokku dokku ps:report bx03-backend
#
# Gated: refuses to run unless DASHBOARD_ENV=dev is set on the dashboard
# container. That environment variable is passed to the sidecar in
# dashboard/internal/scripts/scripts.go.
#
# Precedent: PR #41 removed a similar /console feature for RCE reasons.
# This is knowingly re-introducing it in a limited form for debugging.
# Ship a PR that deletes this script when done.
# =============================================================================
set -euo pipefail

if [ "${DASHBOARD_ENV:-}" != "dev" ]; then
    echo "[!] dev-shell.sh refused — DASHBOARD_ENV is not 'dev' (got '${DASHBOARD_ENV:-<unset>}')." >&2
    echo "[!] This is a temporary diagnostic tool; delete it once the tenant flow is working." >&2
    exit 2
fi

CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cmd) CMD="$2"; shift 2 ;;
        *)     shift ;;
    esac
done

if [ -z "$CMD" ]; then
    echo "[!] Usage: dev-shell.sh --cmd '<shell command>'" >&2
    exit 2
fi

echo "[dev-shell] cwd: $(pwd)"
echo "[dev-shell] running: $CMD"
echo "[dev-shell] ---------- output ----------"
# Run in a subshell so pipefail on our side doesn't kill the whole script if
# the caller's command exits non-zero — we want to surface the exit code.
set +e
bash -c "$CMD"
rc=$?
set -e
echo "[dev-shell] ---------- end ----------"
echo "[dev-shell] exit=${rc}"
exit "$rc"
