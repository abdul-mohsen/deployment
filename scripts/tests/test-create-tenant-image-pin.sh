#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() {
    grep -Fq -- "$2" "$1" || fail "$3"
}
count_matches() {
    grep -Fc "$2" "$1" || true
}

CREATE=scripts/create-tenant.sh

echo "=== create-tenant passes resolved immutable references ==="
[ "$(count_matches "$CREATE" 'resolve_build_identity "$BACKEND_IMAGE"')" -eq 1 ] ||
    fail "backend BuildIdentity is not resolved exactly once before migrations"
[ "$(count_matches "$CREATE" 'ensure_tenant_image_available "$BACKEND_IMAGE"')" -eq 1 ] ||
    fail "backend mutable tag is re-pulled after identity resolution"
contains "$CREATE" '--backend-image "$BUILD_RESOLVED_REF"' \
    "Goose does not receive the resolved backend image reference"
contains "$CREATE" 'dokku_git_from_image "$BACKEND_APP" "$BUILD_RESOLVED_REF"' \
    "Dokku does not receive the resolved backend image reference"
[ "$(count_matches "$CREATE" 'resolve_build_identity "$FRONTEND_IMAGE"')" -eq 1 ] ||
    fail "frontend BuildIdentity is not resolved exactly once"
contains "$CREATE" 'dokku_git_from_image "$FRONTEND_APP" "$BUILD_RESOLVED_REF"' \
    "frontend Dokku deployment does not use its resolved image reference"
pass "backend and frontend consumers are wired to their resolved references"

echo "=== moved mutable tags do not change resolved consumer references ==="
source scripts/tenant-provenance.sh

BACKEND_REQUESTED="example/api:dev"
FRONTEND_REQUESTED="example/web:dev"
BACKEND_TAG_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
BACKEND_MOVED_DIGEST="sha256:2222222222222222222222222222222222222222222222222222222222222222"
FRONTEND_TAG_DIGEST="sha256:3333333333333333333333333333333333333333333333333333333333333333"
FRONTEND_MOVED_DIGEST="sha256:4444444444444444444444444444444444444444444444444444444444444444"
BACKEND_IMAGE_ID="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FRONTEND_IMAGE_ID="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CURRENT_BACKEND_DIGEST="$BACKEND_TAG_DIGEST"
CURRENT_FRONTEND_DIGEST="$FRONTEND_TAG_DIGEST"
GOOSE_IMAGE_REF=""
DOKKU_BACKEND_REF=""
DOKKU_FRONTEND_REF=""

docker() {
    local format="" format_next=0 image_ref
    local -a docker_args=("$@")
    image_ref="${docker_args[$((${#docker_args[@]} - 1))]}"
    for arg in "$@"; do
        if [ "$format_next" -eq 1 ]; then
            format="$arg"
            format_next=0
            continue
        fi
        case "$arg" in
            --format=*) format="${arg#--format=}" ;;
            --format|-f) format_next=1 ;;
        esac
    done
    [[ "$*" == *"image inspect"* ]] || return 0

    case "$format" in
        *RepoDigests*)
            case "$image_ref" in
                "$BACKEND_REQUESTED")
                    printf 'example/api@%s\n' "$CURRENT_BACKEND_DIGEST"
                    ;;
                "$FRONTEND_REQUESTED")
                    printf 'example/web@%s\n' "$CURRENT_FRONTEND_DIGEST"
                    ;;
                *)
                    printf '%s\n' "$image_ref"
                    ;;
            esac
            ;;
        *".Id"*)
            case "$image_ref" in
                *"@${BACKEND_TAG_DIGEST}") printf '%s\n' "$BACKEND_IMAGE_ID" ;;
                *"@${FRONTEND_TAG_DIGEST}") printf '%s\n' "$FRONTEND_IMAGE_ID" ;;
                *) printf '\n' ;;
            esac
            ;;
        *"org.opencontainers.image.version"*) printf 'v1.2.3\n' ;;
        *"revision"*|*".commit"*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
        *"workflow_run_url"*) printf 'https://github.com/example/app/actions/runs/42\n' ;;
        *"workflow_run_id"*|*"workflow_run"*) printf '42\n' ;;
        *"image_ref"*|*"ref.name"*)
            case "$image_ref" in
                example/api@*) printf '%s\n' "$BACKEND_REQUESTED" ;;
                example/web@*) printf '%s\n' "$FRONTEND_REQUESTED" ;;
            esac
            ;;
        *"source"*) printf 'https://github.com/example/app\n' ;;
        *"created"*|*"built_at"*|*"built-at"*) printf '2026-09-07T10:00:00Z\n' ;;
        *"channel"*) printf 'release\n' ;;
        *"digest"*)
            case "$image_ref" in
                *@*) printf '%s\n' "${image_ref##*@}" ;;
            esac
            ;;
        *) printf '\n' ;;
    esac
}

goose_run() {
    GOOSE_IMAGE_REF="$1"
}
dokku_git_from_image() {
    case "$1" in
        backend-app) DOKKU_BACKEND_REF="$2" ;;
        frontend-app) DOKKU_FRONTEND_REF="$2" ;;
    esac
}

resolve_build_identity "$BACKEND_REQUESTED" ||
    fail "backend identity did not resolve from the initial mutable tag"
backend_resolved_ref="$BUILD_RESOLVED_REF"
[ "$backend_resolved_ref" = "example/api@$BACKEND_TAG_DIGEST" ] ||
    fail "backend resolved reference did not capture the original tag target"
CURRENT_BACKEND_DIGEST="$BACKEND_MOVED_DIGEST"
goose_run "$backend_resolved_ref"
dokku_git_from_image backend-app "$backend_resolved_ref"
[ "$GOOSE_IMAGE_REF" = "$backend_resolved_ref" ] ||
    fail "Goose did not receive the pinned backend image"
[ "$DOKKU_BACKEND_REF" = "$backend_resolved_ref" ] ||
    fail "Dokku did not receive the pinned backend image after the tag moved"
pass "backend migration and runtime stubs retain one digest after tag movement"

resolve_build_identity "$FRONTEND_REQUESTED" ||
    fail "frontend identity did not resolve from the initial mutable tag"
frontend_resolved_ref="$BUILD_RESOLVED_REF"
[ "$frontend_resolved_ref" = "example/web@$FRONTEND_TAG_DIGEST" ] ||
    fail "frontend resolved reference did not capture the original tag target"
CURRENT_FRONTEND_DIGEST="$FRONTEND_MOVED_DIGEST"
dokku_git_from_image frontend-app "$frontend_resolved_ref"
[ "$DOKKU_FRONTEND_REF" = "$frontend_resolved_ref" ] ||
    fail "frontend Dokku deploy did not retain the resolved image after tag movement"
pass "frontend Dokku stub retains its resolved digest after tag movement"

echo "=== non-production override cannot produce an empty image reference ==="
CURRENT_BACKEND_DIGEST=""
TENANT_PROVENANCE_OVERRIDE=1
DEPLOY_ENV=development
if resolve_build_identity "$BACKEND_REQUESTED"; then
    fail "non-production override accepted identity without an immutable reference"
fi
[ -z "$BUILD_RESOLVED_REF" ] ||
    fail "failed resolution left an image reference for Goose/Dokku"
unset TENANT_PROVENANCE_OVERRIDE DEPLOY_ENV
contains "$CREATE" 'Backend image did not resolve to an immutable reference' \
    "backend Goose/deploy path does not reject an empty resolved reference"
contains "$CREATE" 'Frontend image did not resolve to an immutable reference' \
    "frontend deploy path does not reject an empty resolved reference"
pass "override still fails closed when no immutable reference is resolved"
