#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
FORCE=false
STAGING=false
NO_RELOAD=false

timestamp() { date '+%Y-%m-%d %H:%M:%S%z'; }
log() { printf '%s [%s] %s\n' "$(timestamp)" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*" >&2; }
fail() { error "$*"; exit 1; }
on_error() { local rc=$?; error "Failed at line $1 (exit $rc)."; exit "$rc"; }
trap 'on_error $LINENO' ERR

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --env <path>      Path to env file (default: $SCRIPT_DIR/.env)
  --force           Force ACME re-issue even if certificate is still valid
  --staging         Use Let's Encrypt staging CA for a test run
  --no-reload       Do not register COMMAND_TO_RELOAD_WEBSERVER with acme.sh
  -h, --help        Show this help

Required .env keys:
  ENDPOINT
  APIKEY
  SECRET_APIKEY
  DOMAIN
  DOMAIN_CERT_LOCATION
  PRIVATE_KEY_LOCATION
  PUBLIC_KEY_LOCATION
  INTERMEDITE_CERT_LOCATION
  COMMAND_TO_RELOAD_WEBSERVER

Real output files:
  SSL fullchain certificate: DOMAIN_CERT_LOCATION
  Private key:               PRIVATE_KEY_LOCATION
  Public key:                PUBLIC_KEY_LOCATION
  Intermediate certificate:  INTERMEDITE_CERT_LOCATION

Prerequisites:
  acme.sh, curl, openssl
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            [ -n "${2:-}" ] || fail "--env requires a path"
            ENV_FILE="$2"
            shift 2
            ;;
        --force) FORCE=true; shift ;;
        --staging) STAGING=true; shift ;;
        --no-reload) NO_RELOAD=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Required command not found: $1"
        exit 1
    fi
}

require_value() {
    local name="$1" value="${!1:-}"
    if [ -z "$value" ]; then
        error "$name is required in $ENV_FILE"
        exit 1
    fi
}

bool_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

trim() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

set_env_value() {
    local key="$1" value="$2"
    if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        error "Invalid env key in $ENV_FILE: $key"
        exit 1
    fi
    printf -v "$key" '%s' "$value"
    export "$key"
}

load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        error "Env file not found: $ENV_FILE"
        error "Create it with the required keys shown in --help or pass --env <path>."
        exit 1
    fi

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="$(trim "$line")"
        [ -n "$line" ] || continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" == export\ * ]] && line="${line#export }"
        if [[ "$line" != *=* ]]; then
            error "Invalid env line in $ENV_FILE: $line"
            exit 1
        fi
        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"
        if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        fi
        set_env_value "$key" "$value"
    done < "$ENV_FILE"

    if [ -z "${INTERMEDITE_CERT_LOCATION:-}" ] && [ -n "${INTERMEDIATE_CERT_LOCATION:-}" ]; then
        INTERMEDITE_CERT_LOCATION="$INTERMEDIATE_CERT_LOCATION"
    fi

    require_value ENDPOINT
    require_value APIKEY
    require_value SECRET_APIKEY
    require_value DOMAIN
    require_value DOMAIN_CERT_LOCATION
    require_value PRIVATE_KEY_LOCATION
    require_value PUBLIC_KEY_LOCATION
    require_value INTERMEDITE_CERT_LOCATION
    require_value COMMAND_TO_RELOAD_WEBSERVER

    ENDPOINT="${ENDPOINT%/}"
    ACME_KEY_LENGTH="${ACME_KEY_LENGTH:-2048}"
    DNS_SLEEP="${DNS_SLEEP:-120}"
}

find_acme_sh() {
    if [ -n "${ACME_SH_BIN:-}" ] && [ -x "$ACME_SH_BIN" ]; then
        printf '%s' "$ACME_SH_BIN"
        return 0
    fi
    if command -v acme.sh >/dev/null 2>&1; then
        command -v acme.sh
        return 0
    fi
    if [ -x "$HOME/.acme.sh/acme.sh" ]; then
        printf '%s' "$HOME/.acme.sh/acme.sh"
        return 0
    fi
    return 1
}

ensure_acme_sh() {
    if ACME_SH_BIN="$(find_acme_sh)"; then
        return 0
    fi
    fail "acme.sh is required. Install it first or set ACME_SH_BIN."
}

porkbun_ping() {
    local response status payload
    response="$(mktemp)"
    payload="{\"apikey\":\"$APIKEY\",\"secretapikey\":\"$SECRET_APIKEY\"}"
    status="$(curl -fsS --globoff -X POST "$ENDPOINT/ping" -H 'Content-Type: application/json' --data "$payload" -o "$response" -w '%{http_code}' || true)"
    if [ "$status" != "200" ] || ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"SUCCESS"' "$response"; then
        rm -f "$response"
        fail "Porkbun API credential check failed (HTTP $status)."
    fi
    rm -f "$response"
    info "Porkbun API credentials verified."
}

build_domain_args() {
    DOMAIN_ARGS=()
    PRIMARY_DOMAIN=""
    if [ -n "${CERT_DOMAINS:-}" ]; then
        local item normalized
        normalized="$(printf '%s' "$CERT_DOMAINS" | tr ',' ' ')"
        for item in $normalized; do
            [ -n "$item" ] || continue
            if [ -z "$PRIMARY_DOMAIN" ] && [[ "$item" != \*.* ]]; then
                PRIMARY_DOMAIN="$item"
                DOMAIN_ARGS=("-d" "$item" "${DOMAIN_ARGS[@]}")
            else
                DOMAIN_ARGS+=("-d" "$item")
            fi
        done
        if [ -z "$PRIMARY_DOMAIN" ]; then
            PRIMARY_DOMAIN="${DOMAIN#*.}"
            DOMAIN_ARGS=("-d" "$PRIMARY_DOMAIN" "${DOMAIN_ARGS[@]}")
        fi
        return 0
    fi
    if [[ "$DOMAIN" == \*.* ]]; then
        PRIMARY_DOMAIN="${DOMAIN#*.}"
        DOMAIN_ARGS=("-d" "$PRIMARY_DOMAIN" "-d" "$DOMAIN")
    else
        PRIMARY_DOMAIN="$DOMAIN"
        DOMAIN_ARGS=("-d" "$DOMAIN" "-d" "*.$DOMAIN")
    fi
}

prepare_output_dirs() {
    local path dir test_file
    for path in "$DOMAIN_CERT_LOCATION" "$PRIVATE_KEY_LOCATION" "$PUBLIC_KEY_LOCATION" "$INTERMEDITE_CERT_LOCATION"; do
        [ -n "$path" ] || fail "Output path cannot be empty"
        dir="$(dirname "$path")"
        install -d -m 0755 "$dir" || fail "Cannot create output directory: $dir"
        [ -d "$dir" ] || fail "Output directory does not exist: $dir"
        [ -w "$dir" ] || fail "Output directory is not writable: $dir"
        test_file="$dir/.renew_cert_write_test.$$"
        : > "$test_file" || fail "Cannot write to output directory: $dir"
        rm -f "$test_file"
    done
}

derive_public_key() {
    openssl x509 -in "$DOMAIN_CERT_LOCATION" -pubkey -noout > "$PUBLIC_KEY_LOCATION"
    chmod 0644 "$PUBLIC_KEY_LOCATION"
}

verify_cert_files() {
    local cert_fp key_fp
    [ -s "$DOMAIN_CERT_LOCATION" ] || fail "SSL fullchain certificate was not created: $DOMAIN_CERT_LOCATION"
    [ -s "$PRIVATE_KEY_LOCATION" ] || fail "Private key was not created: $PRIVATE_KEY_LOCATION"
    [ -s "$PUBLIC_KEY_LOCATION" ] || fail "Public key was not created: $PUBLIC_KEY_LOCATION"
    [ -s "$INTERMEDITE_CERT_LOCATION" ] || fail "Intermediate certificate was not created: $INTERMEDITE_CERT_LOCATION"

    openssl x509 -in "$DOMAIN_CERT_LOCATION" -noout >/dev/null
    openssl pkey -in "$PRIVATE_KEY_LOCATION" -noout >/dev/null
    openssl pkey -pubin -in "$PUBLIC_KEY_LOCATION" -noout >/dev/null

    cert_fp="$(openssl x509 -in "$DOMAIN_CERT_LOCATION" -noout -pubkey | openssl pkey -pubin -outform DER | openssl sha256)"
    key_fp="$(openssl pkey -in "$PRIVATE_KEY_LOCATION" -pubout -outform DER | openssl sha256)"
    [ "$cert_fp" = "$key_fp" ] || fail "SSL certificate and private key do not match."

    chmod 0644 "$DOMAIN_CERT_LOCATION" "$INTERMEDITE_CERT_LOCATION"
    chmod 0600 "$PRIVATE_KEY_LOCATION"
    info "SSL certificate, private key, public key, and intermediate certificate verified."
    info "Certificate expires: $(openssl x509 -in "$DOMAIN_CERT_LOCATION" -noout -enddate | cut -d= -f2-)"
}

issue_certificate() {
    local issue_args install_args reload_cmd
    issue_args=(--issue --dns dns_porkbun "${DOMAIN_ARGS[@]}" --keylength "$ACME_KEY_LENGTH" --dnssleep "$DNS_SLEEP" --server letsencrypt)
    install_args=(--install-cert -d "$PRIMARY_DOMAIN" --fullchain-file "$DOMAIN_CERT_LOCATION" --key-file "$PRIVATE_KEY_LOCATION" --ca-file "$INTERMEDITE_CERT_LOCATION")
    if $STAGING || bool_true "${ACME_STAGING:-}"; then
        issue_args+=(--staging)
        warn "Using Let's Encrypt staging CA. The certificate will not be browser-trusted."
    fi
    if $FORCE || bool_true "${ACME_FORCE:-}"; then
        issue_args+=(--force)
    fi
    if [[ "$ACME_KEY_LENGTH" == ec-* ]]; then
        install_args+=(--ecc)
    fi
    if ! $NO_RELOAD && [ -n "${COMMAND_TO_RELOAD_WEBSERVER:-}" ]; then
        reload_cmd="$COMMAND_TO_RELOAD_WEBSERVER"
        install_args+=(--reloadcmd "$reload_cmd")
    fi
    export PORKBUN_API_KEY="$APIKEY"
    export PORKBUN_SECRET_API_KEY="$SECRET_APIKEY"
    info "Issuing SSL certificate for: ${DOMAIN_ARGS[*]}"
    "$ACME_SH_BIN" "${issue_args[@]}"
    info "Installing SSL certificate and private key."
    "$ACME_SH_BIN" "${install_args[@]}"
}

main() {
    require_command sed
    require_command grep
    require_command curl
    require_command openssl
    require_command install

    load_env
    build_domain_args
    ensure_acme_sh

    info "Env file: $ENV_FILE"
    info "Porkbun endpoint: $ENDPOINT"
    info "Primary domain: $PRIMARY_DOMAIN"
    info "SSL fullchain certificate: $DOMAIN_CERT_LOCATION"
    info "Private key: $PRIVATE_KEY_LOCATION"
    info "Public key: $PUBLIC_KEY_LOCATION"
    info "Intermediate certificate: $INTERMEDITE_CERT_LOCATION"

    if bool_true "${DRY_RUN:-}"; then
        warn "DRY_RUN=true; validation only, no certificate will be issued."
        exit 0
    fi

    prepare_output_dirs
    porkbun_ping
    issue_certificate
    derive_public_key
    verify_cert_files

    info "Certificate generation complete."
    if $NO_RELOAD; then
        warn "Skipped webserver reload because --no-reload was set."
    else
        info "Reload command registered with acme.sh: $COMMAND_TO_RELOAD_WEBSERVER"
    fi
}

main "$@"