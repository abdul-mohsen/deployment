#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
not_contains() { ! grep -Fq -- "$2" "$1" || fail "$3"; }

REFRESH_SCRIPT="scripts/rebuild-zatca-daemon.sh"
SETUP_SCRIPT="scripts/setup-zatca-daemon.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
BIN="$TEST_DIR/bin"
SOURCE_DIR="$TEST_DIR/daemon"
SDK_CONTEXT="$TEST_DIR/sdk"
STATE_DIR="$TEST_DIR/state"
CONFIG="$TEST_DIR/config.env"
CONFIG_BEFORE="$TEST_DIR/config.before"
DOCKER_LOG="$TEST_DIR/docker.log"
BUILD_TAGS="$TEST_DIR/build-tags"
UP_IMAGES="$TEST_DIR/up-images"
OUTPUT="$TEST_DIR/output"
CONTAINER_NAME="zatca-daemon-refresh-test"
mkdir -p "$BIN" "$SOURCE_DIR" "$SDK_CONTEXT/Apps"
touch "$SDK_CONTEXT/Apps/fatoora"

if [ ! -f "$REFRESH_SCRIPT" ]; then
    fail "$REFRESH_SCRIPT has not been implemented"
fi

git -C "$SOURCE_DIR" init -q
git -C "$SOURCE_DIR" config user.name "Refresh Test"
git -C "$SOURCE_DIR" config user.email "refresh-test@example.invalid"
printf 'FROM scratch\n' > "$SOURCE_DIR/Dockerfile"
git -C "$SOURCE_DIR" add Dockerfile
git -C "$SOURCE_DIR" commit -qm "test daemon source"
REVISION="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
CONFIG_IMAGE="local/zatca-daemon:test"

write_config() {
    local path="$1"
    cat > "$path" <<EOF
ZATCA_DAEMON_ENABLED=1
ZATCA_DAEMON_IMAGE=${CONFIG_IMAGE}
ZATCA_DAEMON_CONTAINER=${CONTAINER_NAME}
ZATCA_NATS_DATA_ROOT=${TEST_DIR}/nats
ZATCA_DB_USER=test-user
ZATCA_DB_PASSWORD=TEST_SECRET_DB_PASSWORD
ZATCA_ENCRYPT_KEY=TEST_SECRET_ENCRYPTION_KEY
ZATCA_MONITOR_PASSWORD=TEST_SECRET_MONITOR_PASSWORD
NATS_USER=test-nats-user
NATS_PASSWORD=TEST_SECRET_NATS_PASSWORD
NATS_PRIVATE_NETWORK_ONLY=true
NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED=true
NATS_SHARED_CREDENTIALS_ACKNOWLEDGED=true
NATS_SHARED_CREDENTIALS_APPROVAL_ID=TEST-APPROVAL
NATS_SHARED_CREDENTIALS_EXPIRES=2099-12-31
EOF
}
write_config "$CONFIG"
cp "$CONFIG" "$CONFIG_BEFORE"

cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"

case "${1:-}" in
    info)
        exit 0
        ;;
    compose)
        case " $* " in
            *" config --images "*)
                printf '%s\n' "${CONFIG_IMAGE:?}"
                ;;
            *" config --quiet "*)
                [ "${CONFIG_FAIL:-0}" = "0" ] || exit 1
                ;;
            *" ps -a -q zatca-daemon "*)
                [ "${CONTAINER_PRESENT:-1}" = "1" ] &&
                    [ "${COMPOSE_CONTAINER_VISIBLE:-1}" = "1" ] &&
                    printf '%s\n' "container-id"
                ;;
            *" up -d "*)
                printf '%s\n' "${ZATCA_DAEMON_IMAGE:-}" >> "${UP_IMAGES:?}"
                ;;
        esac
        exit 0
        ;;
    build)
        tag=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--tag" ] && [ "$#" -ge 2 ]; then
                tag="$2"
                break
            fi
            shift
        done
        printf '%s\n' "$tag" >> "${BUILD_TAGS:?}"
        [ -z "${ZATCA_DB_PASSWORD:-}" ] || {
            echo "deployment secret reached docker build" >&2
            exit 97
        }
        [ "${BUILD_FAIL:-0}" = "0" ] || exit 12
        exit 0
        ;;
    image)
        case "${2:-}" in
            inspect)
                shift 2
                format=""
                while [ "$#" -gt 1 ]; do
                    if [ "$1" = "--format" ] && [ "$#" -ge 2 ]; then
                        format="$2"
                        shift 2
                    else
                        shift
                    fi
                done
                case "$format" in
                    *org.opencontainers.image.revision*)
                        printf '%s\n' "${LABEL_REVISION:-}"
                        ;;
                    *".Id"*)
                        printf '%s\n' "sha256:built-image"
                        ;;
                    *)
                        printf '\n'
                        ;;
                esac
                ;;
            tag)
                source_image="${3:-}"
                target_image="${4:-}"
                if [ "${RESTORE_TAG_FAIL:-0}" = "1" ] &&
                    [[ "$source_image" == *":rollback-"* ]] &&
                    [ "$target_image" = "${CONFIG_IMAGE:?}" ]; then
                    exit 1
                fi
                ;;
            ls)
                [ "${OLD_IMAGE_AVAILABLE:-1}" = "1" ] &&
                    printf '%s\n' "sha256:old-image"
                ;;
        esac
        exit 0
        ;;
    container)
        if [ "${2:-}" = "ls" ] && [ "${CONTAINER_PRESENT:-1}" = "1" ]; then
            printf '%s\n' "container-id"
        fi
        exit 0
        ;;
    inspect)
        case "${3:-}" in
            *".Image"*)
                printf '%s\n' "sha256:old-image"
                ;;
            *"State.Health.Status"*)
                printf '%s\n' "${HEALTH_STATUS:-healthy}"
                ;;
        esac
        exit 0
        ;;
    rm)
        if [ "${REMOVE_CONTAINER_FAIL:-0}" = "1" ]; then
            exit 13
        fi
        ;;
    ps)
        if [ "${CONTAINER_LIST_FAIL:-0}" = "1" ] && [ "${2:-}" = "-a" ]; then
            exit 14
        fi
        if [ "${2:-}" = "-a" ] && [ "${CONTAINER_PRESENT:-1}" = "1" ]; then
            printf '%s\n' "${CONFIGURED_CONTAINER_NAME:-zatca-daemon}"
        fi
        ;;
    logs)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
STUB

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
if [[ "$config" == *"/healthz"* ]]; then
    printf '%s\n' '{"status":"healthy"}'
else
    printf '%s\n' '{"data":{"account_details":[{"stream_detail":[{"name":"ZATCA","state":{"messages":0},"consumer_detail":[{"num_pending":0,"num_ack_pending":0,"num_redelivered":0}]}]}]}}'
fi
STUB

chmod +x "$BIN/docker" "$BIN/curl"
export PATH="$BIN:$PATH"
export DOCKER_LOG BUILD_TAGS UP_IMAGES EXPECTED_REVISION="$REVISION" DEPLOY_STATE_DIR="$STATE_DIR"
export CONFIGURED_CONTAINER_NAME="$CONTAINER_NAME"
export CONFIG_IMAGE

reset_mocks() {
    : > "$DOCKER_LOG"
    : > "$BUILD_TAGS"
    : > "$UP_IMAGES"
    unset CONFIG_FAIL BUILD_FAIL RESTORE_TAG_FAIL REMOVE_CONTAINER_FAIL CONTAINER_LIST_FAIL COMPOSE_CONTAINER_VISIBLE
    export CONTAINER_PRESENT=1 OLD_IMAGE_AVAILABLE=1 HEALTH_STATUS=healthy
    export LABEL_REVISION="$REVISION"
}

run_refresh() {
    local config="$1" revision="${2:-$REVISION}" sdk="${3:-$SDK_CONTEXT}"
    bash "$REFRESH_SCRIPT" \
        --config "$config" \
        --source-dir "$SOURCE_DIR" \
        --revision "$revision" \
        --sdk-context "$sdk" \
        --health-timeout 2
}

run_setup_recreate() {
    local config="$1"
    bash "$SETUP_SCRIPT" --config "$config" --recreate --health-timeout 2
}

run_setup_without_recreate() {
    local config="$1"
    bash "$SETUP_SCRIPT" --config "$config" --health-timeout 2
}

reset_mocks
if ! run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT" >&2
    fail "clean exact-SHA refresh should succeed"
fi
contains "$DOCKER_LOG" 'build --no-cache --pull' "build did not disable cache and refresh base images"
contains "$DOCKER_LOG" "--build-context zatca-sdk=$SDK_CONTEXT" "private SDK build context was not used"
contains "$DOCKER_LOG" "org.opencontainers.image.revision=$REVISION" "build did not label the exact source SHA"
contains "$DOCKER_LOG" '--force-recreate' "daemon was not explicitly recreated"
contains "$DOCKER_LOG" "rm --force $CONTAINER_NAME" "existing daemon container was not removed by its configured name"
contains "$DOCKER_LOG" "inspect --format {{.Image}} $CONTAINER_NAME" "rollback source was not read from the exact configured container name"
contains "$DOCKER_LOG" "image tag sha256:old-image zatca-daemon:rollback-" "actual container image was not retained for rollback"
not_contains "$DOCKER_LOG" 'rm --volumes' "recreation attempted to remove daemon volumes"
build_line="$(grep -nF 'build --no-cache --pull' "$DOCKER_LOG" | head -n 1 | cut -d: -f1)"
remove_line="$(grep -nF "rm --force $CONTAINER_NAME" "$DOCKER_LOG" | head -n 1 | cut -d: -f1)"
up_line="$(grep -nF 'up -d --force-recreate zatca-daemon' "$DOCKER_LOG" | head -n 1 | cut -d: -f1)"
[ "$build_line" -lt "$remove_line" ] && [ "$remove_line" -lt "$up_line" ] ||
    fail "existing container was not removed after the build and before Compose up"
contains "$UP_IMAGES" 'zatca-daemon:refresh-' "setup did not receive the unique build image"
contains "$OUTPUT" "$REVISION" "success output omitted the full source SHA"
contains "$OUTPUT" 'sha256:built-image' "success output omitted the image ID"
contains "$OUTPUT" 'ready' "success output omitted readiness"
not_contains "$OUTPUT" 'TEST_SECRET_' "refresh output exposed a deployment secret"
not_contains "$DOCKER_LOG" 'push' "refresh attempted to push an image"
cmp -s "$CONFIG" "$CONFIG_BEFORE" || fail "refresh edited the protected config file"
tag_one="$(head -n 1 "$BUILD_TAGS")"
[[ "$tag_one" == zatca-daemon:refresh-"$REVISION"-* ]] || fail "build tag does not include revision and a unique suffix"
contains "$DOCKER_LOG" "image tag $tag_one $CONFIG_IMAGE" "configured local alias was not updated"
pass "clean source builds a uniquely identified image and reports readiness"

reset_mocks
export LABEL_REVISION="ffffffffffffffffffffffffffffffffffffffff"
if run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "image with a mismatched source revision label was accepted"
fi
contains "$OUTPUT" 'source revision label does not match' "image provenance mismatch was not explicit"
not_contains "$DOCKER_LOG" 'up -d' "unverified image reached Compose up"
not_contains "$DOCKER_LOG" "image tag zatca-daemon:refresh-" "unverified image replaced the configured alias"
pass "source revision label mismatch fails before alias update or replacement"

reset_mocks
if ! run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT" >&2
    fail "second clean refresh should succeed"
fi
tag_two="$(head -n 1 "$BUILD_TAGS")"
[ "$tag_one" != "$tag_two" ] || fail "successive refreshes reused the same image tag"
pass "each refresh receives a distinct local image tag"

reset_mocks
wrong_revision="ffffffffffffffffffffffffffffffffffffffff"
if run_refresh "$CONFIG" "$wrong_revision" >"$OUTPUT" 2>&1; then
    fail "mismatched source revision was accepted"
fi
not_contains "$DOCKER_LOG" 'build ' "mismatched source revision reached Docker build"
not_contains "$DOCKER_LOG" 'up -d' "mismatched source revision reached Compose up"
pass "source revision mismatch fails before build or replacement"

reset_mocks
printf 'dirty\n' > "$SOURCE_DIR/untracked.txt"
if run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "dirty daemon checkout was accepted"
fi
rm "$SOURCE_DIR/untracked.txt"
not_contains "$DOCKER_LOG" 'build ' "dirty source checkout reached Docker build"
pass "dirty source checkout fails before build"

reset_mocks
if run_refresh "$CONFIG" "$REVISION" "$TEST_DIR/missing-sdk" >"$OUTPUT" 2>&1; then
    fail "missing SDK context was accepted"
fi
not_contains "$DOCKER_LOG" 'build ' "missing SDK context reached Docker build"
pass "missing SDK context fails before build"

reset_mocks
invalid_config="$TEST_DIR/invalid-config.env"
sed 's/^NATS_PASSWORD=.*/NATS_PASSWORD=/' "$CONFIG" > "$invalid_config"
if run_refresh "$invalid_config" >"$OUTPUT" 2>&1; then
    fail "invalid deployment config was accepted"
fi
not_contains "$DOCKER_LOG" 'build ' "invalid config reached Docker build"
not_contains "$DOCKER_LOG" 'up -d' "invalid config reached Compose up"
pass "invalid protected config fails before build or replacement"

reset_mocks
export BUILD_FAIL=1
if run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "failed Docker build was reported as success"
fi
not_contains "$DOCKER_LOG" 'up -d' "failed Docker build reached Compose up"
not_contains "$DOCKER_LOG" 'rm --force' "failed Docker build removed the current daemon container"
not_contains "$DOCKER_LOG" "image tag zatca-daemon:refresh-" "failed build updated the configured alias"
pass "build failure leaves the configured alias and running container untouched"

reset_mocks
export REMOVE_CONTAINER_FAIL=1
if run_setup_recreate "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "container removal failure was reported as success"
fi
contains "$OUTPUT" 'Could not remove existing ZATCA daemon container' "container removal failure was not explicit"
contains "$DOCKER_LOG" "rm --force $CONTAINER_NAME" "recreation did not attempt to remove the conflicting container"
not_contains "$DOCKER_LOG" 'up -d' "Compose started after container removal failed"
pass "container removal failure stops before Compose starts a replacement"

reset_mocks
export CONTAINER_LIST_FAIL=1
if run_setup_recreate "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "container list failure was reported as success"
fi
contains "$OUTPUT" 'Could not inspect existing ZATCA daemon containers' "container list failure was not explicit"
not_contains "$DOCKER_LOG" 'up -d' "Compose started after existing-container inspection failed"
pass "container inspection failure stops before Compose starts a replacement"

reset_mocks
if ! run_setup_without_recreate "$CONFIG" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT" >&2
    fail "ordinary setup should not remove the existing daemon container"
fi
not_contains "$DOCKER_LOG" 'rm --force' "ordinary setup removed the existing daemon container"
pass "container removal is limited to explicit recreation"

reset_mocks
export HEALTH_STATUS=unhealthy
if run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "unhealthy replacement was reported as success"
fi
contains "$OUTPUT" 'Rollback command:' "readiness failure omitted the manual rollback action"
contains "$OUTPUT" 'zatca-daemon:rollback-' "rollback command omitted the retained prior image tag"
contains "$DOCKER_LOG" "image tag zatca-daemon:rollback-" "prior image was not retained under a rollback tag"
contains "$OUTPUT" 'Restored configured image alias' "readiness failure did not report alias recovery"
not_contains "$OUTPUT" 'TEST_SECRET_' "failure output exposed a deployment secret"
pass "readiness failure retains the old image and prints an exact recovery action"

reset_mocks
export HEALTH_STATUS=unhealthy RESTORE_TAG_FAIL=1
if run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "alias restore failure was reported as success"
fi
contains "$OUTPUT" 'restore the configured image alias' "alias restore failure was not explicit"
contains "$OUTPUT" 'Rollback command:' "alias restore failure omitted the manual rollback action"
pass "alias restore failure is explicit while the retained image remains actionable"

reset_mocks
export CONTAINER_PRESENT=0 OLD_IMAGE_AVAILABLE=0 HEALTH_STATUS=unhealthy
if run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "unhealthy first deployment was reported as success"
fi
contains "$OUTPUT" 'no rollback target' "missing prior image was not reported"
not_contains "$DOCKER_LOG" "rm --force $CONTAINER_NAME" "recreation tried removing a nonexistent daemon container"
pass "readiness failure without an old image is reported without a false rollback claim"

reset_mocks
export COMPOSE_CONTAINER_VISIBLE=0 OLD_IMAGE_AVAILABLE=0 HEALTH_STATUS=unhealthy
if run_refresh "$CONFIG" >"$OUTPUT" 2>&1; then
    fail "unhealthy replacement with an out-of-project container was reported as success"
fi
contains "$DOCKER_LOG" "inspect --format {{.Image}} $CONTAINER_NAME" "out-of-project container image was not inspected"
contains "$DOCKER_LOG" "image tag sha256:old-image zatca-daemon:rollback-" "out-of-project container image was not preserved for rollback"
contains "$OUTPUT" 'Rollback command:' "out-of-project container failure omitted its recovery command"
pass "out-of-project container image is preserved as the rollback target"

reset_mocks
digest_config="$TEST_DIR/digest-config.env"
sed 's#^ZATCA_DAEMON_IMAGE=.*#ZATCA_DAEMON_IMAGE=local/zatca-daemon@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#' \
    "$CONFIG" > "$digest_config"
if run_refresh "$digest_config" >"$OUTPUT" 2>&1; then
    fail "digest-only image reference was accepted"
fi
not_contains "$DOCKER_LOG" 'build ' "digest-only reference reached Docker build"
pass "digest-only image reference is rejected before build"
