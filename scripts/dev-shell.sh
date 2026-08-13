#!/usr/bin/env bash
# =============================================================================
# scripts/dev-shell.sh — TEMPORARY docker diagnostic runner for the sidecar.
# =============================================================================
# ⚠  TEMPORARY. DELETE AS SOON AS THE TENANT PROVISIONING FLOW IS FIXED.
#
# Runs a `docker ...` command inside the runner sidecar. Restricted to docker
# only (first token must be `docker`) and refuses shell metacharacters (no
# `;`, `|`, `&`, backticks, `$`, `<`, `>`, `\`, newlines). Meant for one-off
# diagnostics like:
#   docker run --rm --network web curlimages/curl -sS http://bx03-backend.web:8090/api/v2/register
#   docker inspect dokku --format '{{...}}'
#   docker port dokku 80/tcp
#
# Gated: refuses to run unless DASHBOARD_ENV=dev is set on the dashboard
# container (passed to the sidecar via dashboard/internal/scripts/scripts.go).
#
# Precedent: PR #41 removed a similar /console feature for RCE reasons.
# This is a knowingly limited reintroduction for debugging. Ship a PR that
# deletes this script when done.
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
    echo "[!] Usage: dev-shell.sh --cmd 'docker <subcommand> [args...]'" >&2
    exit 2
fi

# Reject shell metacharacters so operators can't chain a second command.
# NB: -E's \r/\n match the literal letters r/n; use -P for real CR/LF, and
# a separate check for embedded newlines via a case glob.
if printf '%s' "$CMD" | grep -qE '[|;&`$<>\\]'; then
    echo "[!] dev-shell.sh refused — shell metacharacters not allowed in --cmd." >&2
    echo "[!] Rejected: $CMD" >&2
    exit 2
fi
case "$CMD" in
    *$'\n'*|*$'\r'*)
        echo "[!] dev-shell.sh refused — newlines not allowed in --cmd." >&2
        exit 2
        ;;
esac

# Only allow docker as the first token.
FIRST="$(printf '%s' "$CMD" | awk '{print $1}')"
if [ "$FIRST" != "docker" ]; then
    echo "[!] dev-shell.sh refused — only 'docker ...' commands allowed. Got: '${FIRST}'" >&2
    exit 2
fi

echo "[dev-shell] running: $CMD"
echo "[dev-shell] ---------- output ----------"
set +e
# shellcheck disable=SC2086
$CMD
rc=$?
set -e
echo "[dev-shell] ---------- end ----------"
echo "[dev-shell] exit=${rc}"
exit "$rc"
