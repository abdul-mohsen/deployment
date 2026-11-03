#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

apply="dashboard/observability/openobserve/apply-openobserve.sh"
[ -f "$apply" ] || fail "missing OpenObserve apply script"

bash -n "$apply" || fail "OpenObserve apply script has invalid shell syntax"
grep -Fq 'AUTH=(--config "$AUTH_CONFIG")' "$apply" \
    || fail "curl calls do not use the generated credential config"
grep -Fq 'chmod 600 "$AUTH_CONFIG"' "$apply" \
    || fail "credential config permissions are not restricted"
grep -Fq 'trap cleanup_auth_config EXIT' "$apply" \
    || fail "credential config cleanup is not registered"
grep -Fq 'rm -f -- "$AUTH_CONFIG"' "$apply" \
    || fail "credential config cleanup is missing"
grep -Fq 'mktemp "$SCRIPT_DIR/.openobserve-curl-auth.XXXXXX"' "$apply" \
    || fail "credential config is not created in the script work area"
if grep -Fq 'AUTH=(-u' "$apply" || grep -Fq -- '--user "$USER_NAME:$PASSWORD"' "$apply"; then
    fail "OpenObserve password is still passed through curl user arguments"
fi
pass "OpenObserve authentication uses a cleaned-up restrictive config file"

scratch="$REPO_DIR/.openobserve-password-file-test.$$"
rm -rf "$scratch"
mkdir -p "$scratch/bin"
trap 'rm -rf "$scratch"' EXIT

secret="file-mounted-password-not-for-argv"
printf '%s' "$secret" > "$scratch/password"
chmod 600 "$scratch/password"
: > "$scratch/curl-args.log"
: > "$scratch/config-seen.log"
mode_probe="$scratch/mode-probe"
: > "$mode_probe"
chmod 600 "$mode_probe"
expected_mode="$(stat -c '%a' "$mode_probe")"
rm -f "$mode_probe"

cat > "$scratch/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${OPENOBSERVE_FAKE_CURL_LOG:?}"
seen="${OPENOBSERVE_FAKE_CONFIG_SEEN:?}"
config_path=""

for arg in "$@"; do
    printf 'arg=%s\n' "$arg" >> "$log"
done

while (($#)); do
    case "$1" in
        --config)
            config_path="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -z "$config_path" ]]; then
    printf 'config_missing\n' >> "$seen"
    exit 1
fi

printf 'config_path=%s\n' "$config_path" >> "$seen"
if [[ -f "$config_path" ]]; then
    printf 'config_exists=yes\n' >> "$seen"
else
    printf 'config_exists=no\n' >> "$seen"
fi
if [[ -f "$config_path" && "$(stat -c '%a' "$config_path")" == "${OPENOBSERVE_EXPECTED_MODE:?}" ]]; then
    printf 'config_mode=expected\n' >> "$seen"
else
    printf 'config_mode=unexpected\n' >> "$seen"
fi

if python3 - "$config_path" <<'PY'
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    contents = handle.read()
if not contents.startswith('user = "operator:'):
    raise SystemExit(1)
if os.environ["OPENOBSERVE_TEST_SECRET"] not in contents:
    raise SystemExit(1)
PY
then
    printf 'config_contains_expected_credential=yes\n' >> "$seen"
else
    printf 'config_contains_expected_credential=no\n' >> "$seen"
fi

printf '503'
EOF
chmod 700 "$scratch/bin/curl"

unset OPENOBSERVE_PASSWORD
set +e
PATH="$scratch/bin:$PATH" \
OPENOBSERVE_ENDPOINT="http://openobserve.invalid" \
OPENOBSERVE_ORG="default" \
OPENOBSERVE_USER="operator" \
OPENOBSERVE_PASSWORD_FILE="$scratch/password" \
OPENOBSERVE_FAKE_CURL_LOG="$scratch/curl-args.log" \
OPENOBSERVE_FAKE_CONFIG_SEEN="$scratch/config-seen.log" \
OPENOBSERVE_EXPECTED_MODE="$expected_mode" \
OPENOBSERVE_TEST_SECRET="$secret" \
bash "$apply" > "$scratch/apply-output.log" 2>&1
status=$?
set -e

[ "$status" -ne 0 ] || fail "health-check failure was unexpectedly swallowed"
grep -Fq 'OpenObserve health check returned HTTP 503' "$scratch/apply-output.log" \
    || fail "health-check failure output changed"
grep -Fq 'arg=--config' "$scratch/curl-args.log" \
    || fail "curl was not given the credential config"
if grep -Fxq 'arg=-u' "$scratch/curl-args.log" ||
    grep -Fxq 'arg=--user' "$scratch/curl-args.log"; then
    fail "curl received a user/password argument"
fi
if grep -Fq "$secret" "$scratch/curl-args.log" ||
    grep -Fq "$secret" "$scratch/apply-output.log"; then
    fail "file-mounted password appeared in curl arguments or output"
fi
grep -Fq 'config_exists=yes' "$scratch/config-seen.log" \
    || fail "curl could not read the generated credential config"
grep -Fq 'config_mode=expected' "$scratch/config-seen.log" \
    || fail "generated credential config did not retain the requested restrictive mode"
grep -Fq 'config_contains_expected_credential=yes' "$scratch/config-seen.log" \
    || fail "generated credential config did not contain file-mounted credentials"
config_path="$(sed -n 's/^config_path=//p' "$scratch/config-seen.log")"
[ -n "$config_path" ] || fail "fake curl did not record the credential config path"
[ ! -e "$config_path" ] || fail "credential config was not removed on exit"
if compgen -G "$apply/.openobserve-curl-auth.*" > /dev/null; then
    fail "credential config was left beside the apply script"
fi
pass "file-mounted password stays out of curl argv/logs and cleanup runs on failure"

echo
echo "ALL OPENOBSERVE PASSWORD-FILE TESTS PASSED"
