#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

script="scripts/generate-zatca-secrets.sh"
default_dir="$tmpdir/default"
mkdir -p "$default_dir"
generated_env="$default_dir/.env"
output="$tmpdir/output"

echo "=== generation and private permissions ==="
(
    cd "$default_dir"
    bash "$REPO_DIR/$script" >"$output"
)

for key in ZATCA_DB_PASSWORD NATS_PASSWORD ZATCA_MONITOR_PASSWORD; do
    grep -Eq "^${key}=[[:xdigit:]]{64}$" "$generated_env" \
        || fail "$key is not a 32-byte hex value"
done
grep -Eq '^ZATCA_ENCRYPT_KEY=[A-Za-z0-9+/]{43}=$' "$generated_env" \
    || fail "ZATCA_ENCRYPT_KEY is not a Base64-encoded 32-byte key"

for key in ZATCA_DB_PASSWORD NATS_PASSWORD ZATCA_ENCRYPT_KEY ZATCA_MONITOR_PASSWORD; do
    count=$(grep -c "^${key}=" "$generated_env" || true)
    [[ "$count" == 1 ]] || fail "$key was not written exactly once"
done
[[ "$(stat -c '%a' "$generated_env")" == 600 ]] \
    || fail "generated env file permissions are not 600"
if grep -q '=' "$output"; then
    fail "script output may contain a secret value"
fi
pass "generated all four secrets without printing their values"

echo
echo "=== existing values and unrelated entries ==="
existing_dir="$tmpdir/existing"
mkdir -p "$existing_dir"
existing_env="$existing_dir/.env"
cat > "$existing_env" <<'EOF'
# keep this comment
KEEP_ME=retain-this-line
export ZATCA_DB_PASSWORD=
NATS_PASSWORD=already-configured-sentinel
ZATCA_ENCRYPT_KEY=existing-key-placeholder
ZATCA_MONITOR_PASSWORD=""
EOF
chmod 644 "$existing_env"
(
    cd "$existing_dir"
    bash "$REPO_DIR/$script" >"$output"
)

grep -qxF '# keep this comment' "$existing_env" || fail "comment was not preserved"
grep -qxF 'KEEP_ME=retain-this-line' "$existing_env" || fail "unrelated setting was not preserved"
grep -qxF 'NATS_PASSWORD=already-configured-sentinel' "$existing_env" \
    || fail "non-empty NATS password was changed"
grep -qxF 'ZATCA_ENCRYPT_KEY=existing-key-placeholder' "$existing_env" \
    || fail "non-empty encryption key was changed"
grep -Eq '^export ZATCA_DB_PASSWORD=[[:xdigit:]]{64}$' "$existing_env" \
    || fail "empty exported DB password was not filled or export semantics changed"
grep -Eq '^ZATCA_MONITOR_PASSWORD=[[:xdigit:]]{64}$' "$existing_env" \
    || fail "empty monitor password was not filled"
[[ "$(stat -c '%a' "$existing_env")" == 600 ]] \
    || fail "existing env file permissions were not tightened to 600"

cp "$existing_env" "$tmpdir/before-rerun"
(
    cd "$existing_dir"
    bash "$REPO_DIR/$script" >"$output"
)
cmp -s "$tmpdir/before-rerun" "$existing_env" \
    || fail "rerunning changed already-set values or file contents"
pass "empty values filled, configured values preserved, reruns do not rotate"

echo
echo "=== alternate target rejection ==="
alternate_target="$tmpdir/alternate.env"
if bash "$script" "$alternate_target" >"$output" 2>&1; then
    fail "alternate target path was accepted"
fi
[[ ! -e "$alternate_target" ]] || fail "alternate target was created"
pass "alternate target paths are rejected without creating the target file"

echo
echo "=== ambiguous input rejection ==="
duplicate_dir="$tmpdir/duplicate"
mkdir -p "$duplicate_dir"
duplicate_env="$duplicate_dir/.env"
printf 'ZATCA_DB_PASSWORD=first-sentinel\nZATCA_DB_PASSWORD=second-sentinel\n' > "$duplicate_env"
cp "$duplicate_env" "$tmpdir/duplicate-before"
if (cd "$duplicate_dir" && bash "$REPO_DIR/$script" >"$output" 2>&1); then
    fail "duplicate secret assignments were accepted"
fi
cmp -s "$tmpdir/duplicate-before" "$duplicate_env" \
    || fail "duplicate-file rejection changed the file"
if grep -Eq 'first-sentinel|second-sentinel' "$output"; then
    fail "duplicate-file error exposed an existing value"
fi
pass "duplicate secret assignments are rejected without modifying the file"

echo
echo "=== symlink rejection ==="
symlink_dir="$tmpdir/symlink"
mkdir -p "$symlink_dir"
target_env="$tmpdir/target.env"
link_env="$symlink_dir/.env"
printf 'KEEP_ME=unchanged\n' > "$target_env"
ln -s "$target_env" "$link_env"
if (cd "$symlink_dir" && bash "$REPO_DIR/$script" >"$output" 2>&1); then
    fail "symlink env target was accepted"
fi
grep -qxF 'KEEP_ME=unchanged' "$target_env" || fail "symlink target was changed"
pass "symlink env targets are rejected"
