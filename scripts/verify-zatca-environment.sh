#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SETUP_SCRIPT="${SCRIPT_DIR}/setup-zatca-daemon.sh"
readonly HEALTH_SCRIPT="${SCRIPT_DIR}/health-zatca-daemon.sh"

ARG_CONFIG_FILE="${REPO_DIR}/config.env"
ARG_EXPLICIT_CONFIG=false
ARG_INSTALL_ENV=""
ARG_VERBOSE=false

SECRETS_FILE=""
STAGE1_ERR_FILE=""
COMPOSE_ERR_FILE=""
DATABASE_DIAGNOSTIC_FILE=""
HEALTH_DIAGNOSTIC_FILE=""
LOGS_CAPTURE_FILE=""

cleanup_diagnostics() {
    local f
    for f in \
        "$SECRETS_FILE" \
        "$STAGE1_ERR_FILE" \
        "$COMPOSE_ERR_FILE" \
        "$DATABASE_DIAGNOSTIC_FILE" \
        "$HEALTH_DIAGNOSTIC_FILE" \
        "$LOGS_CAPTURE_FILE"; do
        [ -z "$f" ] || rm -f -- "$f"
    done
}
trap cleanup_diagnostics EXIT

usage() {
    cat <<'USAGE'
Usage: scripts/verify-zatca-environment.sh [OPTIONS]

Run a read-only, verbose, start-to-finish verification of the ZATCA deployment
configuration, host readiness, Compose resolution, running daemon parity,
database access, live readiness/JetStream health, and Dokku tenant wiring.

Options:
  --env-file PATH, --config PATH  Select a specific config.env file
                                  (default: <repo>/config.env; never falls back to .env)
  --install-env PATH              Explicit install.env path for drift comparison
                                  (default: sibling install.env next to config.env, if present)
  --verbose, -v                   Include full non-secret mapped daemon env table,
                                  matching drift details, and deeper redacted failure logs
  -h, --help                      Show this help

Exit codes:
  0  All required verification checks passed (OVERALL PASS)
  1  One or more runtime, image, database, or health checks failed or remain unverified
  2  Invocation error, unreadable/unparseable config, or blocking configuration error
USAGE
}

config_error() {
    printf 'FAIL | configuration | %s\n' "$1" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-file|--config)
            [ "$#" -ge 2 ] || config_error "$1 requires a path"
            [ -n "$2" ] || config_error "$1 requires a path"
            ARG_CONFIG_FILE="$2"
            ARG_EXPLICIT_CONFIG=true
            shift 2
            ;;
        --install-env)
            [ "$#" -ge 2 ] || config_error "--install-env requires a path"
            [ -n "$2" ] || config_error "--install-env requires a path"
            ARG_INSTALL_ENV="$2"
            shift 2
            ;;
        --verbose|-v)
            ARG_VERBOSE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            config_error "unknown invocation option"
            ;;
    esac
done

if [ "$ARG_EXPLICIT_CONFIG" = true ] && [[ "$ARG_CONFIG_FILE" != /* ]]; then
    ARG_CONFIG_FILE="${PWD}/${ARG_CONFIG_FILE}"
fi
if [ -n "$ARG_INSTALL_ENV" ] && [[ "$ARG_INSTALL_ENV" != /* ]]; then
    ARG_INSTALL_ENV="${PWD}/${ARG_INSTALL_ENV}"
fi

[ -f "$ARG_CONFIG_FILE" ] || config_error "selected configuration file does not exist"
[ -r "$ARG_CONFIG_FILE" ] || config_error "selected configuration file is not readable"
if [ -n "$ARG_INSTALL_ENV" ] && [ ! -r "$ARG_INSTALL_ENV" ]; then
    config_error "explicit --install-env file is not readable"
fi

readonly SELECTED_CONFIG_FILE="$ARG_CONFIG_FILE"
readonly SELECTED_CONFIG_DIR="$(cd "$(dirname "$SELECTED_CONFIG_FILE")" && pwd)"
readonly EXPLICIT_CONFIG="$ARG_EXPLICIT_CONFIG"
readonly EXPLICIT_INSTALL_ENV="$ARG_INSTALL_ENV"
readonly VERBOSE="$ARG_VERBOSE"

set +e
set -a
# shellcheck disable=SC1090
source "$SELECTED_CONFIG_FILE" >/dev/null 2>&1
source_status=$?
set +a
set +x
set -euo pipefail

CONFIG_FILE="$SELECTED_CONFIG_FILE"
[ "$source_status" -eq 0 ] || config_error "selected configuration file could not be loaded"

VERIFICATION_OK=true
CONFIG_BLOCKED=false
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
NOT_VERIFIED_COUNT=0
NEXT_STEPS=()

HAS_DOCKER=false
HAS_PYTHON=false
HAS_CURL=false
command -v docker >/dev/null 2>&1 && HAS_DOCKER=true
command -v python3 >/dev/null 2>&1 && HAS_PYTHON=true
command -v curl >/dev/null 2>&1 && HAS_CURL=true

add_next_step() {
    local step="$1" existing
    [ -n "$step" ] || return 0
    for existing in "${NEXT_STEPS[@]+"${NEXT_STEPS[@]}"}"; do
        [ "$existing" = "$step" ] && return 0
    done
    NEXT_STEPS+=("$step")
}

emit_stage() {
    printf '\n=== %s ===\n' "$1"
}

emit_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS | %s | %s\n' "$1" "$2"
}

emit_info() {
    printf 'INFO | %s | %s\n' "$1" "$2"
}

emit_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf 'WARN | %s | %s\n' "$1" "$2"
}

emit_hint() {
    printf 'HINT | %s | %s\n' "$1" "$2"
}

mark_failure() {
    local status="$1" check="$2" message="$3"
    printf '%s | %s | %s\n' "$status" "$check" "$message"
    VERIFICATION_OK=false
    if [ "$status" = "FAIL" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        NOT_VERIFIED_COUNT=$((NOT_VERIFIED_COUNT + 1))
    fi
}

# Build a private, mode-600 secrets inventory so every helper can scrub secret
# literals before printing diagnostics, errors, or bounded container logs.
init_secrets_file() {
    SECRETS_FILE="$(mktemp 2>/dev/null || true)"
    [ -n "$SECRETS_FILE" ] || return 0
    chmod 600 "$SECRETS_FILE" 2>/dev/null || true
    [ "$HAS_PYTHON" = true ] || return 0

    local install_candidate=""
    if [ -n "$EXPLICIT_INSTALL_ENV" ]; then
        install_candidate="$EXPLICIT_INSTALL_ENV"
    elif [ -r "${SELECTED_CONFIG_DIR}/install.env" ]; then
        install_candidate="${SELECTED_CONFIG_DIR}/install.env"
    fi
    local dotenv_candidate=""
    if [ -r "${SELECTED_CONFIG_DIR}/.env" ]; then
        dotenv_candidate="${SELECTED_CONFIG_DIR}/.env"
    fi

    python3 - "$SECRETS_FILE" "$SELECTED_CONFIG_FILE" "$install_candidate" "$dotenv_candidate" <<'PY' 2>/dev/null || true
import os
import re
import sys

out_path, cfg_path, install_path, dotenv_path = sys.argv[1:5]
secret_key_re = re.compile(
    r"(?:PASS|PASSWORD|PASSWD|SECRET|TOKEN|ENCRYPT_KEY|PRIVATE_KEY|API_KEY|AUTH_KEY)",
    re.IGNORECASE,
)
known_secret_keys = {
    "ZATCA_DB_PASSWORD",
    "ZATCA_ADMIN_DB_PASSWORD",
    "ZATCA_ENCRYPT_KEY",
    "ZATCA_MONITOR_PASSWORD",
    "NATS_PASSWORD",
    "ZATCA_SMTP_PASSWORD",
    "MYSQL_ROOT_PASSWORD",
    "MYSQL_ADMIN_PASSWORD",
    "WEBHOOK_SECRET",
    "OPENOBSERVE_TENANT_OTLP_TOKEN",
    "METRICS_TOKEN",
    "DB_PASS",
    "ADMIN_DB_PASS",
    "ENCRYPT_KEY",
    "MONITOR_PASS",
    "SMTP_PASS",
    "PASSWORD",
    "JWT_SECERT_KEY",
    "JWT_SECRET_KEY",
    "SESSION_SECRET",
}

secrets = set()

def add_val(v):
    if not isinstance(v, str):
        return
    s = v.strip()
    if len(s) >= 4:
        secrets.add(s)

for k, v in os.environ.items():
    if k in known_secret_keys or secret_key_re.search(k):
        add_val(v)

def parse_env_file(path):
    if not path or not os.path.isfile(path):
        return
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[7:].strip()
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k in known_secret_keys or secret_key_re.search(k):
                    add_val(v)
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                        add_val(v[1:-1])
    except OSError:
        pass

for p in (cfg_path, install_path, dotenv_path):
    parse_env_file(p)

with open(out_path, "w", encoding="utf-8") as fh:
    for item in sorted(secrets, key=len, reverse=True):
        fh.write(item.replace("\n", "") + "\n")
PY
}

append_running_env_secrets() {
    local running_json="$1" py_code=""
    [ -n "$SECRETS_FILE" ] && [ "$HAS_PYTHON" = true ] && [ -n "$running_json" ] || return 0
    IFS= read -r -d '' py_code <<'PY' || true
import json
import re
import sys

secrets_path = sys.argv[1]
secret_key_re = re.compile(
    r"(?:PASS|PASSWORD|PASSWD|SECRET|TOKEN|ENCRYPT_KEY|PRIVATE_KEY|API_KEY|AUTH_KEY)",
    re.IGNORECASE,
)
try:
    items = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(items, list):
    raise SystemExit(0)

existing = set()
try:
    with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.rstrip("\n")
            if s:
                existing.add(s)
except OSError:
    pass

for item in items:
    if not isinstance(item, str) or "=" not in item:
        continue
    k, v = item.split("=", 1)
    if secret_key_re.search(k) and len(v.strip()) >= 4:
        existing.add(v.strip())

with open(secrets_path, "w", encoding="utf-8") as fh:
    for s in sorted(existing, key=len, reverse=True):
        fh.write(s.replace("\n", "") + "\n")
PY
    printf '%s' "$running_json" | python3 -c "$py_code" "$SECRETS_FILE" 2>/dev/null || true
}

redact_stdin() {
    local py_code=""
    if [ "$HAS_PYTHON" != true ]; then
        printf '[diagnostics redacted; python3 unavailable]\n'
        return 0
    fi
    IFS= read -r -d '' py_code <<'PY' || true
import re
import sys

secrets_path = sys.argv[1]
secrets = []
if secrets_path:
    try:
        with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
            secrets = [line.rstrip("\n") for line in fh if len(line.rstrip("\n")) >= 4]
    except OSError:
        secrets = []
secrets.sort(key=len, reverse=True)

text = sys.stdin.read()
for s in secrets:
    if s in text:
        text = text.replace(s, "[REDACTED]")

# Scrub ANSI escapes and non-printable control characters except tab/newline
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)

# Scrub URI user:pass@, MySQL Go DSN user:pass@tcp(, Bearer/Basic auth, key=value secrets
text = re.sub(r"([a-zA-Z][a-zA-Z0-9+.-]*://)([^:@/\s]+):([^@/\s]+)@", r"\1[REDACTED]@", text)
text = re.sub(r"([A-Za-z0-9._-]+):([^@\s]+)@tcp\(", r"\1:[REDACTED]@tcp(", text)
text = re.sub(r"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9+/=._-]{4,}", r"\1 [REDACTED]", text)
text = re.sub(
    r'(?i)\b([A-Za-z0-9_.-]*(?:password|passwd|pass|pwd|secret|token|encrypt_key|monitor_pass|api_key|authorization))\s*([:=])\s*(?:"[^"]*"|\'[^\']*\'|[^\s,;}\]]+)',
    r"\1\2[REDACTED]",
    text,
)
sys.stdout.write(text)
PY
    python3 -c "$py_code" "${SECRETS_FILE:-}" 2>/dev/null || printf '[diagnostics redacted]\n'
}

safe_display_value() {
    local raw="${1:-}" allow_at="${2:-false}" py_code=""
    if [ -z "$raw" ]; then
        printf '(empty)'
        return 0
    fi
    if [ "$HAS_PYTHON" != true ]; then
        if [[ "$raw" =~ ^[A-Za-z0-9._:/-]+$ ]] && [ "${#raw}" -le 120 ]; then
            printf '%s' "$raw"
        else
            printf '[REDACTED]'
        fi
        return 0
    fi
    IFS= read -r -d '' py_code <<'PY' || true
import re
import sys

secrets_path = sys.argv[1]
allow_at = sys.argv[2] == "true"
val = sys.stdin.read()

if not val:
    print("(empty)", end="")
    raise SystemExit(0)

if any(ord(ch) < 32 or ord(ch) == 127 for ch in val):
    print("[REDACTED]", end="")
    raise SystemExit(0)

if not allow_at and "@" in val:
    print("[REDACTED]", end="")
    raise SystemExit(0)

if secrets_path:
    try:
        with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                s = line.rstrip("\n")
                if len(s) >= 4 and s in val:
                    print("[REDACTED]", end="")
                    raise SystemExit(0)
    except OSError:
        pass

if re.search(r"://[^:@/\s]+:[^@/\s]+@", val):
    print("[REDACTED]", end="")
    raise SystemExit(0)

if len(val) > 160:
    val = val[:157] + "..."
print(val, end="")
PY
    printf '%s' "$raw" | python3 -c "$py_code" "${SECRETS_FILE:-}" "$allow_at" 2>/dev/null || printf '[REDACTED]'
}

is_valid_port() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 ))
}

init_secrets_file

# =============================================================================
# Stage 1: Configuration, Security Gates & File Drift
# =============================================================================
emit_stage "Stage 1/6: Configuration, Security Gates & File Drift"

config_source_kind="default"
[ "$EXPLICIT_CONFIG" = true ] && config_source_kind="explicit"
emit_info "config.file" "path=${SELECTED_CONFIG_FILE} source=${config_source_kind}"

DAEMON_ENABLED=false
case "${ZATCA_DAEMON_ENABLED:-}" in
    1|true|yes) DAEMON_ENABLED=true ;;
esac

if [ "$HAS_PYTHON" = true ]; then
    stage1_output="$(
        python3 - "$SELECTED_CONFIG_FILE" "$EXPLICIT_INSTALL_ENV" "$VERBOSE" "$SECRETS_FILE" <<'PY'
import base64
import datetime
import ipaddress
import os
import re
import stat
import sys

cfg_path, explicit_install, verbose_str, secrets_path = sys.argv[1:5]
verbose = verbose_str == "true"
cfg_dir = os.path.dirname(os.path.abspath(cfg_path))

secrets = []
if secrets_path and os.path.isfile(secrets_path):
    try:
        with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
            secrets = [line.rstrip("\n") for line in fh if len(line.rstrip("\n")) >= 4]
    except OSError:
        secrets = []
secrets.sort(key=len, reverse=True)

secret_key_re = re.compile(
    r"(?:PASS|PASSWORD|PASSWD|SECRET|TOKEN|ENCRYPT_KEY|PRIVATE_KEY|API_KEY|AUTH_KEY)",
    re.IGNORECASE,
)

def safe_nonsecret(val, allow_at=False):
    if val is None or val == "":
        return "(empty)"
    if any(ord(c) < 32 or ord(c) == 127 for c in val):
        return "[REDACTED]"
    if not allow_at and "@" in val:
        return "[REDACTED]"
    for s in secrets:
        if s in val:
            return "[REDACTED]"
    if re.search(r"://[^:@/\s]+:[^@/\s]+@", val):
        return "[REDACTED]"
    return val[:157] + "..." if len(val) > 160 else val

def emit(kind, check, msg, blocking="0", step=""):
    msg = msg.replace("\t", " ").replace("\n", " ").replace("\r", "")
    step = step.replace("\t", " ").replace("\n", " ").replace("\r", "")
    print(f"{kind}\t{check}\t{msg}\t{blocking}\t{step}")

# 1. File hygiene: CRLF & permissions
try:
    with open(cfg_path, "rb") as fh:
        raw_bytes = fh.read()
    crlf_count = raw_bytes.count(b"\r\n")
    if crlf_count > 0:
        emit(
            "FAIL",
            "config.format.crlf",
            f"CRLF line endings detected on {crlf_count} line(s) in {cfg_path}; Bash and Docker Compose may retain trailing \\r in values",
            "1",
            f"Strip CRLF line endings from {cfg_path}: sed -i 's/\\r$//' {cfg_path}",
        )
    else:
        emit("PASS", "config.format.crlf", "configuration file uses Unix LF line endings")
except OSError:
    emit("WARN", "config.format.crlf", "could not inspect line endings")

try:
    mode = stat.S_IMODE(os.stat(cfg_path).st_mode)
    if mode & stat.S_IROTH:
        emit(
            "WARN",
            "config.permissions",
            f"configuration file mode is {mode:04o} (world-readable); restrict permissions because it holds secrets",
            "0",
            f"Restrict config file permissions: chmod 600 {cfg_path}",
        )
    elif mode & stat.S_IWGRP or mode & stat.S_IWOTH:
        emit(
            "WARN",
            "config.permissions",
            f"configuration file mode is {mode:04o} (group/world writable); restrict to 0600",
            "0",
            f"Restrict config file permissions: chmod 600 {cfg_path}",
        )
    elif verbose:
        emit("PASS", "config.permissions", f"configuration file mode is {mode:04o}")
except OSError:
    pass

# 2. Raw env-file static scan (duplicates, $, trailing whitespace, inline #)
def parse_raw_env(path):
    entries = {}
    duplicates = []
    dollar_keys = []
    trailing_ws_keys = []
    hash_keys = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                line = raw_line.rstrip("\r\n")
                stripped = line.lstrip()
                if not stripped or stripped.startswith("#"):
                    continue
                if stripped.startswith("export "):
                    stripped = stripped[7:].lstrip()
                if "=" not in stripped:
                    continue
                k, raw_v = stripped.split("=", 1)
                k = k.strip()
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
                    continue
                if k in entries and k not in duplicates:
                    duplicates.append(k)
                unquoted = raw_v
                is_quoted = len(raw_v) >= 2 and raw_v[0] == raw_v[-1] and raw_v[0] in ("'", '"')
                if is_quoted:
                    unquoted = raw_v[1:-1]
                else:
                    if raw_v and raw_v != raw_v.rstrip(" \t"):
                        if k not in trailing_ws_keys:
                            trailing_ws_keys.append(k)
                    if "#" in raw_v and k not in hash_keys:
                        hash_keys.append(k)
                if "$" in raw_v and "$$" not in raw_v and k not in dollar_keys:
                    dollar_keys.append(k)
                entries[k] = unquoted
    except OSError:
        return None, [], [], [], []
    return entries, duplicates, dollar_keys, trailing_ws_keys, hash_keys

raw_entries, dup_keys, dollar_keys, ws_keys, hash_keys = parse_raw_env(cfg_path)
if dup_keys:
    emit(
        "WARN",
        "config.duplicate_keys",
        "keys defined multiple times in selected config (last value wins): " + ", ".join(sorted(dup_keys)),
        "0",
        f"Remove duplicate key definitions in {cfg_path}: " + ", ".join(sorted(dup_keys)),
    )
if dollar_keys:
    emit(
        "WARN",
        "config.syntax.dollar",
        "keys contain unescaped '$' which Docker Compose interpolates differently from Bash: " + ", ".join(sorted(dollar_keys)),
        "0",
        "Check keys containing '$' in " + cfg_path + " (" + ", ".join(sorted(dollar_keys)) + "); avoid '$' or verify Bash-vs-Compose interpolation parity",
    )
if ws_keys:
    emit(
        "WARN",
        "config.syntax.whitespace",
        "unquoted trailing whitespace detected on keys: " + ", ".join(sorted(ws_keys)),
        "0",
        f"Remove trailing spaces on keys in {cfg_path}: " + ", ".join(sorted(ws_keys)),
    )
if hash_keys:
    emit(
        "WARN",
        "config.syntax.hash",
        "unquoted '#' detected in values (Bash vs Docker Compose comment rules differ): " + ", ".join(sorted(hash_keys)),
        "0",
        f"Verify keys containing '#' in {cfg_path}: " + ", ".join(sorted(hash_keys)),
    )

def env_get(key, default=""):
    val = os.environ.get(key)
    if val is None:
        return default
    return val.rstrip("\r")

# 3. Daemon enabled flag
enabled_raw = env_get("ZATCA_DAEMON_ENABLED", "")
daemon_enabled = enabled_raw in ("1", "true", "yes")
if daemon_enabled:
    emit("PASS", "config.enabled", f"ZATCA_DAEMON_ENABLED={safe_nonsecret(enabled_raw)}")
else:
    emit(
        "FAIL",
        "config.enabled",
        f"ZATCA_DAEMON_ENABLED must be enabled (1, true, or yes); currently {safe_nonsecret(enabled_raw)}",
        "1",
        f"Set ZATCA_DAEMON_ENABLED=1 in {cfg_path} once all required settings and security gates are configured",
    )

# 4. All 7 required settings checked together
required_keys = [
    "ZATCA_DAEMON_IMAGE",
    "ZATCA_DB_USER",
    "ZATCA_DB_PASSWORD",
    "ZATCA_ENCRYPT_KEY",
    "ZATCA_MONITOR_PASSWORD",
    "NATS_USER",
    "NATS_PASSWORD",
]
missing_required = [k for k in required_keys if not env_get(k, "")]
if not missing_required:
    emit("PASS", "config.required", "all 7 required daemon settings are populated")
else:
    emit(
        "FAIL",
        "config.required",
        "missing required settings: " + ", ".join(missing_required),
        "1",
        f"Populate missing required keys in {cfg_path}: " + ", ".join(missing_required),
    )

# 5. Optional account pairs
admin_user = env_get("ZATCA_ADMIN_DB_USER", "")
admin_pass = env_get("ZATCA_ADMIN_DB_PASSWORD", "")
if bool(admin_user) != bool(admin_pass):
    emit(
        "FAIL",
        "config.optional.admin_db",
        "ZATCA_ADMIN_DB_USER and ZATCA_ADMIN_DB_PASSWORD must be configured together",
        "1",
        f"Set both ZATCA_ADMIN_DB_USER and ZATCA_ADMIN_DB_PASSWORD in {cfg_path}, or unset both",
    )
elif admin_user:
    emit("PASS", "config.optional.admin_db", f"onboarding DB account configured (user={safe_nonsecret(admin_user)})")
else:
    emit("INFO", "config.optional.admin_db", "optional onboarding DB account (ZATCA_ADMIN_DB_*) not configured")

smtp_user = env_get("ZATCA_SMTP_USER", "")
smtp_pass = env_get("ZATCA_SMTP_PASSWORD", "")
if bool(smtp_user) != bool(smtp_pass):
    emit(
        "WARN",
        "config.optional.smtp",
        "ZATCA_SMTP_USER and ZATCA_SMTP_PASSWORD are only partially configured",
        "0",
        f"Set both ZATCA_SMTP_USER and ZATCA_SMTP_PASSWORD in {cfg_path}, or leave both empty",
    )

# 6. ZATCA_ENCRYPT_KEY format check (32-byte AES-256 hex/base64/raw)
enc_key = env_get("ZATCA_ENCRYPT_KEY", "")
if enc_key:
    enc_ok = False
    enc_kind = ""
    if re.fullmatch(r"[0-9a-fA-F]{64}", enc_key):
        enc_ok = True
        enc_kind = "32-byte hex"
    else:
        for decoder in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                padded = enc_key + ("=" * ((4 - len(enc_key) % 4) % 4))
                decoded = decoder(padded.encode("ascii"))
                if len(decoded) == 32:
                    enc_ok = True
                    enc_kind = "32-byte base64"
                    break
            except Exception:
                pass
        if not enc_ok and len(enc_key.encode("utf-8")) == 32:
            enc_ok = True
            enc_kind = "32-byte raw"
    if enc_ok:
        emit("PASS", "config.encrypt_key", f"ZATCA_ENCRYPT_KEY format valid ({enc_kind} AES-256 key)")
    else:
        emit(
            "WARN",
            "config.encrypt_key",
            "ZATCA_ENCRYPT_KEY does not decode to 32 bytes (expected 44-char base64 or 64-char hex for AES-256); branch config decryption may fail",
            "0",
            f"Verify ZATCA_ENCRYPT_KEY in {cfg_path} is a valid 32-byte AES-256 key (e.g. openssl rand -base64 32) matching stored branch certificates",
        )

# 7. All NATS security gates checked individually
gate_failures = []

if env_get("NATS_PRIVATE_NETWORK_ONLY", "false") not in ("1", "true", "yes"):
    gate_failures.append("NATS_PRIVATE_NETWORK_ONLY must be true (overlay runs NATS without TLS)")
if env_get("NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED", "false") not in ("1", "true", "yes"):
    gate_failures.append("NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED must be true after confirming host firewall restricts NATS port")
if env_get("NATS_SHARED_CREDENTIALS_ACKNOWLEDGED", "false") not in ("1", "true", "yes"):
    gate_failures.append("NATS_SHARED_CREDENTIALS_ACKNOWLEDGED must be true")
if not env_get("NATS_SHARED_CREDENTIALS_APPROVAL_ID", ""):
    gate_failures.append("NATS_SHARED_CREDENTIALS_APPROVAL_ID is empty")

expires = env_get("NATS_SHARED_CREDENTIALS_EXPIRES", "")
if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", expires):
    gate_failures.append("NATS_SHARED_CREDENTIALS_EXPIRES must use YYYY-MM-DD format")
else:
    try:
        exp_date = datetime.date.fromisoformat(expires)
        today_utc = datetime.datetime.now(datetime.timezone.utc).date()
        if exp_date <= today_utc:
            gate_failures.append(f"NATS_SHARED_CREDENTIALS_EXPIRES ({expires}) is expired (must be after {today_utc.isoformat()})")
        else:
            days_left = (exp_date - today_utc).days
            if days_left <= 14:
                emit(
                    "WARN",
                    "config.security_gates.expiry",
                    f"NATS_SHARED_CREDENTIALS_EXPIRES ({expires}) expires in {days_left} day(s)",
                    "0",
                    f"Renew NATS_SHARED_CREDENTIALS_EXPIRES in {cfg_path} before {expires}",
                )
    except ValueError:
        gate_failures.append("NATS_SHARED_CREDENTIALS_EXPIRES is not a valid calendar date")

if not gate_failures:
    emit(
        "PASS",
        "config.security_gates",
        f"all 5 NATS security gates are valid (approval_id={safe_nonsecret(env_get('NATS_SHARED_CREDENTIALS_APPROVAL_ID', ''))} expires={safe_nonsecret(expires)})",
    )
else:
    for idx, reason in enumerate(gate_failures, 1):
        emit(
            "FAIL",
            f"config.security_gates.{idx}",
            reason,
            "1",
            f"Update NATS security gate settings in {cfg_path}: {reason}",
        )

# 8. Numeric ports & thresholds (never print invalid raw values)
port_specs = [
    ("MYSQL_PORT", "3306", True),
    ("ZATCA_NATS_PORT", "4222", True),
    ("ZATCA_NATS_MONITOR_PORT", "8222", True),
    ("ZATCA_SMTP_PORT", "25", False),
    ("DOKKU_PORT", "8080", False),
]
port_errors = []
resolved_ports = {}
for key, default_val, required_valid in port_specs:
    raw_val = env_get(key, "")
    effective = raw_val if raw_val != "" else default_val
    if re.fullmatch(r"[0-9]{1,5}", effective) and 1 <= int(effective) <= 65535:
        resolved_ports[key] = int(effective)
    else:
        resolved_ports[key] = None
        if required_valid or raw_val != "":
            port_errors.append(key)
            emit(
                "FAIL",
                f"config.port.{key}",
                f"{key} is not a valid TCP port (expected integer 1-65535)",
                "0",
                f"Set {key} in {cfg_path} to a valid integer TCP port between 1 and 65535",
            )
if not port_errors:
    emit(
        "PASS",
        "config.ports",
        f"all configured TCP ports are valid (mysql={resolved_ports['MYSQL_PORT']} nats={resolved_ports['ZATCA_NATS_PORT']} monitor={resolved_ports['ZATCA_NATS_MONITOR_PORT']})",
    )

for key, default_val, allow_zero in (
    ("ZATCA_MAX_PENDING", "1000", False),
    ("ZATCA_MAX_ACK_PENDING", "100", True),
):
    raw_val = env_get(key, "")
    eff = raw_val if raw_val != "" else default_val
    ok = re.fullmatch(r"[0-9]+", eff) is not None and (int(eff) >= 0 if allow_zero else int(eff) > 0)
    if not ok:
        emit(
            "FAIL",
            f"config.threshold.{key}",
            f"{key} must be a {'non-negative' if allow_zero else 'positive'} integer",
            "0",
            f"Set {key} in {cfg_path} to a valid {'non-negative' if allow_zero else 'positive'} integer",
        )

# 9. NATS_URL consistency with ZATCA_NATS_PORT
nats_url = env_get("NATS_URL", "")
nats_port = resolved_ports.get("ZATCA_NATS_PORT") or 4222
if not nats_url:
    emit("INFO", "config.nats_url", f"NATS_URL is empty; backend apps will derive nats://host.docker.internal:{nats_port}")
else:
    if not (nats_url.startswith("nats://") or nats_url.startswith("tls://")):
        emit(
            "FAIL",
            "config.nats_url",
            "NATS_URL must start with nats:// or tls://",
            "1",
            f"Fix NATS_URL in {cfg_path} (leave empty to derive nats://host.docker.internal:{nats_port})",
        )
    elif "@" in nats_url or "," in nats_url or re.search(r"\s", nats_url):
        emit(
            "FAIL",
            "config.nats_url",
            "NATS_URL must not contain embedded credentials, commas, or whitespace",
            "1",
            f"Remove embedded credentials/spaces from NATS_URL in {cfg_path}; use NATS_USER and NATS_PASSWORD instead",
        )
    else:
        hostport = nats_url.split("://", 1)[1].split("/", 1)[0]
        url_port = 4222
        if ":" in hostport and not hostport.endswith("]"):
            maybe_port = hostport.rsplit(":", 1)[1]
            if re.fullmatch(r"[0-9]{1,5}", maybe_port) and 1 <= int(maybe_port) <= 65535:
                url_port = int(maybe_port)
            else:
                url_port = None
        if url_port is None:
            emit(
                "FAIL",
                "config.nats_url",
                "NATS_URL contains an invalid port (must be 1-65535)",
                "1",
                f"Fix the port in NATS_URL in {cfg_path} to match ZATCA_NATS_PORT={nats_port}",
            )
        elif daemon_enabled and resolved_ports.get("ZATCA_NATS_PORT") is not None and url_port != nats_port:
            emit(
                "FAIL",
                "config.nats_url",
                f"NATS_URL port ({url_port}) does not match ZATCA_NATS_PORT ({nats_port})",
                "1",
                f"Align NATS_URL port with ZATCA_NATS_PORT={nats_port} in {cfg_path} (or leave NATS_URL empty)",
            )
        else:
            emit("PASS", "config.nats_url", f"NATS_URL is valid and matches ZATCA_NATS_PORT={nats_port} ({safe_nonsecret(nats_url)})")

# 10. Sibling install.env drift check
install_path = explicit_install if explicit_install else os.path.join(cfg_dir, "install.env")
if os.path.isfile(install_path) and os.path.realpath(install_path) != os.path.realpath(cfg_path):
    inst_entries, _, _, _, _ = parse_raw_env(install_path)
    if inst_entries is None:
        emit("WARN", "config.drift.install_env", f"sibling install.env at {install_path} could not be read")
    else:
        drift_found = False
        shared_nonsecret = [
            "MYSQL_HOST",
            "MYSQL_PORT",
            "MYSQL_MASTER_DB",
            "DOKKU_PORT",
            "BASE_DOMAIN",
            "STORAGE_ROOT",
            "BACKUP_DIR",
        ]
        for k in shared_nonsecret:
            c_val = env_get(k, "")
            i_val = inst_entries.get(k, "")
            if c_val and i_val and c_val != i_val:
                drift_found = True
                emit(
                    "WARN",
                    "config.drift.install_env",
                    f"{k} differs between selected config ({safe_nonsecret(c_val)}) and {os.path.basename(install_path)} ({safe_nonsecret(i_val)})",
                    "0",
                    f"Reconcile {k} between {cfg_path} and {install_path}",
                )
        # Boolean-only password consistency when usernames match
        z_user = env_get("ZATCA_DB_USER", "")
        z_pass = env_get("ZATCA_DB_PASSWORD", "")
        for u_key, p_key in (
            ("MYSQL_ADMIN_USER", "MYSQL_ADMIN_PASSWORD"),
            ("MYSQL_ROOT_USER", "MYSQL_ROOT_PASSWORD"),
        ):
            i_user = inst_entries.get(u_key, "")
            i_pass = inst_entries.get(p_key, "")
            if z_user and i_user and z_user == i_user and z_pass and i_pass:
                if z_pass != i_pass:
                    drift_found = True
                    emit(
                        "WARN",
                        "config.drift.install_env",
                        f"ZATCA_DB_USER matches {os.path.basename(install_path)} {u_key} ({safe_nonsecret(z_user)}), but ZATCA_DB_PASSWORD differs from {p_key}",
                        "0",
                        f"Verify password alignment for MySQL user {safe_nonsecret(z_user)} between {cfg_path} (ZATCA_DB_PASSWORD) and {install_path} ({p_key})",
                    )
                elif verbose:
                    emit(
                        "PASS",
                        "config.drift.install_env",
                        f"ZATCA_DB_PASSWORD matches {os.path.basename(install_path)} {p_key} for shared user {safe_nonsecret(z_user)}",
                    )
        c_root_user = env_get("MYSQL_ROOT_USER", "")
        c_root_pass = env_get("MYSQL_ROOT_PASSWORD", "")
        i_root_user = inst_entries.get("MYSQL_ROOT_USER", "")
        i_root_pass = inst_entries.get("MYSQL_ROOT_PASSWORD", "")
        if c_root_user and i_root_user and c_root_user == i_root_user and c_root_pass and i_root_pass and c_root_pass != i_root_pass:
            drift_found = True
            emit(
                "WARN",
                "config.drift.install_env",
                f"MYSQL_ROOT_PASSWORD in selected config differs from {os.path.basename(install_path)} for user {safe_nonsecret(c_root_user)}",
                "0",
                f"Reconcile MYSQL_ROOT_PASSWORD between {cfg_path} and {install_path}",
            )
        if not drift_found:
            emit("PASS", "config.drift.install_env", f"sibling {os.path.basename(install_path)} settings align with selected config")
else:
    emit("INFO", "config.drift.install_env", "no sibling install.env found (skipped)")

# 11. Sibling .env drift/shadowing check
dotenv_path = os.path.join(cfg_dir, ".env")
if os.path.isfile(dotenv_path) and os.path.realpath(dotenv_path) != os.path.realpath(cfg_path):
    dot_entries, _, _, _, _ = parse_raw_env(dotenv_path)
    if dot_entries:
        watched = [
            "ZATCA_DAEMON_ENABLED",
            "ZATCA_DAEMON_IMAGE",
            "ZATCA_DB_USER",
            "ZATCA_DB_PASSWORD",
            "MYSQL_HOST",
            "MYSQL_PORT",
            "MYSQL_MASTER_DB",
            "ZATCA_ADMIN_DB_USER",
            "ZATCA_ADMIN_DB_PASSWORD",
            "ZATCA_ENCRYPT_KEY",
            "ZATCA_MONITOR_PASSWORD",
            "NATS_USER",
            "NATS_PASSWORD",
            "ZATCA_NATS_PORT",
            "ZATCA_NATS_MONITOR_PORT",
        ]
        present = [k for k in watched if k in dot_entries]
        if present:
            diffs = [k for k in present if dot_entries.get(k, "") != env_get(k, "")]
            if diffs:
                emit(
                    "WARN",
                    "config.drift.dotenv",
                    f"sibling .env differs from selected config on {len(diffs)} key(s): " + ", ".join(diffs) + "; plain 'docker compose' without --env-file would load stale .env values",
                    "0",
                    f"Always pass --env-file {cfg_path} to docker compose, or remove/sync stale ZATCA keys in {dotenv_path}",
                )
            elif verbose:
                emit("INFO", "config.drift.dotenv", "sibling .env exists and matches selected config (always pass --env-file when invoking docker compose)")
PY
    )"

    while IFS=$'\t' read -r kind check msg blocking step; do
        [ -n "$kind" ] || continue
        case "$kind" in
            PASS) emit_pass "$check" "$msg" ;;
            INFO) emit_info "$check" "$msg" ;;
            WARN) emit_warn "$check" "$msg" ;;
            FAIL)
                mark_failure "FAIL" "$check" "$msg"
                if [ "$blocking" = "1" ]; then
                    CONFIG_BLOCKED=true
                fi
                ;;
        esac
        [ -z "$step" ] || add_next_step "$step"
    done <<< "$stage1_output"
else
    # Pure-Bash fallback if python3 is unavailable
    if [ "$DAEMON_ENABLED" = true ]; then
        emit_pass "config.enabled" "ZATCA_DAEMON_ENABLED is enabled"
    else
        mark_failure "FAIL" "config.enabled" "ZATCA_DAEMON_ENABLED must be enabled"
        CONFIG_BLOCKED=true
    fi
    missing_bash=()
    for required_setting in \
        ZATCA_DAEMON_IMAGE \
        ZATCA_DB_USER \
        ZATCA_DB_PASSWORD \
        ZATCA_ENCRYPT_KEY \
        ZATCA_MONITOR_PASSWORD \
        NATS_USER \
        NATS_PASSWORD; do
        [ -n "${!required_setting:-}" ] || missing_bash+=("$required_setting")
    done
    if [ "${#missing_bash[@]}" -eq 0 ]; then
        emit_pass "config.required" "all 7 required daemon settings are populated"
    else
        mark_failure "FAIL" "config.required" "missing required settings: ${missing_bash[*]}"
        CONFIG_BLOCKED=true
    fi
    if { [ -n "${ZATCA_ADMIN_DB_USER:-}" ] && [ -z "${ZATCA_ADMIN_DB_PASSWORD:-}" ]; } ||
        { [ -z "${ZATCA_ADMIN_DB_USER:-}" ] && [ -n "${ZATCA_ADMIN_DB_PASSWORD:-}" ]; }; then
        mark_failure "FAIL" "config.optional.admin_db" "ZATCA_ADMIN_DB_USER and ZATCA_ADMIN_DB_PASSWORD must be configured together"
        CONFIG_BLOCKED=true
    fi
fi

# Run setup-zatca-daemon.sh --validate-only when enabled
SETUP_VALIDATION_OK=false
if [ ! -f "$SETUP_SCRIPT" ]; then
    mark_failure "FAIL" "config.validation" "daemon configuration validator (${SETUP_SCRIPT}) is unavailable"
    CONFIG_BLOCKED=true
elif [ "$DAEMON_ENABLED" != true ]; then
    emit_info "config.validation" "skipped setup-zatca-daemon.sh --validate-only because ZATCA_DAEMON_ENABLED is disabled"
else
    STAGE1_ERR_FILE="$(mktemp 2>/dev/null || true)"
    if [ -n "$STAGE1_ERR_FILE" ]; then
        chmod 600 "$STAGE1_ERR_FILE" 2>/dev/null || true
        if bash "$SETUP_SCRIPT" --config "$CONFIG_FILE" --validate-only >/dev/null 2>"$STAGE1_ERR_FILE"; then
            SETUP_VALIDATION_OK=true
            emit_pass "config.validation" "required settings and Compose validation passed"
        else
            redacted_setup_err=""
            if [ -s "$STAGE1_ERR_FILE" ]; then
                redacted_setup_err="$(head -n 3 "$STAGE1_ERR_FILE" | redact_stdin | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
            fi
            if [ -n "$redacted_setup_err" ]; then
                mark_failure "FAIL" "config.validation" "daemon configuration validation failed (${redacted_setup_err})"
            else
                mark_failure "FAIL" "config.validation" "daemon configuration validation failed"
            fi
            CONFIG_BLOCKED=true
            add_next_step "Fix the Stage 1 configuration/Compose errors above, then re-run: bash scripts/setup-zatca-daemon.sh --config ${CONFIG_FILE} --validate-only"
        fi
    else
        mark_failure "NOT VERIFIED" "config.validation" "could not allocate temporary diagnostic file"
    fi
fi

# =============================================================================
# Stage 2: Host Tooling, Directories & Port Conflicts
# =============================================================================
emit_stage "Stage 2/6: Host Tooling, Directories & Port Conflicts"

if [ "$HAS_DOCKER" = true ]; then
    emit_pass "host.docker" "Docker CLI is available"
else
    mark_failure "NOT VERIFIED" "docker" "Docker is unavailable"
    add_next_step "Install/start Docker and ensure the current user can access the Docker daemon"
fi

if [ "$HAS_PYTHON" = true ]; then
    emit_pass "host.python3" "Python 3 is available"
else
    mark_failure "NOT VERIFIED" "python3" "Python 3 is unavailable"
    add_next_step "Install python3 on this host so structured verification checks can run"
fi

if [ "$HAS_CURL" = true ]; then
    emit_pass "host.curl" "curl is available"
else
    mark_failure "NOT VERIFIED" "host.curl" "curl is unavailable (required for /healthz and /jsz checks)"
    add_next_step "Install curl on this host"
fi

NATS_DATA_ROOT="${ZATCA_NATS_DATA_ROOT:-/opt/zatca-nats}"
if [ -d "$NATS_DATA_ROOT" ]; then
    if [ -w "$NATS_DATA_ROOT" ]; then
        emit_pass "host.path.nats_data" "JetStream data directory exists and is writable ($(safe_display_value "$NATS_DATA_ROOT"))"
    else
        emit_warn "host.path.nats_data" "JetStream data directory exists but is not writable by current user ($(safe_display_value "$NATS_DATA_ROOT"))"
    fi
else
    emit_info "host.path.nats_data" "JetStream data directory does not exist yet ($(safe_display_value "$NATS_DATA_ROOT"); setup-zatca-daemon.sh creates it on start)"
fi

if [ -n "${ZATCA_DAEMON_SOURCE_DIR:-}" ]; then
    if [ -d "$ZATCA_DAEMON_SOURCE_DIR" ]; then
        emit_pass "host.path.daemon_source" "ZATCA_DAEMON_SOURCE_DIR exists ($(safe_display_value "$ZATCA_DAEMON_SOURCE_DIR"))"
    else
        emit_warn "host.path.daemon_source" "ZATCA_DAEMON_SOURCE_DIR does not exist ($(safe_display_value "$ZATCA_DAEMON_SOURCE_DIR"); required for rebuild-zatca-daemon.sh)"
    fi
fi
if [ -n "${ZATCA_DAEMON_SDK_CONTEXT:-}" ]; then
    if [ -d "$ZATCA_DAEMON_SDK_CONTEXT" ]; then
        emit_pass "host.path.sdk_context" "ZATCA_DAEMON_SDK_CONTEXT exists ($(safe_display_value "$ZATCA_DAEMON_SDK_CONTEXT"))"
    else
        emit_warn "host.path.sdk_context" "ZATCA_DAEMON_SDK_CONTEXT does not exist ($(safe_display_value "$ZATCA_DAEMON_SDK_CONTEXT"); required for rebuild-zatca-daemon.sh)"
    fi
fi

RUNNING_CONTAINER_NAMES=""
if [ "$HAS_DOCKER" = true ]; then
    RUNNING_CONTAINER_NAMES="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
fi

LEGACY_NATS_CONTAINER="${NATS_CONTAINER_NAME:-nats}"
CONFIGURED_NATS_PORT="${ZATCA_NATS_PORT:-4222}"
if [ "$HAS_DOCKER" = true ] && [ -n "$RUNNING_CONTAINER_NAMES" ] &&
    printf '%s\n' "$RUNNING_CONTAINER_NAMES" | grep -qxF "$LEGACY_NATS_CONTAINER"; then
    legacy_port="$(docker port "$LEGACY_NATS_CONTAINER" 4222/tcp 2>/dev/null | awk -F: 'NR == 1 {print $NF; exit}' || true)"
    if [ -n "$legacy_port" ] && [ "$legacy_port" = "$CONFIGURED_NATS_PORT" ]; then
        mark_failure "FAIL" "host.nats_port_conflict" \
            "legacy standalone NATS container '${LEGACY_NATS_CONTAINER}' owns host port ${CONFIGURED_NATS_PORT}; it conflicts with embedded NATS in zatca-daemon"
        add_next_step "Stop and remove the legacy standalone NATS container before starting zatca-daemon: docker rm -f ${LEGACY_NATS_CONTAINER}"
    else
        emit_info "host.nats_port_conflict" "legacy NATS container '${LEGACY_NATS_CONTAINER}' is running on a different port (${legacy_port:-none})"
    fi
elif [ "$HAS_DOCKER" = true ]; then
    emit_pass "host.nats_port_conflict" "no running legacy standalone NATS container ('${LEGACY_NATS_CONTAINER}') conflicts with ZATCA_NATS_PORT"
fi

# =============================================================================
# Stage 3: Compose Resolution, Container Runtime, Image & Env Parity
# =============================================================================
emit_stage "Stage 3/6: Compose Resolution, Container Runtime, Image & Env Parity"

COMPOSE_FILE="${ZATCA_DAEMON_COMPOSE_FILE:-${REPO_DIR}/dashboard/docker-compose.zatca.yml}"
CONTAINER="${ZATCA_DAEMON_CONTAINER:-zatca-daemon}"
compose_json=""
running_env_json=""
COMPOSE_MONITOR_BIND_BAD=false
RUNNING_MONITOR_BIND_BAD=false
COMPOSE_MONITOR_BIND_DISPLAY="unavailable"
RUNNING_MONITOR_BIND_DISPLAY="unavailable"
CONTAINER_IPS_DISPLAY="unavailable"
CONTAINER_RUNNING=false
CONTAINER_EXISTS=false
CONFIGURED_IMAGE_ID=""
RUNNING_IMAGE_ID=""

if [ "$DAEMON_ENABLED" != true ]; then
    emit_info "compose.resolved" "skipped daemon Compose, container, image, and parity checks because ZATCA_DAEMON_ENABLED is disabled"
else
    if [ ! -f "$COMPOSE_FILE" ]; then
        mark_failure "NOT VERIFIED" "compose.resolved" "daemon Compose file is unavailable ($(safe_display_value "$COMPOSE_FILE"))"
        add_next_step "Ensure dashboard/docker-compose.zatca.yml exists or fix ZATCA_DAEMON_COMPOSE_FILE in ${CONFIG_FILE}"
    elif [ "$HAS_DOCKER" = true ]; then
        COMPOSE_ERR_FILE="$(mktemp 2>/dev/null || true)"
        [ -z "$COMPOSE_ERR_FILE" ] || chmod 600 "$COMPOSE_ERR_FILE" 2>/dev/null || true
        if compose_json="$(
            docker compose --env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" \
                --profile zatca config --format json 2>"${COMPOSE_ERR_FILE:-/dev/null}"
        )"; then
            emit_pass "compose.resolved" "daemon Compose environment resolved"
        else
            redacted_compose_err=""
            if [ -n "$COMPOSE_ERR_FILE" ] && [ -s "$COMPOSE_ERR_FILE" ]; then
                redacted_compose_err="$(head -n 3 "$COMPOSE_ERR_FILE" | redact_stdin | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
            fi
            if [ -n "$redacted_compose_err" ]; then
                mark_failure "NOT VERIFIED" "compose.resolved" "daemon Compose environment could not be resolved (${redacted_compose_err})"
            else
                mark_failure "NOT VERIFIED" "compose.resolved" "daemon Compose environment could not be resolved"
            fi
            compose_json=""
            add_next_step "Resolve Compose errors with: docker compose --env-file ${CONFIG_FILE} -f ${COMPOSE_FILE} --profile zatca config"
        fi
    else
        mark_failure "NOT VERIFIED" "compose.resolved" "Docker is unavailable for Compose resolution"
    fi

    # Compare Bash-sourced config values vs Compose-resolved values & check Compose NATS_MONITOR_HOST
    if [ -n "$compose_json" ] && [ "$HAS_PYTHON" = true ]; then
        py_compose_audit=""
        IFS= read -r -d '' py_compose_audit <<'PY' || true
import ipaddress
import json
import os
import re
import sys

cfg_path, verbose_str, secrets_path = sys.argv[1:4]
verbose = verbose_str == "true"

secrets = []
if secrets_path and os.path.isfile(secrets_path):
    try:
        with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
            secrets = [line.rstrip("\n") for line in fh if len(line.rstrip("\n")) >= 4]
    except OSError:
        secrets = []
secrets.sort(key=len, reverse=True)

secret_env_keys = {
    "DB_PASS", "ADMIN_DB_PASS", "ENCRYPT_KEY", "NATS_PASSWORD", "MONITOR_PASS", "SMTP_PASS",
}
secret_key_re = re.compile(r"(?:PASS|PASSWORD|SECRET|TOKEN|ENCRYPT_KEY)", re.IGNORECASE)

def is_secret(k):
    return k in secret_env_keys or bool(secret_key_re.search(k))

def safe_val(v, allow_at=False):
    if v == "":
        return "(empty)"
    if any(ord(c) < 32 or ord(c) == 127 for c in v):
        return "[REDACTED]"
    if not allow_at and "@" in v:
        return "[REDACTED]"
    for s in secrets:
        if s in v:
            return "[REDACTED]"
    return v[:157] + "..." if len(v) > 160 else v

try:
    doc = json.load(sys.stdin)
    env_map = doc["services"]["zatca-daemon"]["environment"]
    if not isinstance(env_map, dict):
        raise ValueError("not dict")
except Exception:
    print("INVALID")
    raise SystemExit(0)

# Read raw lines of config.env to see if a mismatched source key has interpolation/quoting hazards
raw_lines = {}
try:
    with open(cfg_path, "r", encoding="utf-8", errors="replace") as fh:
        for raw_line in fh:
            s = raw_line.rstrip("\r\n").lstrip()
            if not s or s.startswith("#"):
                continue
            if s.startswith("export "):
                s = s[7:].lstrip()
            if "=" in s:
                k, rv = s.split("=", 1)
                raw_lines[k.strip()] = rv
except OSError:
    pass

# Expected mapping from config.env -> compose daemon environment
mapping = [
    ("DB_USER", "ZATCA_DB_USER", ""),
    ("DB_PASS", "ZATCA_DB_PASSWORD", ""),
    ("DB_HOST", "MYSQL_HOST", "host.docker.internal"),
    ("DB_PORT", "MYSQL_PORT", "3306"),
    ("MASTER_DB", "MYSQL_MASTER_DB", "zatca_master"),
    ("ADMIN_DB_USER", "ZATCA_ADMIN_DB_USER", ""),
    ("ADMIN_DB_PASS", "ZATCA_ADMIN_DB_PASSWORD", ""),
    ("ADMIN_DB_HOST", "ZATCA_ADMIN_DB_HOST", ""),
    ("ENCRYPT_KEY", "ZATCA_ENCRYPT_KEY", ""),
    ("NATS_USER", "NATS_USER", ""),
    ("NATS_PASSWORD", "NATS_PASSWORD", ""),
    ("NATS_PRIVATE_NETWORK_ONLY", "NATS_PRIVATE_NETWORK_ONLY", ""),
    ("NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED", "NATS_PRIVATE_NETWORK_FIREWALL_CONFIRMED", "false"),
    ("NATS_SHARED_CREDENTIALS_ACKNOWLEDGED", "NATS_SHARED_CREDENTIALS_ACKNOWLEDGED", "false"),
    ("NATS_SHARED_CREDENTIALS_APPROVAL_ID", "NATS_SHARED_CREDENTIALS_APPROVAL_ID", ""),
    ("NATS_SHARED_CREDENTIALS_EXPIRES", "NATS_SHARED_CREDENTIALS_EXPIRES", ""),
    ("MONITOR_PASS", "ZATCA_MONITOR_PASSWORD", ""),
    ("NATS_MONITOR_PRIVATE_NETWORK_ONLY", "NATS_PRIVATE_NETWORK_ONLY", ""),
    ("SMTP_HOST", "ZATCA_SMTP_HOST", "host.docker.internal"),
    ("SMTP_PORT", "ZATCA_SMTP_PORT", "25"),
    ("SMTP_USER", "ZATCA_SMTP_USER", ""),
    ("SMTP_PASS", "ZATCA_SMTP_PASSWORD", ""),
    ("SMTP_FROM", "ZATCA_SMTP_FROM", "zatca-daemon@localhost"),
]

interp_hazards = []
nonhazard_diffs = []
for compose_k, cfg_k, default_v in mapping:
    if compose_k not in env_map:
        continue
    c_val = env_map[compose_k]
    if c_val is None:
        c_val = ""
    elif not isinstance(c_val, str):
        c_val = str(c_val)
    b_val = os.environ.get(cfg_k, "")
    if b_val == "":
        b_val = default_v
    if c_val != b_val:
        raw_v = raw_lines.get(cfg_k, "")
        has_syntax_hazard = (
            "$" in raw_v
            or "'" in raw_v
            or '"' in raw_v
            or "\\" in raw_v
            or "#" in raw_v
            or (raw_v != raw_v.rstrip(" \t"))
        )
        if has_syntax_hazard:
            interp_hazards.append(f"{compose_k}({cfg_k})")
        else:
            nonhazard_diffs.append(compose_k)

if interp_hazards:
    print("INTERP_FAIL\t" + ", ".join(interp_hazards))
elif nonhazard_diffs:
    print("INTERP_WARN\t" + ", ".join(nonhazard_diffs))
else:
    print("INTERP_PASS\t" + str(len(mapping)))

# Check Compose NATS_MONITOR_HOST
mon_host = env_map.get("NATS_MONITOR_HOST")
if not isinstance(mon_host, str) or not mon_host.strip():
    print("MONITOR_BAD\tunset\tNATS_MONITOR_HOST is unset in Compose (daemon defaults to 127.0.0.1 inside container, causing host curl error 56)")
else:
    mh = mon_host.strip()
    is_loopback = mh.casefold() == "localhost"
    if not is_loopback:
        addr = mh[1:-1] if mh.startswith("[") and mh.endswith("]") else mh
        try:
            is_loopback = ipaddress.ip_address(addr).is_loopback
        except ValueError:
            is_loopback = False
    if is_loopback:
        print(f"MONITOR_BAD\t{safe_val(mh)}\tNATS_MONITOR_HOST={safe_val(mh)} binds monitor to container loopback only, breaking host port mapping (causes curl error 56)")
    else:
        print(f"MONITOR_OK\t{safe_val(mh)}\tCompose sets NATS_MONITOR_HOST={safe_val(mh)} inside container (host port remains 127.0.0.1-only)")

if verbose:
    for k in sorted(env_map.keys()):
        v = "" if env_map[k] is None else str(env_map[k])
        if is_secret(k):
            disp = "[REDACTED]" if v else "(empty)"
        else:
            disp = safe_val(v, allow_at=(k == "SMTP_FROM"))
        print(f"ENV_ROW\t{k}\t{disp}")
PY
        compose_audit="$(
            printf '%s' "$compose_json" | python3 -c "$py_compose_audit" "$SELECTED_CONFIG_FILE" "$VERBOSE" "$SECRETS_FILE" 2>/dev/null || true
        )"

        while IFS=$'\t' read -r tag col1 col2; do
            case "$tag" in
                INTERP_PASS)
                    emit_pass "config.interpolation" "Bash-sourced config and Compose-resolved daemon environment match (${col1} mapped keys checked)"
                    ;;
                INTERP_WARN)
                    emit_warn "compose.override" "Compose resolved different value(s) than sourced config.env for: ${col1}"
                    ;;
                INTERP_FAIL)
                    mark_failure "FAIL" "config.interpolation" \
                        "Bash and Docker Compose resolved different values for ${col1} (likely unescaped '\$', quotes, or '#' in ${CONFIG_FILE}; values withheld)"
                    add_next_step "Inspect quoting/'\$' escaping in ${CONFIG_FILE} for ${col1} so Bash and Docker Compose resolve identical values, then recreate zatca-daemon"
                    ;;
                MONITOR_OK)
                    COMPOSE_MONITOR_BIND_DISPLAY="$col1"
                    emit_pass "compose.monitor_bind" "$col2"
                    ;;
                MONITOR_BAD)
                    COMPOSE_MONITOR_BIND_BAD=true
                    COMPOSE_MONITOR_BIND_DISPLAY="$col1"
                    mark_failure "FAIL" "compose.monitor_bind" "$col2"
                    add_next_step "Ensure dashboard/docker-compose.zatca.yml sets NATS_MONITOR_HOST: \"0.0.0.0\" under &zatca-daemon-environment (host mapping stays 127.0.0.1-only), then recreate zatca-daemon"
                    ;;
                ENV_ROW)
                    emit_info "compose.env" "${col1}=${col2}"
                    ;;
            esac
        done <<< "$compose_audit"
    fi

    # Inspect running container state & optional details
    if [ "$HAS_DOCKER" = true ]; then
        if container_state="$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)"; then
            CONTAINER_EXISTS=true
            if [ "$container_state" = true ]; then
                CONTAINER_RUNNING=true
                emit_pass "daemon.container" "configured daemon container '${CONTAINER}' is running"
            else
                mark_failure "FAIL" "daemon.container" "configured daemon container '${CONTAINER}' exists but is not running (running=${container_state})"
                add_next_step "Start or recreate the ZATCA daemon: bash scripts/setup-zatca-daemon.sh --config ${CONFIG_FILE} --recreate"
            fi

            # Best-effort container metadata (health, restarts, networks/IPs, extra_hosts)
            if [ "$HAS_PYTHON" = true ]; then
                state_json="$(docker inspect --format '{{json .State}}' "$CONTAINER" 2>/dev/null || true)"
                nets_json="$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$CONTAINER" 2>/dev/null || true)"
                extra_hosts_json="$(docker inspect --format '{{json .HostConfig.ExtraHosts}}' "$CONTAINER" 2>/dev/null || true)"
                restarts_raw="$(docker inspect --format '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || true)"
                container_meta="$(
                    python3 - "$state_json" "$nets_json" "$extra_hosts_json" "$restarts_raw" <<'PY' 2>/dev/null || true
import json
import sys

state_s, nets_s, extra_s, restarts_s = sys.argv[1:5]
parts = []
ips = []
warn_restarts = None

try:
    st = json.loads(state_s)
    if isinstance(st, dict):
        if st.get("Status"):
            parts.append("status=" + str(st["Status"]))
        health = st.get("Health")
        if isinstance(health, dict) and health.get("Status"):
            parts.append("health=" + str(health["Status"]))
        if st.get("OOMKilled") is True:
            parts.append("oom_killed=true")
            warn_restarts = "container was OOMKilled"
except Exception:
    pass

if restarts_s.isdigit():
    r = int(restarts_s)
    parts.append(f"restarts={r}")
    if r > 0 and not warn_restarts:
        warn_restarts = f"container has restarted {r} time(s)"

try:
    nets = json.loads(nets_s)
    if isinstance(nets, dict) and nets:
        net_desc = []
        for n_name, n_info in sorted(nets.items()):
            ip = (n_info or {}).get("IPAddress") or ""
            if ip:
                ips.append(ip)
                net_desc.append(f"{n_name}={ip}")
            else:
                net_desc.append(n_name)
        parts.append("networks=" + ",".join(net_desc))
except Exception:
    pass

try:
    eh = json.loads(extra_s)
    if isinstance(eh, list) and eh:
        parts.append("extra_hosts=" + ",".join(str(x) for x in eh))
except Exception:
    pass

if parts:
    print("DETAILS\t" + " ".join(parts))
if ips:
    print("IPS\t" + ",".join(ips))
if warn_restarts:
    print("WARN\t" + warn_restarts)
PY
                )"
                while IFS=$'\t' read -r mtag mval; do
                    case "$mtag" in
                        DETAILS) emit_info "daemon.container.details" "$mval" ;;
                        IPS) CONTAINER_IPS_DISPLAY="$mval" ;;
                        WARN) emit_warn "daemon.container.restarts" "$mval; inspect container logs" ;;
                    esac
                done <<< "$container_meta"
            fi
        else
            mark_failure "NOT VERIFIED" "daemon.container" "configured daemon container '${CONTAINER}' could not be inspected (not created or Docker error)"
            add_next_step "Start the ZATCA daemon: bash scripts/setup-zatca-daemon.sh --config ${CONFIG_FILE}"
        fi

        # Inspect running container environment & check running NATS_MONITOR_HOST + env.parity
        if running_env_json="$(
            docker inspect --format '{{json .Config.Env}}' "$CONTAINER" 2>/dev/null
        )"; then
            append_running_env_secrets "$running_env_json"

            # Check running container NATS_MONITOR_HOST directly
            if [ "$HAS_PYTHON" = true ]; then
                py_running_mon=""
                IFS= read -r -d '' py_running_mon <<'PY' || true
import ipaddress
import json
import sys

try:
    items = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(items, list):
    raise SystemExit(0)
env = {}
for item in items:
    if isinstance(item, str) and "=" in item:
        k, v = item.split("=", 1)
        env[k] = v

mh = env.get("NATS_MONITOR_HOST", "").strip()
if not mh:
    print("BAD\tunset\trunning container has NATS_MONITOR_HOST unset (defaults to 127.0.0.1 inside container; host /healthz and /jsz fail with curl error 56)")
else:
    is_loopback = mh.casefold() == "localhost"
    if not is_loopback:
        addr = mh[1:-1] if mh.startswith("[") and mh.endswith("]") else mh
        try:
            is_loopback = ipaddress.ip_address(addr).is_loopback
        except ValueError:
            is_loopback = False
    if is_loopback:
        print(f"BAD\t{mh}\trunning container sets NATS_MONITOR_HOST={mh} (loopback-only inside container; host /healthz and /jsz fail with curl error 56)")
    else:
        print(f"OK\t{mh}\trunning container binds monitor on NATS_MONITOR_HOST={mh}")
PY
                running_mon_check="$(
                    printf '%s' "$running_env_json" | python3 -c "$py_running_mon" 2>/dev/null || true
                )"
                if [ -n "$running_mon_check" ]; then
                    IFS=$'\t' read -r mon_status mon_val mon_msg <<< "$running_mon_check"
                    RUNNING_MONITOR_BIND_DISPLAY="$(safe_display_value "$mon_val")"
                    if [ "$mon_status" = "OK" ]; then
                        emit_pass "daemon.monitor_bind" "$mon_msg"
                    else
                        RUNNING_MONITOR_BIND_BAD=true
                        mark_failure "FAIL" "daemon.monitor_bind" "$mon_msg"
                        add_next_step "Recreate the running ZATCA daemon container so it picks up NATS_MONITOR_HOST=0.0.0.0: bash scripts/setup-zatca-daemon.sh --config ${CONFIG_FILE} --recreate"
                    fi
                fi
            fi

            if [ -n "$compose_json" ] && [ "$HAS_PYTHON" = true ]; then
                py_parity=""
                IFS= read -r -d '' py_parity <<'PY' || true
import json
import os
import re
import sys

secrets_path = sys.argv[1]
secrets = []
if secrets_path and os.path.isfile(secrets_path):
    try:
        with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
            secrets = [line.rstrip("\n") for line in fh if len(line.rstrip("\n")) >= 4]
    except OSError:
        secrets = []
secrets.sort(key=len, reverse=True)

secret_keys = {
    "DB_PASS", "ADMIN_DB_PASS", "ENCRYPT_KEY", "NATS_PASSWORD", "MONITOR_PASS", "SMTP_PASS",
}
secret_key_re = re.compile(r"(?:PASS|PASSWORD|PASSWD|SECRET|TOKEN|ENCRYPT_KEY|PRIVATE_KEY|API_KEY)", re.IGNORECASE)

def is_secret(k):
    return k in secret_keys or bool(secret_key_re.search(k))

def safe_nonsecret(v, allow_at=False):
    if v is None or v == "":
        return "(empty)"
    if any(ord(c) < 32 or ord(c) == 127 for c in v):
        return "[REDACTED]"
    if not allow_at and "@" in v:
        return "[REDACTED]"
    for s in secrets:
        if s in v:
            return "[REDACTED]"
    return v[:157] + "..." if len(v) > 160 else v

def invalid():
    print("INVALID")
    raise SystemExit(0)

parts = sys.stdin.buffer.read().split(b"\0")
if len(parts) != 2:
    invalid()
try:
    compose = json.loads(parts[0])
    running = json.loads(parts[1])
except (TypeError, ValueError):
    invalid()

try:
    mapped = compose["services"]["zatca-daemon"]["environment"]
except (KeyError, TypeError):
    invalid()
if not isinstance(mapped, dict) or not mapped:
    invalid()

key_pattern = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
expected = {}
for key, value in mapped.items():
    if not isinstance(key, str) or not key_pattern.fullmatch(key):
        invalid()
    if not isinstance(value, str):
        invalid()
    expected[key] = value

if not isinstance(running, list):
    invalid()
actual = {}
for item in running:
    if not isinstance(item, str):
        invalid()
    key, separator, value = item.partition("=")
    if not separator or not key_pattern.fullmatch(key) or key in actual:
        invalid()
    actual[key] = value

mismatched = sorted(key for key, value in expected.items() if actual.get(key) != value)
if not mismatched:
    print(f"MATCH\t{len(expected)}")
else:
    print("MISMATCH\t" + "\t".join(mismatched))
    for k in mismatched:
        if is_secret(k):
            print(f"DIFF_SECRET\t{k}")
        else:
            exp_s = safe_nonsecret(expected.get(k, ""), allow_at=(k == "SMTP_FROM"))
            act_s = safe_nonsecret(actual.get(k), allow_at=(k == "SMTP_FROM")) if k in actual else "(unset)"
            print(f"DIFF_PLAIN\t{k}\t{exp_s}\t{act_s}")
PY
                if parity_result="$(
                    printf '%s\0%s' "$compose_json" "$running_env_json" |
                        python3 -c "$py_parity" "$SECRETS_FILE"
                )"; then
                    first_line="$(printf '%s\n' "$parity_result" | head -n 1)"
                    case "$first_line" in
                        MATCH$'\t'*)
                            key_count="${first_line#MATCH$'\t'}"
                            emit_pass "env.parity" "every mapped daemon setting matches the running container (${key_count} keys checked)"
                            ;;
                        MISMATCH$'\t'*)
                            mismatch_keys="${first_line#MISMATCH$'\t'}"
                            mismatch_keys="${mismatch_keys//$'\t'/, }"
                            mark_failure "FAIL" "env.parity" "mismatched keys: ${mismatch_keys}"
                            while IFS=$'\t' read -r dtag dk de da; do
                                case "$dtag" in
                                    DIFF_PLAIN)
                                        emit_info "env.parity.diff" "${dk}: expected=${de} actual=${da}"
                                        ;;
                                    DIFF_SECRET)
                                        emit_info "env.parity.diff" "${dk}: secret value differs between selected config and running container (values withheld)"
                                        ;;
                                esac
                            done <<< "$parity_result"
                            add_next_step "Recreate the daemon container so its environment matches ${CONFIG_FILE}: bash scripts/setup-zatca-daemon.sh --config ${CONFIG_FILE} --recreate"
                            ;;
                        *)
                            mark_failure "NOT VERIFIED" "env.parity" "Compose or container environment evidence is malformed"
                            ;;
                    esac
                else
                    mark_failure "NOT VERIFIED" "env.parity" "environment parity comparison could not be completed"
                fi
            else
                mark_failure "NOT VERIFIED" "env.parity" "Compose environment is unavailable for comparison"
            fi
        else
            mark_failure "NOT VERIFIED" "env.parity" "running daemon environment could not be inspected"
        fi
    fi

    # Image identity & OCI revision provenance
    is_valid_image_id() {
        [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]
    }

    read_safe_image_revision() {
        local image="$1" revision
        if revision="$(
            docker image inspect \
                --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
                "$image" 2>/dev/null
        )" && [[ "$revision" =~ ^[[:xdigit:]]{7,40}$ ]]; then
            printf '%s' "${revision,,}"
        else
            printf 'unavailable'
        fi
    }

    CONFIGURED_IMAGE_ID_DISPLAY="unavailable"
    RUNNING_IMAGE_ID_DISPLAY="unavailable"
    CONFIGURED_IMAGE_REVISION="unavailable"
    RUNNING_IMAGE_REVISION="unavailable"

    if [ "$HAS_DOCKER" = true ] && [ -n "${ZATCA_DAEMON_IMAGE:-}" ]; then
        if CONFIGURED_IMAGE_ID="$(
            docker image inspect --format '{{.Id}}' "$ZATCA_DAEMON_IMAGE" 2>/dev/null
        )"; then
            if is_valid_image_id "$CONFIGURED_IMAGE_ID"; then
                CONFIGURED_IMAGE_ID_DISPLAY="$CONFIGURED_IMAGE_ID"
                CONFIGURED_IMAGE_REVISION="$(read_safe_image_revision "$CONFIGURED_IMAGE_ID")"
            else
                CONFIGURED_IMAGE_ID=""
                mark_failure "NOT VERIFIED" "daemon.image" "configured daemon image returned an invalid image ID"
            fi
        else
            mark_failure "NOT VERIFIED" "daemon.image" "configured daemon image '$(safe_display_value "$ZATCA_DAEMON_IMAGE")' is unavailable locally"
            add_next_step "Build or pull the configured daemon image ($(safe_display_value "$ZATCA_DAEMON_IMAGE")), e.g. bash scripts/rebuild-zatca-daemon.sh --config ${CONFIG_FILE}"
        fi
    elif [ -z "${ZATCA_DAEMON_IMAGE:-}" ]; then
        mark_failure "NOT VERIFIED" "daemon.image" "ZATCA_DAEMON_IMAGE is not set in ${CONFIG_FILE}"
    fi

    if [ "$HAS_DOCKER" = true ]; then
        if RUNNING_IMAGE_ID="$(
            docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null
        )"; then
            if is_valid_image_id "$RUNNING_IMAGE_ID"; then
                RUNNING_IMAGE_ID_DISPLAY="$RUNNING_IMAGE_ID"
                RUNNING_IMAGE_REVISION="$(read_safe_image_revision "$RUNNING_IMAGE_ID")"
            else
                RUNNING_IMAGE_ID=""
                mark_failure "NOT VERIFIED" "daemon.image" "running daemon returned an invalid image ID"
            fi
        else
            mark_failure "NOT VERIFIED" "daemon.image" "running daemon image could not be inspected"
        fi
    fi

    emit_info "daemon.image.provenance" \
        "configured_id=${CONFIGURED_IMAGE_ID_DISPLAY} configured_revision=${CONFIGURED_IMAGE_REVISION} running_id=${RUNNING_IMAGE_ID_DISPLAY} running_revision=${RUNNING_IMAGE_REVISION}"

    if [ -n "$CONFIGURED_IMAGE_ID" ] && [ -n "$RUNNING_IMAGE_ID" ]; then
        if [ "$CONFIGURED_IMAGE_ID" = "$RUNNING_IMAGE_ID" ]; then
            emit_pass "daemon.image" "configured image matches the running daemon image"
        else
            mark_failure "FAIL" "daemon.image" "configured image does not match the running daemon image"
            emit_hint "daemon.image" "configured and running image IDs differ; matching source revision labels do not prove identical image artifacts. Run scripts/rebuild-zatca-daemon.sh, then rerun scripts/verify-zatca-environment.sh"
            add_next_step "Align the running daemon image with the configured image: bash scripts/rebuild-zatca-daemon.sh --config ${CONFIG_FILE} (or bash scripts/setup-zatca-daemon.sh --config ${CONFIG_FILE} --recreate if the image is already built)"
        fi
    fi
fi

# =============================================================================
# Stage 4: Database Target & Live MySQL Verification (--verify-db --json)
# =============================================================================
emit_stage "Stage 4/6: Database Target & Live MySQL Verification"

database_target_output=$'unavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable'
if [ -n "$compose_json" ] && [ "$HAS_PYTHON" = true ]; then
    py_db_target=""
    IFS= read -r -d '' py_db_target <<'PY' || true
import ipaddress
import json
import os
import re
import sys

secrets_path = sys.argv[1]
secrets = []
if secrets_path and os.path.isfile(secrets_path):
    try:
        with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
            secrets = [line.rstrip("\n") for line in fh if len(line.rstrip("\n")) >= 4]
    except OSError:
        secrets = []
secrets.sort(key=len, reverse=True)

def safe_ident(v):
    if not isinstance(v, str) or not v.strip():
        return "unavailable"
    s = v.strip()
    if any(ord(c) < 32 or ord(c) == 127 for c in s) or "@" in s:
        return "[REDACTED]"
    for sec in secrets:
        if sec in s:
            return "[REDACTED]"
    return s[:128]

def unavailable():
    print("unavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable")

try:
    document = json.load(sys.stdin)
except json.JSONDecodeError:
    unavailable()
    raise SystemExit(0)

services = document.get("services") if isinstance(document, dict) else None
service = services.get("zatca-daemon") if isinstance(services, dict) else None
environment = service.get("environment") if isinstance(service, dict) else None
if not isinstance(environment, dict):
    unavailable()
    raise SystemExit(0)

host = environment.get("DB_HOST")
if not isinstance(host, str) or not host.strip():
    target_class = "unavailable"
    safe_host = "unavailable"
else:
    host = host.strip()
    safe_host = safe_ident(host)
    if host.casefold() == "host.docker.internal":
        target_class = "host_gateway"
    elif host.casefold() == "localhost":
        target_class = "container_loopback"
    else:
        address = host[1:-1] if host.startswith("[") and host.endswith("]") else host
        try:
            is_loopback = ipaddress.ip_address(address).is_loopback
        except ValueError:
            is_loopback = False
        target_class = "container_loopback" if is_loopback else "custom_host_redacted"

port = environment.get("DB_PORT")
if type(port) is int:
    numeric_port = port
elif isinstance(port, str) and re.fullmatch(r"[0-9]{1,5}", port):
    numeric_port = int(port)
else:
    numeric_port = None
safe_port = str(numeric_port) if numeric_port is not None and 1 <= numeric_port <= 65535 else "unavailable"
safe_user = safe_ident(environment.get("DB_USER"))
safe_master = safe_ident(environment.get("MASTER_DB"))
admin_u = environment.get("ADMIN_DB_USER")
safe_admin = safe_ident(admin_u) if isinstance(admin_u, str) and admin_u.strip() else "none"
print("%s\t%s\t%s\t%s\t%s\t%s" % (target_class, safe_port, safe_host, safe_user, safe_master, safe_admin))
PY
    if parsed_database_target="$(
        printf '%s' "$compose_json" | python3 -c "$py_db_target" "$SECRETS_FILE"
    )" 2>/dev/null; then
        [ -z "$parsed_database_target" ] || database_target_output="$parsed_database_target"
    fi
fi

IFS=$'\t' read -r database_target_class database_target_port database_target_host database_target_user database_target_master database_target_admin <<< "$database_target_output"
case "$database_target_class" in
    host_gateway|container_loopback|custom_host_redacted|unavailable) ;;
    *) database_target_class="unavailable"; database_target_port="unavailable" ;;
esac
if [ "$database_target_port" != "unavailable" ] && ! is_valid_port "$database_target_port"; then
    database_target_port="unavailable"
fi
if [ "$database_target_class" = "unavailable" ]; then
    database_target_port="unavailable"
fi

emit_info "database.target" "class=${database_target_class} port=${database_target_port}"
emit_info "database.target.details" \
    "user=${database_target_user} host=${database_target_host} port=${database_target_port} master_db=${database_target_master} admin_user=${database_target_admin} container_ips=${CONTAINER_IPS_DISPLAY}"

if [ "$database_target_class" = "container_loopback" ]; then
    emit_warn "database.target.loopback" \
        "DB_HOST resolves to container loopback inside zatca-daemon; unless MySQL shares the container network namespace, set MYSQL_HOST=host.docker.internal"
    add_next_step "Set MYSQL_HOST=host.docker.internal in ${CONFIG_FILE} (containers cannot reach host MySQL via 127.0.0.1/localhost), then recreate zatca-daemon"
fi

database_report=""
database_exit_status=125
database_probe_started=false
if [ "$DAEMON_ENABLED" != true ]; then
    emit_info "database.report" "skipped one-shot --verify-db probe because ZATCA_DAEMON_ENABLED is disabled"
elif [ "$CONFIG_BLOCKED" = true ]; then
    mark_failure "NOT VERIFIED" "database.report" "skipped one-shot verifier because Stage 1 configuration validation failed"
elif [ -n "$CONFIGURED_IMAGE_ID" ] && [ -n "$compose_json" ] && [ "$HAS_DOCKER" = true ]; then
    if DATABASE_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
        chmod 600 "$DATABASE_DIAGNOSTIC_FILE" 2>/dev/null || true
        database_probe_started=true
        if database_report="$(
            docker compose --env-file "$CONFIG_FILE" -f "$COMPOSE_FILE" \
                --profile zatca-check run --rm --no-deps zatca-check \
                2>"$DATABASE_DIAGNOSTIC_FILE"
        )"; then
            database_exit_status=0
        else
            database_exit_status=$?
        fi
    else
        mark_failure "NOT VERIFIED" "database.report" \
            "private diagnostic capture could not be created; verifier was not started"
    fi
else
    mark_failure "NOT VERIFIED" "database.report" "one-shot verifier image or Compose evidence is unavailable"
fi

if [ "$database_probe_started" = true ]; then
    if [ -n "$database_report" ]; then
        if [ "$HAS_PYTHON" = true ] && database_validation="$(
            printf '%s' "$database_report" |
                DAEMON_EXIT_STATUS="$database_exit_status" python3 -c '
import json
import os
import re
import sys

def invalid():
    raise SystemExit(2)

raw = sys.stdin.read()
if "\n" in raw or "\r" in raw:
    invalid()
try:
    report = json.loads(raw)
except (TypeError, ValueError):
    invalid()
if not isinstance(report, dict) or set(report) != {"schema_version", "overall_status", "checks"}:
    invalid()
if type(report["schema_version"]) is not int or report["schema_version"] != 1:
    invalid()

statuses = {"PASS", "FAIL", "NOT_VERIFIED"}
categories = {
    "configuration", "connection", "timeout", "registry", "schema",
    "permission", "decryption", "not_ready", "internal",
}
target_fields = {"account_role", "tenant_id", "database", "branch_id", "operation"}
id_pattern = re.compile(r"^[A-Za-z0-9._:-]{1,256}$")
safe_value = re.compile(r"^[A-Za-z0-9._:$-]{1,128}$")
checks = report["checks"]
if not isinstance(checks, list) or not checks:
    invalid()

seen = set()
observed = []
lines = []
for check in checks:
    if not isinstance(check, dict):
        invalid()
    keys = set(check)
    if not {"id", "status", "target"}.issubset(keys) or keys - {
        "id", "status", "target", "error_category", "mysql_code",
    }:
        invalid()
    check_id = check["id"]
    status = check["status"]
    target = check["target"]
    if not isinstance(check_id, str) or not id_pattern.fullmatch(check_id) or check_id in seen:
        invalid()
    if not isinstance(status, str) or status not in statuses:
        invalid()
    if not isinstance(target, dict) or set(target) - target_fields:
        invalid()
    role = target.get("account_role")
    if role is not None and (
        not isinstance(role, str) or role not in {"runtime", "onboarding"}
    ):
        invalid()
    for field in ("tenant_id", "database", "operation"):
        value = target.get(field)
        if value is not None and (not isinstance(value, str) or not safe_value.fullmatch(value)):
            invalid()
    branch_id = target.get("branch_id")
    if branch_id is not None and (type(branch_id) is not int or branch_id <= 0):
        invalid()
    category = check.get("error_category")
    if category is not None and (
        not isinstance(category, str) or category not in categories
    ):
        invalid()
    mysql_code = check.get("mysql_code")
    if mysql_code is not None and (type(mysql_code) is not int or mysql_code < 0):
        invalid()
    if status == "PASS" and ("error_category" in check or "mysql_code" in check):
        invalid()

    seen.add(check_id)
    observed.append(status)
    context = []
    for field in ("account_role", "tenant_id", "database", "branch_id", "operation"):
        if field in target:
            context.append("%s=%s" % (field, target[field]))
    if category is not None:
        context.append("error_category=%s" % category)
    if mysql_code is not None:
        context.append("mysql_code=%s" % mysql_code)
    lines.append("CHECK\t%s\t%s\t%s" % (
        "NOT VERIFIED" if status == "NOT_VERIFIED" else status,
        check_id,
        ", ".join(context) if context else "target=unspecified",
    ))

if "FAIL" in observed:
    aggregate = "FAIL"
elif "NOT_VERIFIED" in observed:
    aggregate = "NOT_VERIFIED"
else:
    aggregate = "PASS"
if report["overall_status"] != aggregate:
    invalid()
process_status = int(os.environ["DAEMON_EXIT_STATUS"])
if (process_status == 0) != (aggregate == "PASS"):
    invalid()
print("REPORT\t" + aggregate)
for line in lines:
    print(line)
' 2>/dev/null
        )"; then
            database_report_status=""
            while IFS=$'\t' read -r record_type status check_id context; do
                case "$record_type" in
                    REPORT)
                        database_report_status="$status"
                        ;;
                    CHECK)
                        case "$status" in
                            PASS)
                                emit_pass "database.${check_id}" "$context"
                                ;;
                            FAIL)
                                mark_failure "FAIL" "database.${check_id}" "$context"
                                if [[ "$context" == *"mysql_code=1045"* ]]; then
                                    emit_hint "database.${check_id}" \
                                        "MySQL 1045 means the server denied this tested connection; it does not prove the password is wrong. A successful Dokku admin test does not verify the daemon connection account/host match; compare the daemon target (user=${database_target_user}, host=${database_target_host}, container_ips=${CONTAINER_IPS_DISPLAY}) and MySQL host grants from its Compose network before changing credentials, without exposing them."
                                    add_next_step "Inspect MySQL grants for user '${database_target_user}' from container network IP(s) (${CONTAINER_IPS_DISPLAY}) and verify ZATCA_DB_PASSWORD matches the grant before rotating credentials"
                                elif [[ "$context" == *"error_category=connection"* ]] || [[ "$context" == *"error_category=timeout"* ]]; then
                                    emit_hint "database.${check_id}" \
                                        "Verify MySQL is listening on ${database_target_host}:${database_target_port} (bind-address / firewall) and reachable from Docker containers via host-gateway"
                                    add_next_step "Verify MySQL TCP reachability from Docker containers to ${database_target_host}:${database_target_port} (check MySQL bind-address and host firewall)"
                                elif [[ "$context" == *"error_category=permission"* ]]; then
                                    emit_hint "database.${check_id}" \
                                        "MySQL user '${database_target_user}' lacks required privileges for this operation; verify SELECT/INSERT/UPDATE grants on ${database_target_master} and tenant databases"
                                    add_next_step "Grant required privileges to MySQL user '${database_target_user}' on ${database_target_master} and enabled tenant databases"
                                elif [[ "$context" == *"error_category=schema"* ]]; then
                                    emit_hint "database.${check_id}" \
                                        "Required tables or columns are missing; run master/tenant migrations first"
                                    add_next_step "Apply pending ZATCA master/tenant database migrations (e.g. bash scripts/deployctl.sh --config ${CONFIG_FILE} db migrate-master)"
                                elif [[ "$context" == *"error_category=decryption"* ]]; then
                                    emit_hint "database.${check_id}" \
                                        "Branch credentials/certificates could not be decrypted; confirm ZATCA_ENCRYPT_KEY matches the key that encrypted the branch records"
                                    add_next_step "Verify ZATCA_ENCRYPT_KEY in ${CONFIG_FILE} matches the key used to encrypt active branch ZATCA configs"
                                elif [[ "$context" == *"error_category=registry"* ]]; then
                                    emit_hint "database.${check_id}" \
                                        "Tenant registry lookup failed in ${database_target_master}; verify tenant rows and enabled status"
                                    add_next_step "Verify enabled tenant rows exist in ${database_target_master}.tenant"
                                fi
                                ;;
                            "NOT VERIFIED")
                                mark_failure "NOT VERIFIED" "database.${check_id}" "$context"
                                ;;
                        esac
                        ;;
                esac
            done <<< "$database_validation"
            if [ "$database_report_status" != PASS ]; then
                VERIFICATION_OK=false
            fi
        else
            mark_failure "NOT VERIFIED" "database.report" "daemon JSON report is malformed, unknown, or inconsistent"
            add_next_step "Verify the daemon image supports the schema v1 --verify-db --json report format"
        fi
    else
        if grep -Eiq 'unknown flag|flag provided but not defined' "$DATABASE_DIAGNOSTIC_FILE"; then
            database_failure_detail="daemon image rejected --verify-db/--json; database probe was not run"
            add_next_step "Rebuild and refresh the ZATCA daemon image to a revision that supports --verify-db --json: bash scripts/rebuild-zatca-daemon.sh --config ${CONFIG_FILE}"
        elif [ "$database_exit_status" -eq 125 ]; then
            database_failure_detail="Docker could not start the one-shot verifier (exit 125); no database result was produced"
            add_next_step "Inspect Docker Compose / image startup failure for zatca-check before re-running verification"
        elif [ "$database_exit_status" -eq 0 ]; then
            database_failure_detail="one-shot verifier exited successfully without a JSON report; database result is unavailable"
        else
            database_failure_detail="one-shot verifier exited with status ${database_exit_status} without JSON; database connection and permissions were not verified"
            if [ -s "$DATABASE_DIAGNOSTIC_FILE" ] && [ "$HAS_PYTHON" = true ]; then
                redacted_db_stderr="$(head -n 3 "$DATABASE_DIAGNOSTIC_FILE" | redact_stdin | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
                if [ -n "$redacted_db_stderr" ]; then
                    emit_hint "database.report.stderr" "redacted verifier stderr: ${redacted_db_stderr}"
                fi
            fi
        fi
        mark_failure "NOT VERIFIED" "database.report" "$database_failure_detail"
    fi
fi

# =============================================================================
# Stage 5: Live Daemon Health, Readiness (/healthz), JetStream (/jsz) & Logs
# =============================================================================
emit_stage "Stage 5/6: Live Daemon Health, Readiness & JetStream"

MONITOR_HOST="${ZATCA_NATS_MONITOR_HOST:-127.0.0.1}"
MONITOR_PORT="${ZATCA_NATS_MONITOR_PORT:-8222}"
monitor_target_class="custom_host_redacted"
case "${MONITOR_HOST,,}" in
    localhost|127.0.0.1|::1) monitor_target_class="loopback" ;;
esac

safe_monitor_port="unavailable"
if is_valid_port "$MONITOR_PORT"; then
    safe_monitor_port="$MONITOR_PORT"
fi
monitor_context="class=${monitor_target_class} port=${safe_monitor_port}"
emit_info "daemon.monitor.target" "${monitor_context} endpoints=/healthz,/jsz"
emit_info "daemon.monitor.details" \
    "host=$(safe_display_value "$MONITOR_HOST") port=${safe_monitor_port} compose_bind=${COMPOSE_MONITOR_BIND_DISPLAY} running_bind=${RUNNING_MONITOR_BIND_DISPLAY}"

health_output=""
health_exit_status=125
health_probe_started=false
if [ "$DAEMON_ENABLED" != true ]; then
    emit_info "daemon.health" "skipped live monitor probe because ZATCA_DAEMON_ENABLED is disabled"
elif [ -z "${ZATCA_MONITOR_PASSWORD:-}" ]; then
    mark_failure "NOT VERIFIED" "daemon.health" "skipped live monitor probe because ZATCA_MONITOR_PASSWORD is missing"
elif [ ! -f "$HEALTH_SCRIPT" ]; then
    mark_failure "NOT VERIFIED" "daemon.health" "daemon health checker is unavailable"
elif HEALTH_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
    chmod 600 "$HEALTH_DIAGNOSTIC_FILE" 2>/dev/null || true
    health_probe_started=true
    if health_output="$(bash "$HEALTH_SCRIPT" --config "$CONFIG_FILE" --json 2>"$HEALTH_DIAGNOSTIC_FILE")"; then
        health_exit_status=0
    else
        health_exit_status=$?
    fi
else
    mark_failure "NOT VERIFIED" "daemon.health" \
        "private diagnostic capture could not be created; health check was not started"
fi

HEALTH_FAILED=false
if [ "$health_probe_started" = true ]; then
    if [ -n "$health_output" ]; then
        if [ "$HAS_PYTHON" = true ] && health_result="$(
            printf '%s' "$health_output" |
                HEALTH_EXIT_STATUS="$health_exit_status" python3 -c '
import json
import os
import sys

try:
    health = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(2)
if not isinstance(health, dict):
    raise SystemExit(2)
status = health.get("status")
limits_ok = health.get("limits_ok")
if (
    not isinstance(status, str)
    or status not in {"healthy", "backlog_exceeded", "disabled"}
    or type(limits_ok) is not bool
):
    raise SystemExit(2)
stream = health.get("stream", "")
msgs = health.get("stream_messages", 0)
consumers = health.get("consumer_count", 0)
pending = health.get("pending", 0)
ack_pending = health.get("ack_pending", 0)
redelivered = health.get("redelivered", 0)
max_pending = health.get("max_pending", 0)
max_ack_pending = health.get("max_ack_pending", 0)
signal = health.get("reconciliation_signal", "none")
if status == "healthy":
    if stream != "ZATCA":
        raise SystemExit(2)
    for val in (msgs, consumers, pending, ack_pending, redelivered):
        if type(val) is not int or val < 0:
            raise SystemExit(2)
if not isinstance(signal, str) or signal not in {"none", "redeliveries_observed"}:
    signal = "none"
print("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" % (
    status,
    "true" if limits_ok else "false",
    os.environ["HEALTH_EXIT_STATUS"],
    msgs,
    consumers,
    pending,
    max_pending,
    ack_pending,
    max_ack_pending,
    redelivered,
    signal,
))
' 2>/dev/null
        )"; then
            IFS=$'\t' read -r health_status limits_ok health_exit_status \
                js_msgs js_consumers js_pending js_max_pending js_ack_pending js_max_ack_pending js_redelivered js_signal <<< "$health_result"
            case "$health_status:$limits_ok:$health_exit_status" in
                healthy:true:0)
                    emit_pass "daemon.health" "authenticated /healthz readiness and JetStream backlog are healthy"
                    emit_info "daemon.jetstream" \
                        "stream=ZATCA messages=${js_msgs} consumers=${js_consumers} pending=${js_pending}/${js_max_pending} ack_pending=${js_ack_pending}/${js_max_ack_pending} redelivered=${js_redelivered} reconciliation=${js_signal}"
                    if [ "$js_consumers" = "0" ]; then
                        emit_warn "daemon.jetstream.consumers" "ZATCA stream currently has 0 active consumers (normal only if no active ZATCA branches are enabled yet)"
                    fi
                    if [ "$js_redelivered" != "0" ]; then
                        emit_warn "daemon.jetstream.redeliveries" "${js_redelivered} redelivered message(s) observed in JetStream; inspect daemon logs for submission retries"
                    fi
                    ;;
                backlog_exceeded:false:*)
                    HEALTH_FAILED=true
                    mark_failure "FAIL" "daemon.health" \
                        "/jsz JetStream backlog exceeds configured thresholds (${monitor_context}; pending=${js_pending}/${js_max_pending} ack_pending=${js_ack_pending}/${js_max_ack_pending} redelivered=${js_redelivered})"
                    add_next_step "Inspect ZATCA daemon logs and worker throughput; JetStream backlog exceeded configured thresholds (pending=${js_pending}/${js_max_pending}, ack_pending=${js_ack_pending}/${js_max_ack_pending})"
                    ;;
                disabled:*)
                    HEALTH_FAILED=true
                    mark_failure "FAIL" "daemon.health" \
                        "health checker reports disabled; /healthz and /jsz were not verified (${monitor_context})"
                    ;;
                *)
                    HEALTH_FAILED=true
                    mark_failure "NOT VERIFIED" "daemon.health" "daemon health evidence is not healthy or exit status is inconsistent"
                    ;;
            esac
        else
            HEALTH_FAILED=true
            mark_failure "NOT VERIFIED" "daemon.health" \
                "health checker did not provide a valid /healthz and /jsz report (${monitor_context})"
        fi
    else
        HEALTH_FAILED=true
        health_http_status="$(
            grep -Eo 'returned error: [0-9]{3}' "$HEALTH_DIAGNOSTIC_FILE" |
                tail -n 1 | grep -Eo '[0-9]{3}$' || true
        )"
        health_curl_code="$(
            grep -Eo 'curl: \([0-9]+\)' "$HEALTH_DIAGNOSTIC_FILE" |
                tail -n 1 | tr -cd '0-9' || true
        )"
        case "$health_curl_code" in
            [0-9]|[0-9][0-9]|[0-9][0-9][0-9]) ;;
            *) health_curl_code="" ;;
        esac
        health_curl_category=""
        case "$health_curl_code" in
            6) health_curl_category="name resolution failure" ;;
            7) health_curl_category="connection failure" ;;
            28) health_curl_category="timeout" ;;
            56) health_curl_category="response receive failure" ;;
            "") ;;
            *) health_curl_category="transport failure" ;;
        esac
        if grep -Fq 'daemon readiness check failed' "$HEALTH_DIAGNOSTIC_FILE"; then
            if [ "$health_http_status" = 401 ] || [ "$health_http_status" = 403 ]; then
                health_failure_detail="/healthz rejected monitor authentication (HTTP ${health_http_status})"
                add_next_step "Verify ZATCA_MONITOR_PASSWORD in ${CONFIG_FILE} matches the running container's MONITOR_PASS (recreate daemon if changed)"
            elif [ -n "$health_http_status" ]; then
                health_failure_detail="/healthz returned HTTP ${health_http_status}; daemon readiness failed"
                add_next_step "Review daemon.readiness details and container logs below to resolve why /healthz returned HTTP ${health_http_status}"
            elif [ "$health_curl_code" = 56 ]; then
                health_failure_detail="/healthz response receive failure (curl error 56); no complete HTTP response was obtained"
            elif [ -n "$health_curl_code" ]; then
                health_failure_detail="/healthz request failed before an HTTP response (${health_curl_category}; curl error ${health_curl_code})"
                add_next_step "Check that ${CONTAINER} is running and publishing 127.0.0.1:${safe_monitor_port}:8222"
            else
                health_failure_detail="/healthz readiness request failed"
            fi
        elif grep -Fq 'daemon JetStream monitor check failed' "$HEALTH_DIAGNOSTIC_FILE"; then
            if [ "$health_http_status" = 401 ] || [ "$health_http_status" = 403 ]; then
                health_failure_detail="/jsz rejected monitor authentication (HTTP ${health_http_status})"
                add_next_step "Verify ZATCA_MONITOR_PASSWORD in ${CONFIG_FILE} matches the running container's MONITOR_PASS"
            elif [ -n "$health_http_status" ]; then
                health_failure_detail="/jsz returned HTTP ${health_http_status}"
            elif [ "$health_curl_code" = 56 ]; then
                health_failure_detail="/jsz response receive failure (curl error 56); no complete HTTP response was obtained"
            elif [ -n "$health_curl_code" ]; then
                health_failure_detail="/jsz request failed before an HTTP response (${health_curl_category}; curl error ${health_curl_code})"
            else
                health_failure_detail="/jsz monitor request failed"
            fi
        elif grep -Fq 'missing ZATCA stream' "$HEALTH_DIAGNOSTIC_FILE"; then
            health_failure_detail="JetStream monitor response does not contain the ZATCA stream"
            add_next_step "Inspect daemon startup logs to confirm embedded JetStream initialized the ZATCA stream"
        elif grep -Fq 'invalid JetStream health JSON' "$HEALTH_DIAGNOSTIC_FILE"; then
            health_failure_detail="/jsz returned invalid JSON"
        else
            health_failure_detail="health checker exited with status ${health_exit_status} without a valid health report"
        fi
        health_failure_detail="${health_failure_detail} (${monitor_context})"
        mark_failure "NOT VERIFIED" "daemon.health" "$health_failure_detail"

        if [ "$health_curl_code" = 56 ] && [ -z "$health_http_status" ]; then
            if [ "$COMPOSE_MONITOR_BIND_BAD" = true ] || [ "$RUNNING_MONITOR_BIND_BAD" = true ]; then
                emit_hint "daemon.health" \
                    "curl error 56 correlates directly with NATS_MONITOR_HOST being unset or loopback inside the container (Stage 3). Ensure dashboard/docker-compose.zatca.yml sets NATS_MONITOR_HOST: \"0.0.0.0\" and recreate ${CONTAINER} (host mapping remains 127.0.0.1-only)."
            else
                emit_hint "daemon.health" \
                    "curl error 56 indicates a response receive failure; no complete HTTP response was obtained. If it persists after database access and configured/running image alignment are verified, inspect the daemon container logs and state. This does not establish a connection reset or identify the cause."
            fi
        fi

        # Extract allow-listed, strictly redacted readiness fields when /healthz returned HTTP 503
        if [ "$health_http_status" = 503 ] && [ "$HAS_PYTHON" = true ] && [ -s "$HEALTH_DIAGNOSTIC_FILE" ]; then
            readiness_lines="$(
                python3 - "$HEALTH_DIAGNOSTIC_FILE" "$SECRETS_FILE" <<'PY' 2>/dev/null || true
import json
import os
import re
import sys

diag_path, secrets_path = sys.argv[1:3]
secrets = []
if secrets_path and os.path.isfile(secrets_path):
    try:
        with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
            secrets = [line.rstrip("\n") for line in fh if len(line.rstrip("\n")) >= 4]
    except OSError:
        secrets = []
secrets.sort(key=len, reverse=True)

def redact(s):
    if not isinstance(s, str):
        return ""
    for sec in secrets:
        if sec in s:
            s = s.replace(sec, "[REDACTED]")
    s = re.sub(r"[\x00-\x1f\x7f]", " ", s)
    s = re.sub(r"([a-zA-Z][a-zA-Z0-9+.-]*://)([^:@/\s]+):([^@/\s]+)@", r"\1[REDACTED]@", s)
    s = re.sub(r"([A-Za-z0-9._-]+):([^@\s]+)@tcp\(", r"\1:[REDACTED]@tcp(", s)
    s = re.sub(
        r'(?i)\b([A-Za-z0-9_.-]*(?:password|passwd|pass|pwd|secret|token|encrypt_key|monitor_pass|api_key|authorization))\s*([:=])\s*(?:"[^"]*"|\'[^\']*\'|[^\s,;}\]]+)',
        r"\1\2[REDACTED]",
        s,
    )
    return s.strip()[:240]

try:
    raw = open(diag_path, "r", encoding="utf-8", errors="replace").read()
except OSError:
    raise SystemExit(0)

# Locate the JSON object embedded in health-zatca-daemon.sh failure output
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end <= start:
    raise SystemExit(0)
try:
    payload = json.loads(raw[start:end + 1])
except Exception:
    raise SystemExit(0)
if not isinstance(payload, dict):
    raise SystemExit(0)

summary = []
for field in ("status", "ready", "active_workers"):
    val = payload.get(field)
    if isinstance(val, (str, bool, int)):
        summary.append(f"{field}={redact(str(val)) if isinstance(val, str) else str(val).lower() if isinstance(val, bool) else val}")
for err_field in ("global_error", "error"):
    val = payload.get(err_field)
    if isinstance(val, str) and val.strip():
        summary.append(f"{err_field}={redact(val)}")
if summary:
    print("SUMMARY\t" + " ".join(summary))

tenants = payload.get("tenants")
if isinstance(tenants, list):
    for t in tenants[:20]:
        if not isinstance(t, dict):
            continue
        t_parts = []
        for field in ("tenant", "database", "status", "ready", "branch_discovery", "expected_branches", "active_workers", "error"):
            val = t.get(field)
            if val is None or val == "":
                continue
            if isinstance(val, bool):
                t_parts.append(f"{field}={'true' if val else 'false'}")
            elif isinstance(val, int):
                t_parts.append(f"{field}={val}")
            elif isinstance(val, str):
                t_parts.append(f"{field}={redact(val)}")
        if t_parts:
            print("TENANT\t" + " ".join(t_parts))
PY
            )"
            while IFS=$'\t' read -r rtag rmsg; do
                case "$rtag" in
                    SUMMARY) emit_info "daemon.readiness" "$rmsg" ;;
                    TENANT) emit_info "daemon.readiness.tenant" "$rmsg" ;;
                esac
            done <<< "$readiness_lines"
        fi
    fi
fi

# Bounded, secret-redacted daemon container logs on health failure (or --verbose when unhealthy)
if [ "$HEALTH_FAILED" = true ] && [ "$CONTAINER_EXISTS" = true ] && [ "$HAS_DOCKER" = true ]; then
    log_tail=15
    [ "$VERBOSE" = true ] && log_tail=40
    LOGS_CAPTURE_FILE="$(mktemp 2>/dev/null || true)"
    if [ -n "$LOGS_CAPTURE_FILE" ]; then
        chmod 600 "$LOGS_CAPTURE_FILE" 2>/dev/null || true
        if docker logs --tail "$log_tail" "$CONTAINER" >"$LOGS_CAPTURE_FILE" 2>&1 && [ -s "$LOGS_CAPTURE_FILE" ]; then
            emit_info "daemon.logs.header" "last ${log_tail} redacted log line(s) from ${CONTAINER}:"
            while IFS= read -r log_line; do
                [ -n "$log_line" ] && emit_info "daemon.logs" "$log_line"
            done < <(redact_stdin < "$LOGS_CAPTURE_FILE")
        fi
    fi
fi

# =============================================================================
# Stage 6: Tenant Backend Wiring (Dokku, when running)
# =============================================================================
emit_stage "Stage 6/6: Tenant Backend Wiring (Dokku)"

DOKKU_CONTAINER="${DOKKU_CONTAINER:-dokku}"
if [ "$HAS_DOCKER" != true ]; then
    emit_info "tenants.dokku" "Docker is unavailable; skipping tenant backend wiring checks"
elif [ -z "$RUNNING_CONTAINER_NAMES" ] || ! printf '%s\n' "$RUNNING_CONTAINER_NAMES" | grep -qxF "$DOKKU_CONTAINER"; then
    emit_info "tenants.dokku" "Dokku container '${DOKKU_CONTAINER}' is not running; skipping tenant backend wiring checks"
else
    backend_apps="$(
        docker exec "$DOKKU_CONTAINER" dokku apps:list 2>/dev/null |
            awk '/-backend$/ {print $1}' || true
    )"
    if [ -z "$backend_apps" ]; then
        emit_info "tenants.dokku" "Dokku is running, but no *-backend tenant apps were found"
    else
        expected_nats_url="${NATS_URL:-nats://host.docker.internal:${ZATCA_NATS_PORT:-4222}}"
        expected_mysql_host="${MYSQL_HOST:-host.docker.internal}"
        while IFS= read -r app_name; do
            [ -n "$app_name" ] || continue
            app_cfg="$(docker exec "$DOKKU_CONTAINER" dokku config "$app_name" 2>/dev/null || true)"
            app_opts="$(docker exec "$DOKKU_CONTAINER" dokku docker-options:report "$app_name" 2>/dev/null || true)"
            if [ "$HAS_PYTHON" = true ]; then
                tenant_audit="$(
                    python3 - "$app_name" "$expected_nats_url" "$expected_mysql_host" "$app_cfg" "$app_opts" "$SECRETS_FILE" <<'PY' 2>/dev/null || true
import os
import re
import sys

app_name, exp_url, exp_db_host, cfg_text, opts_text, secrets_path = sys.argv[1:7]
secrets = []
if secrets_path and os.path.isfile(secrets_path):
    try:
        with open(secrets_path, "r", encoding="utf-8", errors="replace") as fh:
            secrets = [line.rstrip("\n") for line in fh if len(line.rstrip("\n")) >= 4]
    except OSError:
        secrets = []

def safe_disp(v):
    if not v:
        return "(empty)"
    if "@" in v or any(ord(c) < 32 or ord(c) == 127 for c in v):
        return "[REDACTED]"
    for s in secrets:
        if s in v:
            return "[REDACTED]"
    return v[:128]

cfg = {}
for line in cfg_text.splitlines():
    m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", line)
    if m:
        cfg[m.group(1)] = m.group(2).strip()

issues = []
if "host.docker.internal:host-gateway" not in opts_text:
    issues.append("missing host.docker.internal:host-gateway docker option")

app_url = cfg.get("NATS_URL", "")
if not app_url:
    issues.append("NATS_URL is unset")
elif app_url != exp_url:
    issues.append(f"NATS_URL={safe_disp(app_url)} differs from expected {safe_disp(exp_url)}")

exp_user = os.environ.get("NATS_USER", "")
exp_pass = os.environ.get("NATS_PASSWORD", "")
if exp_user:
    if cfg.get("NATS_USER", "") != exp_user:
        issues.append("NATS_USER does not match selected config")
if exp_pass:
    if cfg.get("NATS_PASSWORD", "") != exp_pass:
        issues.append("NATS_PASSWORD does not match selected config (value withheld)")

app_host = cfg.get("HOST", "")
if app_host and exp_db_host and app_host != exp_db_host:
    issues.append(f"HOST={safe_disp(app_host)} differs from MYSQL_HOST={safe_disp(exp_db_host)}")

if issues:
    print("WARN\t" + "; ".join(issues))
else:
    print("PASS\thost-gateway, NATS_URL, NATS_USER, NATS_PASSWORD, and HOST align with selected config")
PY
                )"
                if [ -n "$tenant_audit" ]; then
                    IFS=$'\t' read -r tstatus tmsg <<< "$tenant_audit"
                    if [ "$tstatus" = "PASS" ]; then
                        emit_pass "tenants.wiring.${app_name}" "$tmsg"
                    else
                        emit_warn "tenants.wiring.${app_name}" "$tmsg"
                        tenant_short="${app_name%-backend}"
                        add_next_step "Sync tenant '${tenant_short}' NATS/host-gateway wiring: bash scripts/deployctl.sh --config ${CONFIG_FILE} tenant update ${tenant_short} --restart"
                    fi
                fi
            fi
        done <<< "$backend_apps"
    fi
fi

# =============================================================================
# Summary & Guided Next Steps
# =============================================================================
emit_stage "Summary & Guided Next Steps"
emit_info "summary" "pass=${PASS_COUNT} warn=${WARN_COUNT} fail=${FAIL_COUNT} not_verified=${NOT_VERIFIED_COUNT}"

if [ "${#NEXT_STEPS[@]}" -gt 0 ]; then
    step_idx=1
    for step in "${NEXT_STEPS[@]}"; do
        printf 'NEXT STEP %d | %s\n' "$step_idx" "$step"
        step_idx=$((step_idx + 1))
    done
fi

if [ "$VERIFICATION_OK" = true ]; then
    printf 'OVERALL PASS | selected configuration, database access, active-branch consumer readiness, and daemon health verified; external invoice submission was not tested\n'
    exit 0
fi

printf 'OVERALL NOT VERIFIED | one or more required checks failed or remain unknown\n'
if [ "$CONFIG_BLOCKED" = true ]; then
    exit 2
fi
exit 1
