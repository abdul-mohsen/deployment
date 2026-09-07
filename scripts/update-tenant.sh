#!/usr/bin/env bash
# =============================================================================
# update-tenant.sh — Update a tenant's app images or config
# =============================================================================
# Image updates are provenance-verified and transactional as far as Dokku can
# make them: backend migrations run before the image swap, every app reports
# the expected /version identity, and a failed component restores the prior
# image/config where a prior image exists.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/tenant-provenance.sh"

CONFIG_FILE="$PROJECT_DIR/config.env"
for i in $(seq 1 $#); do
    if [ "${!i}" = "--config" ]; then
        j=$((i+1))
        CONFIG_FILE="${!j}"
        break
    fi
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
IMAGE_PULL_POLICY="${TENANT_IMAGE_PULL_POLICY:-${IMAGE_PULL_POLICY:-always}}"
VERIFY_RETRIES="${TENANT_VERIFY_RETRIES:-15}"
VERIFY_DELAY="${TENANT_VERIFY_DELAY:-2}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

TENANT_NAME=""
BACKEND_IMAGE=""
FRONTEND_IMAGE=""
RESTART=false
SCALE=""
SKIP_MIGRATIONS=false
declare -a ENV_VARS=()
declare -A COMPONENT_IDENTITY=()
declare -A PREVIOUS_IMAGE=()
declare -A PREVIOUS_CONFIG=()
declare -A PREVIOUS_DB_IDENTITY=()
declare -A DEPLOYED_COMPONENT=()

ensure_update_image_available() {
    local image="$1"
    case "$IMAGE_PULL_POLICY" in
        always)
            log "Pulling image: $image"
            docker pull "$image" >/dev/null
            ;;
        missing)
            if docker image inspect "$image" >/dev/null 2>&1; then
                return 0
            fi
            log "Pulling image: $image"
            docker pull "$image" >/dev/null
            ;;
        never)
            if ! docker image inspect "$image" >/dev/null 2>&1; then
                error "Image is not present locally and IMAGE_PULL_POLICY=never: $image"
                return 1
            fi
            ;;
        *)
            error "IMAGE_PULL_POLICY must be 'always', 'missing', or 'never' (got: $IMAGE_PULL_POLICY)"
            return 1
            ;;
    esac
}

image_tag() {
    local image="$1"
    local tail="${image##*/}"
    if [[ "$tail" == *:* ]]; then
        printf '%s' "${tail##*:}"
    fi
}

current_app_image() {
    local app="$1" image
    image="$(dokku git:report "$app" 2>/dev/null |
        awk -F': ' 'tolower($1) ~ /source-image/ {print $2; exit}' || true)"
    if [ -z "$image" ]; then
        image="$(dokku config:get "$app" APP_IMAGE_REF 2>/dev/null | awk 'NF {print; exit}' || true)"
    fi
    printf '%s' "$image"
}

capture_runtime_config() {
    local app="$1" key
    for key in APP_VERSION APP_COMMIT APP_COMMIT_SHORT APP_BUILD_CHANNEL \
        APP_BUILD_WORKFLOW_RUN APP_WORKFLOW_RUN APP_BUILT_AT APP_BUILD_AT \
        APP_IMAGE_REF APP_IMAGE_DIGEST APP_IMAGE_RESOLVED_REF APP_IMAGE_VERSION; do
        PREVIOUS_CONFIG["$app:$key"]="$(dokku config:get "$app" "$key" 2>/dev/null || true)"
    done
}

restore_runtime_config() {
    local app="$1" key value
    local -a set_args=() unset_args=()
    for key in APP_VERSION APP_COMMIT APP_COMMIT_SHORT APP_BUILD_CHANNEL \
        APP_BUILD_WORKFLOW_RUN APP_WORKFLOW_RUN APP_BUILT_AT APP_BUILD_AT \
        APP_IMAGE_REF APP_IMAGE_DIGEST APP_IMAGE_RESOLVED_REF APP_IMAGE_VERSION; do
        value="${PREVIOUS_CONFIG["$app:$key"]:-}"
        if [ -n "$value" ]; then
            set_args+=("$key=$value")
        else
            unset_args+=("$key")
        fi
    done
    [ "${#set_args[@]}" -eq 0 ] || dokku config:set --no-restart "$app" "${set_args[@]}" || true
    [ "${#unset_args[@]}" -eq 0 ] || dokku config:unset --no-restart "$app" "${unset_args[@]}" || true
}

record_failure() {
    local component="$1" requested="$2" message="$3"
    local values="${COMPONENT_IDENTITY[$component]:-}"
    local channel="" version="" commit_sha="" commit_short="" workflow=""
    local image_ref="" digest="" built_at="" previous_ref="" previous_digest=""
    if [ -n "$values" ]; then
        IFS=$'\t' read -r channel version commit_sha commit_short workflow image_ref digest built_at <<< "$values"
    fi
    local resolved_ref="${requested%@*}@${digest}"
    IFS=$'\t' read -r previous_ref previous_digest _ <<< "${PREVIOUS_DB_IDENTITY[$component]:-}"
    tenant_record_failure "$TENANT_NAME" "$component" "$message" 2>/dev/null || true
    tenant_record_audit "$TENANT_NAME" "$component" "$requested" "$resolved_ref" "$digest" \
        "$channel" "$version" "$commit_sha" "$commit_short" "$workflow" "$built_at" \
        "$previous_ref" "$previous_digest" "failed" "$message" 2>/dev/null || true
}

rollback_component() {
    local component="$1" app image
    app="${TENANT_NAME}-${component}"
    image="${PREVIOUS_IMAGE[$component]:-}"
    if [ -z "$image" ]; then
        warn "${app}: no previous image is recorded; cannot perform image rollback"
        restore_runtime_config "$app"
        return 1
    fi
    log "Rolling back ${app} to ${image}"
    if ! dokku_git_from_image "$app" "$image"; then
        error "${app}: rollback failed"
        restore_runtime_config "$app"
        return 1
    fi
    restore_runtime_config "$app"
    IFS=$'\t' read -r old_ref old_digest _ <<< "${PREVIOUS_DB_IDENTITY[$component]:-}"
    if [ -n "$old_ref" ] || [ -n "$old_digest" ]; then
        # Keep the durable current identity equal to the last-known-good image.
        IFS=$'\t' read -r old_ref old_digest old_channel old_version old_commit \
            old_short old_workflow old_built <<< "${PREVIOUS_DB_IDENTITY[$component]}"
        tenant_record_identity "$TENANT_NAME" "$component" "$old_ref" "$old_ref" \
            "$old_digest" "$old_channel" "$old_version" "$old_commit" "$old_short" \
            "$old_workflow" "$old_built" 2>/dev/null || true
    else
        tenant_clear_identity "$TENANT_NAME" "$component" "deployment rolled back; no prior verified identity" 2>/dev/null || true
    fi
    return 0
}

verify_component() {
    local component="$1" app="$2" values="$3"
    local channel version commit_sha commit_short workflow image_ref digest built_at
    IFS=$'\t' read -r channel version commit_sha commit_short workflow image_ref digest built_at <<< "$values"
    local attempt
    for ((attempt=1; attempt<=VERIFY_RETRIES; attempt++)); do
        if verify_runtime_identity "$app" "$version" "$commit_sha" "$digest" \
            "$image_ref" "$channel" "$workflow" "$built_at"; then
            return 0
        fi
        [ "$attempt" -lt "$VERIFY_RETRIES" ] && sleep "$VERIFY_DELAY"
    done
    error "${app}: /version did not report the expected BuildIdentity"
    return 1
}

deploy_component() {
    local component="$1" image="$2" app="${TENANT_NAME}-${1}"
    local values="${COMPONENT_IDENTITY[$component]}"
    local channel version commit_sha commit_short workflow image_ref digest built_at
    local resolved_ref="${image%@*}@${digest}"
    IFS=$'\t' read -r channel version commit_sha commit_short workflow image_ref digest built_at <<< "$values"

    if ! tenant_record_audit "$TENANT_NAME" "$component" "$image" "$resolved_ref" "$digest" \
        "$channel" "$version" "$commit_sha" "$commit_short" "$workflow" "$built_at" \
        "${PREVIOUS_IMAGE[$component]:-}" \
        "$(printf '%s' "${PREVIOUS_DB_IDENTITY[$component]:-}" | cut -f2)" \
        "started" "" 2>/dev/null; then
        error "${app}: deployment audit is unavailable; refusing an untracked swap"
        record_failure "$component" "$image" "deployment audit start failed"
        return 1
    fi

    log "Deploying ${component}: ${image} (${digest})"
    local resolved_ref="${image%@*}@${digest}"
    if ! dokku config:set --no-restart "$app" \
        APP_VERSION="$version" \
        APP_COMMIT="$commit_sha" \
        APP_COMMIT_SHORT="$commit_short" \
        APP_BUILD_CHANNEL="$channel" \
        APP_BUILD_WORKFLOW_RUN="$workflow" \
        APP_WORKFLOW_RUN="$workflow" \
        APP_BUILT_AT="$built_at" \
        APP_BUILD_AT="$built_at" \
        APP_IMAGE_VERSION="$(image_tag "$image")" \
        APP_IMAGE_REF="$image" \
        APP_IMAGE_DIGEST="$digest" \
        APP_IMAGE_RESOLVED_REF="$resolved_ref"; then
        record_failure "$component" "$image" "failed to set runtime identity"
        restore_runtime_config "$app"
        return 1
    fi
    if ! dokku_git_from_image "$app" "$image"; then
        record_failure "$component" "$image" "Dokku image swap failed"
        rollback_component "$component" || true
        return 1
    fi
    if ! verify_component "$component" "$app" "$values"; then
        record_failure "$component" "$image" "post-deploy /version identity verification failed"
        rollback_component "$component" || true
        return 1
    fi
    if ! tenant_record_identity "$TENANT_NAME" "$component" "$image" "$image_ref" \
        "$digest" "$channel" "$version" "$commit_sha" "$commit_short" \
        "$workflow" "$built_at"; then
        record_failure "$component" "$image" "failed to persist verified deployment identity"
        rollback_component "$component" || true
        return 1
    fi
    if ! tenant_record_audit "$TENANT_NAME" "$component" "$image" "$resolved_ref" "$digest" \
        "$channel" "$version" "$commit_sha" "$commit_short" "$workflow" "$built_at" \
        "${PREVIOUS_IMAGE[$component]:-}" \
        "$(printf '%s' "${PREVIOUS_DB_IDENTITY[$component]:-}" | cut -f2)" \
        "verified" "" 2>/dev/null; then
        error "${app}: failed to record successful deployment audit"
        rollback_component "$component" || true
        record_failure "$component" "$image" "deployment audit completion failed"
        return 1
    fi
    DEPLOYED_COMPONENT["$component"]=1
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend-image)  BACKEND_IMAGE="$2"; shift 2 ;;
        --frontend-image) FRONTEND_IMAGE="$2"; shift 2 ;;
        --env)            ENV_VARS+=("$2"); shift 2 ;;
        --restart)        RESTART=true; shift ;;
        --scale)          SCALE="$2"; shift 2 ;;
        --skip-migrations)
            SKIP_MIGRATIONS=true
            shift
            ;;
        --config)         shift 2 ;;
        -*)               error "Unknown option: $1"; exit 1 ;;
        *)                [ -z "$TENANT_NAME" ] && TENANT_NAME="$1"; shift ;;
    esac
done

if [ -z "$TENANT_NAME" ]; then
    echo "Usage: $0 <tenant-name> [--backend-image <image>] [--frontend-image <image>]"
    exit 1
fi
TENANT_NAME="$(tenant_full_name "$TENANT_NAME")" || exit 1
BACKEND_APP="${TENANT_NAME}-backend"
FRONTEND_APP="${TENANT_NAME}-frontend"

if [ -n "$BACKEND_IMAGE" ] || [ -n "$FRONTEND_IMAGE" ]; then
    if ! ensure_tenant_provenance_schema; then
        error "Tenant provenance schema is unavailable; refusing an untracked deployment."
        exit 1
    fi
fi

for ev in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    if [[ "$ev" == *"="* ]]; then
        log "Setting env: $ev"
        dokku config:set --no-restart "$BACKEND_APP" "$ev"
    fi
done

for component in backend frontend; do
    image="${component^^}_IMAGE"
    image="${!image:-}"
    [ -n "$image" ] || continue
    app="${TENANT_NAME}-${component}"
    PREVIOUS_IMAGE["$component"]="$(current_app_image "$app")"
    capture_runtime_config "$app"
    PREVIOUS_DB_IDENTITY["$component"]="$(tenant_current_identity "$TENANT_NAME" "$component" || true)"
    if ! ensure_update_image_available "$image"; then
        record_failure "$component" "$image" "image pull/availability check failed"
        exit 1
    fi
    if ! resolve_build_identity "$image"; then
        error "${image}: missing or inconsistent OCI BuildIdentity labels"
        record_failure "$component" "$image" "missing or inconsistent OCI BuildIdentity labels"
        exit 1
    fi
    COMPONENT_IDENTITY["$component"]="$(provenance_identity_tsv)"
done

if [ -n "$BACKEND_IMAGE" ]; then
    if $SKIP_MIGRATIONS && ! provenance_override_enabled; then
        error "--skip-migrations is only allowed with TENANT_PROVENANCE_OVERRIDE=1 in a non-production environment."
        record_failure backend "$BACKEND_IMAGE" "unsafe migration bypass refused"
        exit 1
    fi
    if ! $SKIP_MIGRATIONS; then
        log "Replaying schema/migrations from ${BACKEND_IMAGE} before backend swap"
        if ! "$SCRIPT_DIR/init-tenant-db.sh" "$TENANT_NAME" \
            --schema-only --backend-image "$BACKEND_IMAGE" --config "$CONFIG_FILE"; then
            error "Migration replay failed; refusing to swap the backend image."
            record_failure backend "$BACKEND_IMAGE" "migration replay failed"
            exit 1
        fi
    else
        warn "Skipping backend migrations under explicit non-production override."
    fi
fi

if [ -n "$BACKEND_IMAGE" ]; then
    if ! deploy_component backend "$BACKEND_IMAGE"; then
        exit 1
    fi
fi
if [ -n "$FRONTEND_IMAGE" ]; then
    if ! deploy_component frontend "$FRONTEND_IMAGE"; then
        if [ -n "${DEPLOYED_COMPONENT[backend]:-}" ]; then
            warn "Frontend failed after backend swap; restoring backend last-known-good image."
            rollback_component backend || true
        fi
        exit 1
    fi
fi

if [ -n "$SCALE" ]; then
    log "Scaling backend to $SCALE instances"
    dokku ps:scale "$BACKEND_APP" web="$SCALE"
fi

if $RESTART; then
    log "Restarting tenant..."
    dokku ps:restart "$BACKEND_APP"
    dokku ps:restart "$FRONTEND_APP"
fi

log "Done. Verified deployment identity persisted for ${TENANT_NAME}."
