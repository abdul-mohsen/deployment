#!/usr/bin/env bash
# Build the ZATCA daemon from an exact local source revision and recreate it.
#
# Usage:
#   bash scripts/rebuild-zatca-daemon.sh
#   bash scripts/rebuild-zatca-daemon.sh --config /opt/deployment/config.env
#   bash scripts/rebuild-zatca-daemon.sh --source-dir /opt/src/zatca-daemon \
#     --revision <full-commit-sha> --sdk-context /opt/private/zatca-sdk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_DIR"

CONFIG_FILE="${CONFIG_FILE:-${REPO_DIR}/config.env}"
SOURCE_DIR=""
REQUESTED_REVISION=""
SDK_CONTEXT=""
HEALTH_TIMEOUT_SECONDS=""

error() { echo "[x] $*" >&2; }
info() { echo "[i] $*"; }
fail() { error "$*"; exit 1; }

read_config_setting() {
    local setting="$1"
    bash -c '
        set -euo pipefail
        unset ZATCA_DAEMON_SOURCE_DIR ZATCA_DAEMON_SDK_CONTEXT
        source "$1" >/dev/null 2>&1
        set +x
        case "$2" in
            ZATCA_DAEMON_SOURCE_DIR) printf "%s" "${ZATCA_DAEMON_SOURCE_DIR:-}" ;;
            ZATCA_DAEMON_SDK_CONTEXT) printf "%s" "${ZATCA_DAEMON_SDK_CONTEXT:-}" ;;
            *) exit 2 ;;
        esac
    ' _ "$CONFIG_FILE" "$setting"
}

resolve_config_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        printf '%s' "$path"
    else
        printf '%s/%s' "$CONFIG_DIR" "$path"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || fail "--config requires a path"
            CONFIG_FILE="$2"
            shift 2
            ;;
        --source-dir)
            [ "$#" -ge 2 ] || fail "--source-dir requires a path"
            SOURCE_DIR="$2"
            shift 2
            ;;
        --revision)
            [ "$#" -ge 2 ] || fail "--revision requires a full commit SHA"
            REQUESTED_REVISION="$2"
            shift 2
            ;;
        --sdk-context)
            [ "$#" -ge 2 ] || fail "--sdk-context requires a path"
            SDK_CONTEXT="$2"
            shift 2
            ;;
        --health-timeout)
            [ "$#" -ge 2 ] || fail "--health-timeout requires seconds"
            HEALTH_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '1,18p' "$0"
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[ -f "$CONFIG_FILE" ] || fail "Config file not found: $CONFIG_FILE"
CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd -P)" ||
    fail "Could not resolve the config.env directory"
CONFIG_FILE="${CONFIG_DIR}/$(basename "$CONFIG_FILE")"

if [ -n "$HEALTH_TIMEOUT_SECONDS" ]; then
    [[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] &&
        [ "$HEALTH_TIMEOUT_SECONDS" -gt 0 ] ||
        fail "--health-timeout must be a positive integer"
fi

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$(read_config_setting ZATCA_DAEMON_SOURCE_DIR)" ||
        fail "Could not read ZATCA_DAEMON_SOURCE_DIR from config.env"
    [ -n "$SOURCE_DIR" ] ||
        fail "ZATCA_DAEMON_SOURCE_DIR must be set in config.env or pass --source-dir"
    SOURCE_DIR="$(resolve_config_path "$SOURCE_DIR")"
fi

if [ -z "$SDK_CONTEXT" ]; then
    SDK_CONTEXT="$(read_config_setting ZATCA_DAEMON_SDK_CONTEXT)" ||
        fail "Could not read ZATCA_DAEMON_SDK_CONTEXT from config.env"
    [ -n "$SDK_CONTEXT" ] ||
        fail "ZATCA_DAEMON_SDK_CONTEXT must be set in config.env or pass --sdk-context"
    SDK_CONTEXT="$(resolve_config_path "$SDK_CONTEXT")"
fi

[ -n "$SOURCE_DIR" ] || fail "--source-dir is required"
[ -n "$SDK_CONTEXT" ] || fail "--sdk-context is required"

[ -d "$SOURCE_DIR" ] || fail "Daemon source directory not found: $SOURCE_DIR"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)" ||
    fail "Could not resolve daemon source directory"
SOURCE_ROOT="$(git -C "$SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
    fail "Daemon source directory is not a Git checkout"
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)" ||
    fail "Could not resolve daemon Git root"
[ "$SOURCE_DIR" = "$SOURCE_ROOT" ] ||
    fail "--source-dir must be the root of the daemon Git checkout"
[ -f "$SOURCE_DIR/Dockerfile" ] ||
    fail "Daemon Dockerfile not found in $SOURCE_DIR"

HEAD_REVISION="$(git -C "$SOURCE_DIR" rev-parse --verify HEAD 2>/dev/null)" ||
    fail "Could not read daemon source HEAD"
if [ -z "$REQUESTED_REVISION" ]; then
    REQUESTED_REVISION="$HEAD_REVISION"
fi
[[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
    fail "--revision must be a full 40-character lowercase Git SHA"
RESOLVED_REVISION="$(git -C "$SOURCE_DIR" rev-parse --verify "${REQUESTED_REVISION}^{commit}" 2>/dev/null)" ||
    fail "Requested daemon revision is not present in the local checkout"
[ "$HEAD_REVISION" = "$REQUESTED_REVISION" ] &&
    [ "$RESOLVED_REVISION" = "$REQUESTED_REVISION" ] ||
    fail "Requested daemon revision does not match the checked-out HEAD"

SOURCE_STATUS="$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all 2>/dev/null)" ||
    fail "Could not inspect daemon source status"
[ -z "$SOURCE_STATUS" ] ||
    fail "Daemon source checkout is not clean; commit or remove local changes before refresh"

[ -f "$SDK_CONTEXT/Apps/fatoora" ] ||
    fail "SDK context must contain Apps/fatoora: $SDK_CONTEXT"
SDK_CONTEXT="$(cd "$SDK_CONTEXT" && pwd -P)" ||
    fail "Could not resolve SDK context"

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v flock >/dev/null 2>&1 || fail "flock is required to serialize daemon refreshes"

setup_args=(--config "$CONFIG_FILE" --validate-only)
if [ -n "$HEALTH_TIMEOUT_SECONDS" ]; then
    setup_args+=(--health-timeout "$HEALTH_TIMEOUT_SECONDS")
fi
if ! bash "${SCRIPT_DIR}/setup-zatca-daemon.sh" "${setup_args[@]}"; then
    fail "ZATCA setup validation failed; no image was built or replaced"
fi

docker info >/dev/null 2>&1 || fail "Docker Engine is unavailable"
docker compose version >/dev/null 2>&1 ||
    fail "Docker Compose V2 is required for daemon refresh"

DEFAULT_COMPOSE_FILE="${REPO_DIR}/dashboard/docker-compose.zatca.yml"
CONFIG_VALUES="$(
    bash -c '
        set -euo pipefail
        source "$1" >/dev/null 2>&1
        set +x
        printf "%s\t%s\t%s\n" \
            "${ZATCA_DAEMON_IMAGE:-}" \
            "${ZATCA_DAEMON_COMPOSE_FILE:-$2}" \
            "${ZATCA_DAEMON_CONTAINER:-zatca-daemon}"
    ' _ "$CONFIG_FILE" "$DEFAULT_COMPOSE_FILE"
)" || fail "Could not read the daemon image setting from config"
IFS=$'\t' read -r CONFIGURED_IMAGE COMPOSE_FILE DAEMON_CONTAINER_NAME <<< "$CONFIG_VALUES"
[ -n "$CONFIGURED_IMAGE" ] || fail "ZATCA_DAEMON_IMAGE must be configured"
[[ "$CONFIGURED_IMAGE" != *@* ]] ||
    fail "ZATCA_DAEMON_IMAGE must be a tag-style reference, not a digest"
[[ "${CONFIGURED_IMAGE##*/}" == *:* ]] ||
    fail "ZATCA_DAEMON_IMAGE must include an explicit tag"

if [[ "$COMPOSE_FILE" != /* ]]; then
    COMPOSE_FILE="${REPO_DIR}/${COMPOSE_FILE}"
fi
[ -f "$COMPOSE_FILE" ] || fail "Compose file not found: $COMPOSE_FILE"

image_output="$(
    env -u ZATCA_DAEMON_IMAGE docker compose \
        --env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" --profile zatca config --images
)" || fail "Could not resolve the configured daemon image"
[[ -n "$image_output" && "$image_output" != *$'\n'* ]] ||
    fail "Expected exactly one daemon image in the ZATCA Compose profile"
[ "$image_output" = "$CONFIGURED_IMAGE" ] ||
    fail "Compose image does not match ZATCA_DAEMON_IMAGE in the protected config"

LOCK_DIR="${DEPLOY_STATE_DIR:-/run/lock}"
LOCK_FILE="${ZATCA_DAEMON_REFRESH_LOCK_FILE:-${LOCK_DIR}/ifritah-zatca-daemon-refresh.lock}"
mkdir -p "$(dirname "$LOCK_FILE")" ||
    fail "Could not create the daemon refresh lock directory"
exec {lock_fd}>"$LOCK_FILE" ||
    fail "Could not open the daemon refresh lock"
flock -n "$lock_fd" ||
    fail "Another ZATCA daemon refresh is already running"

# Compose's project-scoped listing can miss a same-name container created elsewhere.
existing_container_names="$(docker ps -a --format '{{.Names}}')" ||
    fail "Could not inspect existing ZATCA daemon containers"
old_image_id=""
if printf '%s\n' "$existing_container_names" | grep -qxF "$DAEMON_CONTAINER_NAME"; then
    old_image_id="$(docker inspect --format '{{.Image}}' "$DAEMON_CONTAINER_NAME")" ||
        fail "Could not identify the current daemon container image"
elif ! old_image_id="$(docker image ls --quiet --no-trunc "$CONFIGURED_IMAGE")"; then
    fail "Could not inspect the configured local daemon image"
fi

build_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}${RANDOM}" ||
    fail "Could not create a unique local build identity"
new_image="zatca-daemon:refresh-${REQUESTED_REVISION}-${build_id}"
rollback_image="zatca-daemon:rollback-${build_id}"
has_rollback=false

if [ -n "$old_image_id" ]; then
    docker image tag "$old_image_id" "$rollback_image" ||
        fail "Could not preserve the prior daemon image for rollback"
    has_rollback=true
else
    info "No prior local daemon image is available for rollback."
fi

info "Building daemon source ${REQUESTED_REVISION} as ${new_image}..."
docker build \
    --no-cache \
    --pull \
    --build-context "zatca-sdk=${SDK_CONTEXT}" \
    --label "org.opencontainers.image.revision=${REQUESTED_REVISION}" \
    --tag "$new_image" \
    "$SOURCE_DIR" ||
    fail "Docker image build failed; the running daemon was not replaced"

image_id="$(docker image inspect --format '{{.Id}}' "$new_image")" ||
    fail "Could not inspect the newly built daemon image"
[ -n "$image_id" ] || fail "The newly built daemon image has no image ID"
image_revision="$(
    docker image inspect \
        --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
        "$new_image"
)" || fail "Could not verify the daemon source revision label"
[ "$image_revision" = "$REQUESTED_REVISION" ] ||
    fail "Built image source revision label does not match the requested SHA"

docker image tag "$new_image" "$CONFIGURED_IMAGE" ||
    fail "Built image is verified but the configured local image alias could not be updated"

setup_args=(--config "$CONFIG_FILE" --image "$new_image" --recreate)
if [ -n "$HEALTH_TIMEOUT_SECONDS" ]; then
    setup_args+=(--health-timeout "$HEALTH_TIMEOUT_SECONDS")
fi

if ! bash "${SCRIPT_DIR}/setup-zatca-daemon.sh" "${setup_args[@]}"; then
    error "ZATCA daemon replacement or readiness check failed."
    if $has_rollback; then
        alias_restored=false
        if docker image tag "$rollback_image" "$CONFIGURED_IMAGE"; then
            info "Restored configured image alias to the prior local image."
            alias_restored=true
        else
            error "Could not restore the configured image alias; attempting container recovery from the retained image."
        fi

        rollback_args=(--config "$CONFIG_FILE" --image "$rollback_image" --recreate)
        if [ -n "$HEALTH_TIMEOUT_SECONDS" ]; then
            rollback_args+=(--health-timeout "$HEALTH_TIMEOUT_SECONDS")
        fi
        if bash "${SCRIPT_DIR}/setup-zatca-daemon.sh" "${rollback_args[@]}"; then
            if $alias_restored; then
                info "Automatic rollback completed: configured image alias was restored and the prior daemon container is ready."
            else
                error "Prior daemon container was automatically restored, but the configured image alias could not be restored."
            fi
        elif $alias_restored; then
            error "Automatic rollback failed: the configured image alias was restored, but the prior daemon container did not pass readiness."
        else
            error "Automatic rollback failed: the configured image alias and prior daemon container readiness were not restored."
        fi
    else
        error "There is no rollback target because no prior local daemon image was available."
    fi
    exit 1
fi

info "ZATCA daemon refresh succeeded: source=${REQUESTED_REVISION} image=${new_image} image_id=${image_id}; readiness passed."
