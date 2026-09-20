#!/usr/bin/env bash
# =============================================================================
# scripts/tests/test-create-tenant.sh — unit tests for create-tenant.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== syntax ==="
bash -n scripts/create-tenant.sh && pass "syntax create-tenant.sh"

echo ""
echo "=== tenant operation logs redact secret env values ==="
redaction_tmpdir="$REPO_DIR/.test-create-tenant-redaction.$$"
mkdir -p "$redaction_tmpdir/logs"
trap 'rm -rf "${tmpdir:-}" "$redaction_tmpdir"' EXIT
cat > "$redaction_tmpdir/config.env" <<'EOF'
BASE_DOMAIN=example.test
PUBLIC_PROTOCOL=https
EOF

redaction_output="$(
    LOG_DIR="$redaction_tmpdir/logs" \
    bash scripts/create-tenant.sh redaction-test \
        --dry-run \
        --no-database \
        --config "$redaction_tmpdir/config.env" \
        --env "DB_PASSWORD=tenant-password-marker" \
        --env "API_TOKEN=tenant-token-marker" \
        --env "PARTNER_API_KEY=tenant-api-key-marker" \
        --env "PUBLIC_SETTING=visible-value" \
        --env "DATABASE_URL=mysql://user:database-url-marker@example.test/db" \
        2>&1
)"
redaction_log="$(cat "$redaction_tmpdir"/logs/*.log)"
combined_redaction_log="${redaction_output}
${redaction_log}"
for marker in \
    tenant-password-marker \
    tenant-token-marker \
    tenant-api-key-marker \
    database-url-marker; do
    if printf '%s\n' "$combined_redaction_log" | grep -Fq "$marker"; then
        fail "secret marker leaked into tenant operation logs: $marker"
    fi
done
for redacted in \
    'DB_PASSWORD=***' \
    'API_TOKEN=***' \
    'PARTNER_API_KEY=***' \
    'DATABASE_URL=***'; do
    printf '%s\n' "$combined_redaction_log" | grep -Fq "$redacted" \
        || fail "missing redacted env diagnostic: $redacted"
done
printf '%s\n' "$combined_redaction_log" | grep -Fq 'PUBLIC_SETTING=visible-value' \
    || fail "non-secret env diagnostic was removed"
pass "tenant operation logs keep env keys and redact secret values"

echo ""
echo "=== ensure_storage_mount is idempotent ==="
# Extract the ensure_storage_mount function and test it with a stubbed dokku.
if grep -q "ensure_storage_mount" scripts/create-tenant.sh; then
    pass "ensure_storage_mount helper exists"
else
    fail "ensure_storage_mount helper missing — storage:mount would fail on re-run"
fi

if ! grep -qE '^dokku storage:mount.*STORAGE_ROOT.*\$BACKEND_APP' scripts/create-tenant.sh; then
    pass "storage:mount is NOT called unconditionally"
else
    fail "unconditional dokku storage:mount call still present"
fi

# Function-level test with stub dokku
tmpdir="$REPO_DIR/scripts/tests/.test-create-tenant.$$"
mkdir -p "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/dokku" <<'EOF'
#!/usr/bin/env bash
# stub: fake `storage:list` returns one pre-existing mount, `storage:mount` records calls
case "$1" in
    storage:list) echo "/host/uploads:/app/uploads" ;;
    storage:mount)
        echo "MOUNTED: $3" >> "$STUB_LOG"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmpdir/dokku"
export PATH="$tmpdir:$PATH"
export STUB_LOG="$tmpdir/mounts.log"
touch "$STUB_LOG"

# extract just the ensure_storage_mount function (plus info() stub) and exercise it
info() { echo "[i] $*"; }
eval "$(awk '/^ensure_storage_mount\(\)/,/^\}$/' scripts/create-tenant.sh)"

ensure_storage_mount myapp "/host/uploads:/app/uploads"
ensure_storage_mount myapp "/host/data:/app/data"

# First should have been a no-op (existed), second should have mounted
mounted=$(cat "$STUB_LOG")
if echo "$mounted" | grep -qF "/host/data:/app/data" && ! echo "$mounted" | grep -qF "/host/uploads:/app/uploads"; then
    pass "ensure_storage_mount mounts new paths, skips existing"
else
    echo "MOUNTED log: $mounted"
    fail "ensure_storage_mount behaviour is wrong"
fi

echo ""
echo "=== MySQL password SQL literal escaping ==="
eval "$(awk '/^mysql_password_sql_literal\(\)/,/^\}$/' scripts/create-tenant.sh)"

quote_input="quote'\"value"
quote_expected="'quote''\"value'"
[ "$(mysql_password_sql_literal "$quote_input")" = "$quote_expected" ] \
    && pass "single quotes are doubled in password literals" \
    || fail "single quote escaping is incorrect"

backslash_input='back\slash\\value'
backslash_expected="'$backslash_input'"
[ "$(mysql_password_sql_literal "$backslash_input")" = "$backslash_expected" ] \
    && pass "backslashes remain literal under NO_BACKSLASH_ESCAPES" \
    || fail "backslash handling is incorrect"

metachar_input='$(touch should-not-run);`command` -- comment # $HOME'
metachar_expected="'$metachar_input'"
[ "$(mysql_password_sql_literal "$metachar_input")" = "$metachar_expected" ] \
    && pass "shell and SQL metacharacters remain inside the literal" \
    || fail "metacharacter handling is incorrect"

if grep -qF "SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'NO_BACKSLASH_ESCAPES');" scripts/create-tenant.sh; then
    pass "password SQL uses a backslash-safe MySQL session mode"
else
    fail "password SQL does not force NO_BACKSLASH_ESCAPES"
fi

if grep -qF "run_mysql --binary-mode <<SQLEOF" scripts/create-tenant.sh; then
    pass "mysql batch mode does not interpret password backslash commands"
else
    fail "mysql provisioning is missing binary batch mode"
fi

if grep -qF "IDENTIFIED BY '\${TENANT_DB_PASS}'" scripts/create-tenant.sh; then
    fail "raw tenant password interpolation remains in MySQL SQL"
else
    pass "raw tenant password interpolation is absent"
fi

echo ""
echo "=== dokku container attached to tenant network ==="
if grep -q "docker network connect \"\$TENANT_NETWORK\" \"\$DOKKU_CONTAINER\"" scripts/create-tenant.sh; then
    pass "dokku container is attached to the tenant network"
else
    fail "dokku container is NOT attached to tenant network — dokku's nginx will 502 when proxying <app>.web hostnames"
fi

echo ""
echo "=== all create-tenant.sh tests passed ==="
