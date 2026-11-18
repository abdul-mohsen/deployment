#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

source scripts/lib.sh

declare -A DOCKER_OPTIONS=()
declare -a ADDED_PHASES=()
DOKKU_ADD_FAIL_PHASE=""
DOKKU_DROP_ADD_PHASE=""
DOKKU_LIST_FAIL_PHASE=""

dokku() {
    local command="${1:-}"
    shift || true
    case "$command" in
        docker-options:list)
            local app="${1:-}" phase=""
            shift || true
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--phase" ] && [ "$#" -gt 1 ]; then
                    phase="$2"
                    shift 2
                else
                    shift
                fi
            done
            [ -n "$app" ] && [ -n "$phase" ] || return 2
            [ "$DOKKU_LIST_FAIL_PHASE" != "$phase" ] || return 1
            printf '%s\n' "${DOCKER_OPTIONS[$phase]:-}"
            ;;
        docker-options:add)
            local app="${1:-}" phase="${2:-}" option="${3:-}"
            [ -n "$app" ] && [ -n "$phase" ] && [ -n "$option" ] || return 2
            ADDED_PHASES+=("$phase")
            [ "$DOKKU_ADD_FAIL_PHASE" != "$phase" ] || return 1
            [ "$DOKKU_DROP_ADD_PHASE" = "$phase" ] && return 0
            DOCKER_OPTIONS[$phase]="${DOCKER_OPTIONS[$phase]:-} $option"
            ;;
        *)
            return 2
            ;;
    esac
}

if ! declare -F ensure_dokku_host_gateway >/dev/null; then
    fail "shared host-gateway ensure helper is missing"
fi

expected="--add-host=host.docker.internal:host-gateway"
DOCKER_OPTIONS[deploy]="$expected"
DOCKER_OPTIONS[run]=""
ensure_dokku_host_gateway tenant_acme
[ "${DOCKER_OPTIONS[deploy]}" = "$expected" ] ||
    fail "existing deploy option was changed"
[[ "${DOCKER_OPTIONS[run]}" == *"$expected"* ]] ||
    fail "missing run option was not added"
[ "$DOKKU_HOST_GATEWAY_ADDED" = "true" ] ||
    fail "helper did not report that a new host-gateway option was added"
[ "${#ADDED_PHASES[@]}" -eq 1 ] && [ "${ADDED_PHASES[0]}" = "run" ] ||
    fail "helper did not add only the missing phase"
pass "existing and missing phases are reconciled independently"

calls_before="${#ADDED_PHASES[@]}"
ensure_dokku_host_gateway tenant_acme
[ "${#ADDED_PHASES[@]}" -eq "$calls_before" ] ||
    fail "helper added a duplicate option on a repeated rollout"
[ "$DOKKU_HOST_GATEWAY_ADDED" = "false" ] ||
    fail "idempotent ensure reported a new host-gateway option"
pass "host-gateway setup is idempotent"

DOCKER_OPTIONS[deploy]=""
DOCKER_OPTIONS[run]=""
DOKKU_ADD_FAIL_PHASE=deploy
if ensure_dokku_host_gateway tenant_broken >/dev/null 2>&1; then
    fail "Dokku add failure was suppressed"
fi
pass "Dokku add failure is surfaced"

DOKKU_ADD_FAIL_PHASE=""
DOKKU_DROP_ADD_PHASE=run
if ensure_dokku_host_gateway tenant_broken >/dev/null 2>&1; then
    fail "missing post-add option was not detected"
fi
pass "post-add option state is verified"

DOKKU_DROP_ADD_PHASE=""
DOKKU_LIST_FAIL_PHASE=deploy
if ensure_dokku_host_gateway tenant_broken >/dev/null 2>&1; then
    fail "Dokku list failure was suppressed"
fi
pass "Dokku option inspection failure is surfaced"

echo "All host-gateway checks passed."
