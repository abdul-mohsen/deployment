#!/usr/bin/env bash
# Local test for the changes in fix/auto-ensure-dokku.
# Uses an alpine container as a stand-in for "dokku" so we can exercise
# ensure_dokku_running / restart-stack.sh without needing a real Dokku install.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

PASS() { echo "PASS: $*"; }
FAIL() { echo "FAIL: $*"; exit 1; }

echo "=== 1. bash -n on changed scripts ==="
for f in scripts/lib.sh scripts/setup-dokku.sh scripts/restart-stack.sh; do
    bash -n "$f" && PASS "syntax $f" || FAIL "syntax $f"
done

echo
echo "=== 2. setup-dokku.sh reads install.env ==="
[ -f install.env ] && cp install.env install.env.bak
trap '[ -f install.env.bak ] && mv install.env.bak install.env || rm -f install.env' EXIT
cat > install.env <<EOF
DOKKU_PORT=18082
DOKKU_HOSTNAME=test.example.com
EOF

# Inject a fake `docker` to short-circuit before any real container ops.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "Docker (stub)"; exit 0; fi
if [ "$1" = "ps" ]; then exit 0; fi  # pretend no dokku container
if [ "$1" = "run" ]; then
    echo "STUB-DOCKER-RUN: $*" >&2
    exit 99   # bail out before any wait loop
fi
exit 0
STUB
chmod +x "$STUB_DIR/docker"

OUT="$(PATH="$STUB_DIR:$PATH" bash scripts/setup-dokku.sh 2>&1 || true)"
echo "$OUT" | grep -q '18082->80' && PASS "DOKKU_PORT from install.env honored" \
    || { echo "$OUT"; FAIL "expected '18082->80' in setup-dokku.sh output"; }

echo
echo "=== 3. ensure_dokku_running prints log on failure ==="
# Source lib.sh and invoke ensure_dokku_running with stub docker that pretends
# the container exists but is stopped, and `docker start` fails.
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "ps -a")       echo dokku ;;
    "ps --format") ;; # no running containers
    "start"*)      exit 1 ;;   # simulate start failure
    "logs"*)       echo "FAKE-DOKKU-LOG: oom killed" ;;
    *)             ;;
esac
STUB
OUT="$(PATH="$STUB_DIR:$PATH" bash -c "source scripts/lib.sh; ensure_dokku_running" 2>&1 || true)"
echo "$OUT" | grep -q 'FAKE-DOKKU-LOG' && PASS "log dumped on start failure" \
    || { echo "$OUT"; FAIL "expected log dump"; }

echo
echo "=== 4. restart-stack.sh --help prints usage ==="
bash scripts/restart-stack.sh --help | grep -qi 'restart' && PASS "help works" \
    || FAIL "help missing"

echo
echo "=== 5. restart-stack.sh rejects unknown env ==="
OUT="$(bash scripts/restart-stack.sh --env staging 2>&1 || true)"
echo "$OUT" | grep -q "must be 'dev' or 'prod'" \
    && PASS "rejects unknown env" \
    || { echo "$OUT"; FAIL "should reject --env staging"; }

echo
echo "ALL TESTS PASSED"
