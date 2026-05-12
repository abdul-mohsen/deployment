#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ORIGINAL_WORKING_DIR="$(pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
FORCE=false
STAGING=false
NO_RELOAD=false
HOOK_MODE=""

timestamp() { date '+%Y-%m-%d %H:%M:%S%z'; }
log() {
    if [ -n "${HOOK_MODE:-}" ]; then
        printf '%s [%s] %s\n' "$(timestamp)" "$1" "$2" >&2
    else
        printf '%s [%s] %s\n' "$(timestamp)" "$1" "$2"
    fi
}
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
  --force           Force Certbot renewal even if certificate is still valid
  --staging         Use Let's Encrypt staging CA for a test run
  --no-reload       Do not run COMMAND_TO_RELOAD_WEBSERVER after install
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
  Working directory copies:  ./server.crt and ./server.key

Optional .env keys:
  CERTBOT_EMAIL=admin@example.com
  CERTBOT_BIN=certbot
  CERTBOT_CONFIG_DIR=/etc/letsencrypt
  CERTBOT_WORK_DIR=/var/lib/letsencrypt
  CERTBOT_LOGS_DIR=/var/log/letsencrypt
  CERTBOT_KEY_TYPE=rsa
  CERTBOT_RSA_KEY_SIZE=2048
  CERTBOT_ELLIPTIC_CURVE=secp256r1
  CERTBOT_HOOK_DIR=/etc/letsencrypt/porkbun-hooks/<cert-name>
  PORKBUN_DNS_ZONE=ifritah.com
  DNS_SLEEP=120
  DNS_TTL=120

Prerequisites:
  bash, certbot, curl, openssl, sed, grep, install, sh
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
        --hook)
            [ -n "${2:-}" ] || fail "--hook requires auth, cleanup, or deploy"
            HOOK_MODE="$2"
            shift 2
            ;;
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

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

shell_quote() {
    printf '%q' "$1"
}

resolve_path() {
    local path="$1" dir base
    if [[ "$path" == /* ]]; then
        printf '%s' "$path"
        return 0
    fi
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    printf '%s/%s' "$(cd "$dir" && pwd)" "$base"
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

normalize_domain() {
    local value="$1"
    value="${value%.}"
    if [[ "$value" == \*.* ]]; then
        value="${value#*.}"
    fi
    printf '%s' "$value"
}

derive_porkbun_zone() {
    local domain labels_count
    local -a labels
    domain="$(normalize_domain "$1")"
    IFS='.' read -r -a labels <<< "$domain"
    labels_count="${#labels[@]}"
    [ "$labels_count" -ge 2 ] || fail "Cannot derive Porkbun DNS zone from DOMAIN=$DOMAIN. Set PORKBUN_DNS_ZONE."
    printf '%s.%s' "${labels[$((labels_count - 2))]}" "${labels[$((labels_count - 1))]}"
}

configure_defaults() {
    ENDPOINT="${ENDPOINT%/}"

    local email_domain rsa_size
    email_domain="$(normalize_domain "$DOMAIN")"
    CERTBOT_EMAIL="${CERTBOT_EMAIL:-${ACME_EMAIL:-admin@$email_domain}}"
    CERTBOT_BIN="${CERTBOT_BIN:-certbot}"
    CERTBOT_CONFIG_DIR="${CERTBOT_CONFIG_DIR:-/etc/letsencrypt}"
    CERTBOT_WORK_DIR="${CERTBOT_WORK_DIR:-/var/lib/letsencrypt}"
    CERTBOT_LOGS_DIR="${CERTBOT_LOGS_DIR:-/var/log/letsencrypt}"
    CERTBOT_KEY_TYPE="${CERTBOT_KEY_TYPE:-rsa}"
    rsa_size="${CERTBOT_RSA_KEY_SIZE:-}"
    if [ -z "$rsa_size" ] && [[ "${ACME_KEY_LENGTH:-}" =~ ^[0-9]+$ ]]; then
        rsa_size="$ACME_KEY_LENGTH"
    fi
    CERTBOT_RSA_KEY_SIZE="${rsa_size:-2048}"
    CERTBOT_ELLIPTIC_CURVE="${CERTBOT_ELLIPTIC_CURVE:-secp256r1}"
    DNS_SLEEP="${DNS_SLEEP:-120}"
    DNS_TTL="${DNS_TTL:-120}"
    PORKBUN_DNS_ZONE="${PORKBUN_DNS_ZONE:-${PORKBUN_ZONE:-}}"
    if [ -z "$PORKBUN_DNS_ZONE" ]; then
        PORKBUN_DNS_ZONE="$(derive_porkbun_zone "$DOMAIN")"
    fi
    PORKBUN_DNS_ZONE="$(normalize_domain "$PORKBUN_DNS_ZONE")"
}

load_env() {
    local require_outputs="${1:-true}"
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

    if bool_true "$require_outputs"; then
        require_value DOMAIN_CERT_LOCATION
        require_value PRIVATE_KEY_LOCATION
        require_value PUBLIC_KEY_LOCATION
        require_value INTERMEDITE_CERT_LOCATION
        require_value COMMAND_TO_RELOAD_WEBSERVER
    fi

    configure_defaults
}

ensure_certbot() {
    if [[ "$CERTBOT_BIN" == */* ]]; then
        [ -x "$CERTBOT_BIN" ] || fail "Certbot is required but not executable: $CERTBOT_BIN"
    elif command -v "$CERTBOT_BIN" >/dev/null 2>&1; then
        CERTBOT_BIN="$(command -v "$CERTBOT_BIN")"
    else
        fail "Certbot is required. Install it first, for example: sudo apt-get update && sudo apt-get install -y certbot"
    fi
    info "Using Certbot: $CERTBOT_BIN"
}

certbot_supports_option() {
    "$CERTBOT_BIN" --help all 2>&1 | grep -Fq -- "$1"
}

porkbun_payload() {
    printf '{"apikey":"%s","secretapikey":"%s"}' "$(json_escape "$APIKEY")" "$(json_escape "$SECRET_APIKEY")"
}

porkbun_ping() {
    local response status
    response="$(mktemp)"
    status="$(curl -sS --globoff -X POST "$ENDPOINT/ping" -H 'Content-Type: application/json' --data "$(porkbun_payload)" -o "$response" -w '%{http_code}' || true)"
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
            PRIMARY_DOMAIN="$(normalize_domain "$DOMAIN")"
            DOMAIN_ARGS=("-d" "$PRIMARY_DOMAIN" "${DOMAIN_ARGS[@]}")
        fi
        return 0
    fi
    if [[ "$DOMAIN" == \*.* ]]; then
        PRIMARY_DOMAIN="$(normalize_domain "$DOMAIN")"
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

certificate_fingerprint() {
    local cert_path="$1"
    [ -s "$cert_path" ] || return 1
    openssl x509 -in "$cert_path" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2-
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

install_certbot_files() {
    local lineage="$1"
    [ -s "$lineage/fullchain.pem" ] || fail "Certbot fullchain not found: $lineage/fullchain.pem"
    [ -s "$lineage/privkey.pem" ] || fail "Certbot private key not found: $lineage/privkey.pem"
    [ -s "$lineage/chain.pem" ] || fail "Certbot intermediate certificate not found: $lineage/chain.pem"

    install -m 0644 "$lineage/fullchain.pem" "$DOMAIN_CERT_LOCATION"
    install -m 0600 "$lineage/privkey.pem" "$PRIVATE_KEY_LOCATION"
    install -m 0644 "$lineage/chain.pem" "$INTERMEDITE_CERT_LOCATION"
    derive_public_key
    verify_cert_files
}

install_working_dir_server_files() {
    local cert_target="$ORIGINAL_WORKING_DIR/server.crt"
    local key_target="$ORIGINAL_WORKING_DIR/server.key"
    local cert_source key_source

    cert_source="$(resolve_path "$DOMAIN_CERT_LOCATION")"
    key_source="$(resolve_path "$PRIVATE_KEY_LOCATION")"

    if [ "$cert_source" != "$cert_target" ]; then
        install -m 0644 "$cert_source" "$cert_target"
    fi
    if [ "$key_source" != "$key_target" ]; then
        install -m 0600 "$key_source" "$key_target"
    fi
    info "Working-directory certificate copy: $cert_target"
    info "Working-directory private key copy: $key_target"
}

run_reload_command() {
    if $NO_RELOAD; then
        warn "Skipped webserver reload because --no-reload was set."
        return 0
    fi
    [ -n "${COMMAND_TO_RELOAD_WEBSERVER:-}" ] || return 0
    info "Running reload command: $COMMAND_TO_RELOAD_WEBSERVER"
    sh -c "$COMMAND_TO_RELOAD_WEBSERVER"
}

hook_state_dir() {
    local state_dir="${CERTBOT_HOOK_STATE_DIR:-/tmp/renew-cert-porkbun}"
    install -d -m 0700 "$state_dir"
    printf '%s' "$state_dir"
}

safe_state_key() {
    printf '%s' "$1" | sed -e 's/[^A-Za-z0-9_.-]/_/g'
}

challenge_identifier() {
    local identifier="${CERTBOT_IDENTIFIER:-${CERTBOT_DOMAIN:-}}"
    [ -n "$identifier" ] || fail "CERTBOT_IDENTIFIER is required for Certbot DNS hooks."
    normalize_domain "$identifier"
}

challenge_subdomain() {
    local identifier fqdn zone
    identifier="$(challenge_identifier)"
    fqdn="_acme-challenge.$identifier"
    zone="${PORKBUN_DNS_ZONE%.}"
    if [ "$fqdn" = "$zone" ]; then
        printf ''
        return 0
    fi
    case "$fqdn" in
        *."$zone") printf '%s' "${fqdn%.$zone}" ;;
        *) fail "$fqdn is not under Porkbun DNS zone $zone. Set PORKBUN_DNS_ZONE in $ENV_FILE." ;;
    esac
}

record_state_file() {
    local identifier validation state_dir
    identifier="$(challenge_identifier)"
    validation="${CERTBOT_VALIDATION:-}"
    [ -n "$validation" ] || fail "CERTBOT_VALIDATION is required for Certbot DNS hooks."
    state_dir="$(hook_state_dir)"
    printf '%s/%s.%s.record' "$state_dir" "$(safe_state_key "$identifier")" "$(safe_state_key "$validation")"
}

porkbun_create_txt_challenge() {
    local identifier validation subdomain payload response status record_id state_file
    identifier="$(challenge_identifier)"
    validation="${CERTBOT_VALIDATION:-}"
    [ -n "$validation" ] || fail "CERTBOT_VALIDATION is required for Certbot DNS hooks."
    subdomain="$(challenge_subdomain)"
    payload="$(printf '{"apikey":"%s","secretapikey":"%s","type":"TXT","name":"%s","content":"%s","ttl":"%s"}' \
        "$(json_escape "$APIKEY")" \
        "$(json_escape "$SECRET_APIKEY")" \
        "$(json_escape "$subdomain")" \
        "$(json_escape "$validation")" \
        "$(json_escape "$DNS_TTL")")"

    response="$(mktemp)"
    status="$(curl -sS --globoff -X POST "$ENDPOINT/dns/create/$PORKBUN_DNS_ZONE" -H 'Content-Type: application/json' --data "$payload" -o "$response" -w '%{http_code}' || true)"
    if [ "$status" != "200" ] || ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"SUCCESS"' "$response"; then
        warn "Porkbun create TXT response: $(tr -d '\n' < "$response")"
        rm -f "$response"
        fail "Failed to create Porkbun TXT challenge record for $identifier (HTTP $status)."
    fi
    record_id="$(grep -Eo '"id"[[:space:]]*:[[:space:]]*"?[^",}]+' "$response" | head -n 1 | sed -E 's/.*:[[:space:]]*"?([^",}]+).*/\1/')"
    rm -f "$response"
    [ -n "$record_id" ] || fail "Porkbun TXT challenge was created but no record id was returned."

    state_file="$(record_state_file)"
    printf '%s\n' "$record_id" > "$state_file"
    chmod 0600 "$state_file"
    info "Created Porkbun TXT record $record_id for _acme-challenge.$identifier in zone $PORKBUN_DNS_ZONE."

    if [ "${CERTBOT_REMAINING_CHALLENGES:-0}" = "0" ] && [ "${DNS_SLEEP:-0}" -gt 0 ]; then
        info "Waiting $DNS_SLEEP seconds for DNS propagation."
        sleep "$DNS_SLEEP"
    fi

    printf '%s\n' "$record_id"
}

porkbun_delete_txt_challenge() {
    local validation record_id state_file payload response status
    validation="${CERTBOT_VALIDATION:-}"
    record_id="$(printf '%s' "${CERTBOT_AUTH_OUTPUT:-}" | tr -d '\r' | sed -n 's/^[[:space:]]*\([^[:space:]]\+\)[[:space:]]*$/\1/p' | tail -n 1)"
    if [ -z "$record_id" ] && [ -n "$validation" ]; then
        state_file="$(record_state_file)"
        [ -s "$state_file" ] && record_id="$(sed -n '1p' "$state_file")"
    fi
    if [ -z "$record_id" ]; then
        warn "No Porkbun TXT record id found for cleanup; skipping."
        return 0
    fi

    payload="$(porkbun_payload)"
    response="$(mktemp)"
    status="$(curl -sS --globoff -X POST "$ENDPOINT/dns/delete/$PORKBUN_DNS_ZONE/$record_id" -H 'Content-Type: application/json' --data "$payload" -o "$response" -w '%{http_code}' || true)"
    if [ "$status" != "200" ] || ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"SUCCESS"' "$response"; then
        warn "Porkbun delete TXT response: $(tr -d '\n' < "$response")"
        warn "Failed to delete Porkbun TXT challenge record $record_id (HTTP $status)."
        rm -f "$response"
        return 0
    fi
    rm -f "$response"
    if [ -n "$validation" ]; then
        rm -f "$(record_state_file)"
    fi
    info "Deleted Porkbun TXT challenge record $record_id."
}

write_hook_wrapper() {
    local path="$1" mode="$2" no_reload_arg=""
    if [ "$mode" = "deploy" ] && $NO_RELOAD; then
        no_reload_arg=" --no-reload"
    fi
    cat > "$path" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec bash $(shell_quote "$SCRIPT_PATH") --hook $mode --env $(shell_quote "$ENV_FILE")$no_reload_arg
EOF
    chmod 0700 "$path"
}

create_hook_wrappers() {
    CERTBOT_CERT_NAME="${CERTBOT_CERT_NAME:-$PRIMARY_DOMAIN}"
    CERTBOT_HOOK_DIR="${CERTBOT_HOOK_DIR:-$CERTBOT_CONFIG_DIR/porkbun-hooks/$CERTBOT_CERT_NAME}"
    install -d -m 0700 "$CERTBOT_HOOK_DIR"
    CERTBOT_AUTH_HOOK="$CERTBOT_HOOK_DIR/auth.sh"
    CERTBOT_CLEANUP_HOOK="$CERTBOT_HOOK_DIR/cleanup.sh"
    CERTBOT_DEPLOY_HOOK="$CERTBOT_HOOK_DIR/deploy.sh"
    write_hook_wrapper "$CERTBOT_AUTH_HOOK" auth
    write_hook_wrapper "$CERTBOT_CLEANUP_HOOK" cleanup
    write_hook_wrapper "$CERTBOT_DEPLOY_HOOK" deploy
    info "Certbot hooks written to: $CERTBOT_HOOK_DIR"
}

issue_certificate() {
    local certbot_args
    certbot_args=(certonly --manual --preferred-challenges dns --non-interactive --agree-tos \
        --email "$CERTBOT_EMAIL" \
        --cert-name "$CERTBOT_CERT_NAME" \
        --manual-auth-hook "$CERTBOT_AUTH_HOOK" \
        --manual-cleanup-hook "$CERTBOT_CLEANUP_HOOK" \
        --deploy-hook "$CERTBOT_DEPLOY_HOOK" \
        --config-dir "$CERTBOT_CONFIG_DIR" \
        --work-dir "$CERTBOT_WORK_DIR" \
        --logs-dir "$CERTBOT_LOGS_DIR" \
        "${DOMAIN_ARGS[@]}")

    if certbot_supports_option '--manual-public-ip-logging-ok'; then
        certbot_args+=(--manual-public-ip-logging-ok)
    fi
    if $STAGING || bool_true "${CERTBOT_STAGING:-${ACME_STAGING:-}}"; then
        certbot_args+=(--staging)
        warn "Using Let's Encrypt staging CA. The certificate will not be browser-trusted."
    fi
    if $FORCE || bool_true "${CERTBOT_FORCE:-${ACME_FORCE:-}}"; then
        certbot_args+=(--force-renewal)
    else
        certbot_args+=(--keep-until-expiring)
    fi
    case "$CERTBOT_KEY_TYPE" in
        rsa) certbot_args+=(--key-type rsa --rsa-key-size "$CERTBOT_RSA_KEY_SIZE") ;;
        ecdsa) certbot_args+=(--key-type ecdsa --elliptic-curve "$CERTBOT_ELLIPTIC_CURVE") ;;
        *) fail "Unsupported CERTBOT_KEY_TYPE=$CERTBOT_KEY_TYPE. Use rsa or ecdsa." ;;
    esac

    export CERTBOT_HOOK_STATE_DIR="${CERTBOT_HOOK_STATE_DIR:-$(mktemp -d /tmp/renew-cert-porkbun.XXXXXX)}"
    export RENEW_CERT_DEPLOY_MARKER="$CERTBOT_HOOK_STATE_DIR/deploy-ran"
    info "Issuing SSL certificate with Certbot for: ${DOMAIN_ARGS[*]}"
    "$CERTBOT_BIN" "${certbot_args[@]}"
}

main_hook() {
    require_command sed
    require_command grep
    require_command curl
    require_command install

    ENV_FILE="$(resolve_path "$ENV_FILE")"
    if [ "$HOOK_MODE" = "deploy" ]; then
        require_command openssl
        load_env true
        prepare_output_dirs
        local renewed_lineage="${RENEWED_LINEAGE:-$CERTBOT_CONFIG_DIR/live/${CERTBOT_CERT_NAME:-$(normalize_domain "$DOMAIN")}}"
        install_certbot_files "$renewed_lineage"
        [ -n "${RENEW_CERT_DEPLOY_MARKER:-}" ] && : > "$RENEW_CERT_DEPLOY_MARKER"
        run_reload_command
        return 0
    fi

    load_env false
    case "$HOOK_MODE" in
        auth) porkbun_create_txt_challenge ;;
        cleanup) porkbun_delete_txt_challenge ;;
        *) fail "Unknown hook mode: $HOOK_MODE" ;;
    esac
}

main() {
    require_command sed
    require_command grep
    require_command curl
    require_command openssl
    require_command install
    require_command sh
    require_command mktemp
    require_command dirname
    require_command basename
    require_command cut
    require_command tr

    ENV_FILE="$(resolve_path "$ENV_FILE")"
    load_env true
    build_domain_args
    CERTBOT_CERT_NAME="${CERTBOT_CERT_NAME:-$PRIMARY_DOMAIN}"
    CERTBOT_LIVE_DIR="$CERTBOT_CONFIG_DIR/live/$CERTBOT_CERT_NAME"

    info "Env file: $ENV_FILE"
    info "Porkbun endpoint: $ENDPOINT"
    info "Porkbun DNS zone: $PORKBUN_DNS_ZONE"
    info "Primary domain: $PRIMARY_DOMAIN"
    info "Certbot cert name: $CERTBOT_CERT_NAME"
    info "SSL fullchain certificate: $DOMAIN_CERT_LOCATION"
    info "Private key: $PRIVATE_KEY_LOCATION"
    info "Public key: $PUBLIC_KEY_LOCATION"
    info "Intermediate certificate: $INTERMEDITE_CERT_LOCATION"

    if bool_true "${DRY_RUN:-}"; then
        warn "DRY_RUN=true; validation only, no certificate will be issued."
        exit 0
    fi

    ensure_certbot
    prepare_output_dirs
    porkbun_ping
    create_hook_wrappers

    local before_fp after_fp
    before_fp="$(certificate_fingerprint "$DOMAIN_CERT_LOCATION" || true)"
    issue_certificate
    install_certbot_files "$CERTBOT_LIVE_DIR"
    install_working_dir_server_files
    after_fp="$(certificate_fingerprint "$DOMAIN_CERT_LOCATION" || true)"

    if [ -n "${RENEW_CERT_DEPLOY_MARKER:-}" ] && [ -f "$RENEW_CERT_DEPLOY_MARKER" ]; then
        info "Deploy hook already installed the renewed certificate."
    elif [ "$before_fp" != "$after_fp" ]; then
        run_reload_command
    else
        info "Certificate output is unchanged; reload not needed."
    fi

    info "Certificate generation complete."
}

if [ -n "$HOOK_MODE" ]; then
    main_hook
else
    main "$@"
fi