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
tmpdir=$(mktemp -d)
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
echo "=== dokku container attached to tenant network ==="
if grep -q "docker network connect \"\$TENANT_NETWORK\" \"\$DOKKU_CONTAINER\"" scripts/create-tenant.sh; then
    pass "dokku container is attached to the tenant network"
else
    fail "dokku container is NOT attached to tenant network — dokku's nginx will 502 when proxying <app>.web hostnames"
fi

echo ""
echo "=== all create-tenant.sh tests passed ==="
