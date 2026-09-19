#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== shared shell log fields ==="
line="$(
    DEPLOY_OPERATION_ID=test-op \
    DEPLOY_SCRIPT_NAME=test-script.sh \
    DEPLOY_TENANT=acme \
    DEPLOY_LOG_STDERR=1 \
    bash -c 'source <(tr -d "\r" < scripts/lib.sh); deployment_init_logging; deployment_log WARN "hello world"' 2>&1 |
        tail -n 1
)"
printf '%s\n' "$line" |
    grep -Eq '^timestamp=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z severity=WARN script=test-script\.sh operation_id=test-op tenant=acme message=' \
    || fail "structured shell fields are incomplete: $line"
pass "UTC timestamp, severity, script, operation ID, and tenant are emitted"

echo
echo "=== ERR trap ==="
failure="$(
    DEPLOY_OPERATION_ID=trap-op \
    DEPLOY_SCRIPT_NAME=trap-script.sh \
    DEPLOY_TENANT=acme \
    DEPLOY_LOG_STDERR=1 \
    bash -c 'set -euo pipefail; source <(tr -d "\r" < scripts/lib.sh); deployment_init_logging; false' 2>&1 || true
)"
printf '%s\n' "$failure" | grep -q 'severity=ERROR' \
    || fail "ERR trap did not emit an error event: $failure"
printf '%s\n' "$failure" | grep -q 'operation_id=trap-op' \
    || fail "ERR trap lost the operation ID: $failure"
if printf '%s\n' "$failure" | grep -q 'message=.*false'; then
    fail "ERR trap exposed failed command text"
fi
pass "ERR trap correlates failures without command text"

echo
echo "=== conditional deployment boundary ==="
boundary="$(
    DEPLOY_OPERATION_ID=boundary-op \
    DEPLOY_TENANT=acme \
    DEPLOY_LOG_STDERR=1 \
    bash -c 'set -euo pipefail; source <(tr -d "\r" < scripts/lib.sh); deployment_init_logging; failing_deploy() { return 7; }; if deployment_run_boundary deploy_one failing_deploy; then exit 99; fi' 2>&1 ||
        true
)"
printf '%s\n' "$boundary" | grep -q 'operation_boundary' \
    || fail "conditional deployment boundary did not emit a status event: $boundary"
printf '%s\n' "$boundary" | grep -q 'status=failed' \
    || fail "conditional deployment boundary omitted failed status: $boundary"
printf '%s\n' "$boundary" | grep -q 'exit_code=7' \
    || fail "conditional deployment boundary omitted exit code: $boundary"
if printf '%s\n' "$boundary" | grep -q 'operation failed exit_code=7'; then
    fail "conditional deploy emitted a duplicate ERR event: $boundary"
fi
if [ "$(printf '%s\n' "$boundary" | grep -c 'operation_boundary' || true)" -ne 1 ]; then
    fail "conditional deployment boundary emitted duplicate status events: $boundary"
fi
pass "conditional deploy failures have one explicit boundary status"

echo
echo "=== bounded optional file sink ==="
sink_dir="$REPO_DIR/.test-logging-contract.$$"
sink_file="$sink_dir/deployment.log"
mkdir -p "$sink_dir"
trap 'rm -rf "$sink_dir"' EXIT
DEPLOY_LOG_STDERR=0 \
DEPLOY_LOG_FILE="$sink_file" \
DEPLOY_LOG_MAX_BYTES=1024 \
bash -c 'source <(tr -d "\r" < scripts/lib.sh); deployment_init_logging; for i in $(seq 1 100); do deployment_log INFO "bounded event ${i}"; done'
[ -f "$sink_file" ] || fail "bounded log sink was not written"
[ -f "${sink_file}.1" ] || fail "bounded log sink did not rotate"
sink_bytes="$(( $(wc -c < "$sink_file") + $(wc -c < "${sink_file}.1") ))"
[ "$sink_bytes" -le 3000 ] || fail "bounded log sink exceeded rotation budget: ${sink_bytes} bytes"
mkdir "$sink_dir/failure-target"
failure_sink="$(
    DEPLOY_LOG_STDERR=0 \
    DEPLOY_LOG_FILE="$sink_dir/failure-target" \
    bash -c 'source <(tr -d "\r" < scripts/lib.sh); deployment_init_logging' 2>&1 || true
)"
printf '%s\n' "$failure_sink" | grep -q 'sink.*disabled' \
    || fail "file sink write failure was silent: $failure_sink"
pass "optional file sink rotates and fails visibly"

echo
echo "=== entrypoint wiring ==="
for script in \
    scripts/deployctl.sh \
    scripts/update-tenant.sh \
    scripts/deploy-all.sh \
    scripts/init-tenant-db.sh \
    scripts/backup-tenant.sh \
    scripts/auto-pull.sh \
    scripts/restart-stack.sh \
    update.sh \
    dashboard/prod-up.sh; do
    tr -d '\r' < "$script" | bash -n || fail "syntax $script"
    grep -q 'deployment_init_logging' "$script" || fail "$script lacks shared logging initialization"
    pass "$script wires shared logging"
done

grep -q 'docker logs --tail' dashboard/prod-up.sh \
    || fail "prod-up failure reporting is not bounded"
grep -q 'docker inspect' dashboard/prod-up.sh \
    || fail "prod-up failure reporting omits container state"
grep -q 'cut -c1-2048' dashboard/prod-up.sh \
    || fail "prod-up failure reporting does not bound container state"
if grep -q 'error={{\.State\.Error}}' dashboard/prod-up.sh; then
    fail "prod-up failure reporting exposes raw container error text"
fi
pass "prod-up reports bounded logs and container state without rollback"

echo
echo "=== observability socket boundary ==="
observability_compose="dashboard/docker-compose.observability.yml"
alloy_config="dashboard/observability/alloy/config.alloy"
filter_config="dashboard/observability/docker-api-filter/nginx.conf"
proxy_block="$(awk '/^  docker-socket-proxy:/{section=1} /^  docker-api-filter:/{section=0} section{print}' "$observability_compose")"
filter_block="$(awk '/^  docker-api-filter:/{section=1} /^  alloy:/{section=0} section{print}' "$observability_compose")"
alloy_block="$(awk '/^  alloy:/{section=1} /^  loki:/{section=0} section{print}' "$observability_compose")"
printf '%s\n' "$proxy_block" | grep -q 'tecnativa/docker-socket-proxy:0.1.2@sha256:' \
    || fail "socket proxy image is not pinned"
printf '%s\n' "$proxy_block" | grep -q 'networks: \[docker-api\]' \
    || fail "socket proxy is not isolated on docker-api"
if printf '%s\n' "$proxy_block" | grep -q 'networks: \[observability\]'; then
    fail "socket proxy still joins the observability network"
fi
printf '%s\n' "$proxy_block" | grep -q '/var/run/docker.sock:/var/run/docker.sock:ro' \
    || fail "socket proxy socket mount is not read-only"
printf '%s\n' "$proxy_block" | grep -q 'read_only: true' \
    || fail "socket proxy filesystem is not read-only"
printf '%s\n' "$proxy_block" | grep -q 'cap_drop: \[ALL\]' \
    || fail "socket proxy does not drop Linux capabilities"
printf '%s\n' "$proxy_block" | grep -q 'mem_limit: 128m' \
    || fail "socket proxy memory budget is missing"
printf '%s\n' "$proxy_block" | grep -q 'cpus: "0.25"' \
    || fail "socket proxy CPU budget is missing"
if printf '%s\n' "$proxy_block" | grep -Eq 'privileged:|^[[:space:]]+ports:'; then
    fail "socket proxy exposes privileged or host-published access"
fi
printf '%s\n' "$filter_block" | grep -q 'nginx:1.27.1-alpine@sha256:' \
    || fail "Docker API path filter image is not pinned"
printf '%s\n' "$filter_block" | grep -q 'networks: \[docker-api, observability\]' \
    || fail "Docker API path filter does not bridge private networks"
printf '%s\n' "$filter_block" | grep -q './observability/docker-api-filter/nginx.conf:/etc/nginx/nginx.conf:ro' \
    || fail "Docker API path filter config is not mounted read-only"
printf '%s\n' "$filter_block" | grep -q 'read_only: true' \
    || fail "Docker API path filter filesystem is not read-only"
if printf '%s\n' "$filter_block" | grep -Eq '^[[:space:]]+ports:'; then
    fail "Docker API path filter publishes a host port"
fi
for setting in \
    'CONTAINERS: "1"' \
    'EVENTS: "1"' \
    'POST: "0"' \
    'DELETE: "0"' \
    'EXEC: "0"' \
    'PING: "1"' \
    'VERSION: "1"' \
    'ALLOW_START: "0"' \
    'ALLOW_STOP: "0"' \
    'ALLOW_RESTARTS: "0"' \
    'ALLOW_PAUSE: "0"' \
    'ALLOW_UNPAUSE: "0"'; do
    printf '%s\n' "$proxy_block" | grep -q "$setting" \
        || fail "socket proxy missing allowlist setting: $setting"
done
if printf '%s\n' "$alloy_block" | grep -q '/var/run/docker.sock'; then
    fail "Alloy still mounts the host Docker socket"
fi
if printf '%s\n' "$alloy_block" | grep -q 'docker-socket-proxy'; then
    fail "Alloy still addresses the socket proxy directly"
fi
grep -q 'alloy-data:/var/lib/alloy' "$observability_compose" \
    || fail "Alloy positions volume is missing"
grep -q -- '--storage.path=/var/lib/alloy' "$observability_compose" \
    || fail "Alloy storage path is not explicit"
grep -q 'http://docker-api-filter:2375' "$alloy_config" \
    || fail "Alloy is not configured through the Docker API path filter"
if grep -q 'http://docker-socket-proxy:2375' "$alloy_config"; then
    fail "Alloy config bypasses the Docker API path filter"
fi
grep -Fq 'containers/[A-Za-z0-9_.-]+/logs' "$filter_config" \
    || fail "Docker API path filter does not allow log paths"
if grep -Fq 'containers/[A-Za-z0-9_.-]+/(?:json|logs)' "$filter_config"; then
    fail "Docker API path filter still allows container JSON/inspect paths"
fi
if ! awk '
    index($0, "containers/[A-Za-z0-9_.-]+/(?:json|archive|attach|exec)") {
        in_deny = 1
    }
    in_deny && index($0, "return 403;") {
        found = 1
        exit
    }
    END { exit(found ? 0 : 1) }
' "$filter_config"; then
    fail "Docker API path filter does not deny json/archive/attach/exec"
fi
grep -Fq 'location / {' "$filter_config" \
    || fail "Docker API path filter lacks a default deny location"
grep -A1 -F 'location / {' "$filter_config" | grep -Fq 'return 403;' \
    || fail "Docker API path filter default path is not denied"
tr -d '\r' < .gitignore | grep -qx 'dashboard/observability/\.env' \
    || fail "observability credentials file is not ignored"
pass "observability uses a pinned read-only Docker API allowlist"

echo
echo "ALL LOGGING CONTRACT TESTS PASSED"
