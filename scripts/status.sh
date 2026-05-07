#!/usr/bin/env bash
# =============================================================================
# status.sh — Live status of all Dokku tenants on this server
# =============================================================================
# Prints a single-pass report of:
#   - Dokku container health
#   - Per-app process state (running/restarting/crashed) and restart count
#   - Currently deployed image
#   - Domains, internal Dokku-network port, host-published port (if any)
#   - HTTP probe (in-container) result
#   - Master-DB tenant pin (next image auto-pull will deploy)
#   - Auto-pull cron presence
#
# Usage:
#   sudo bash scripts/status.sh                  # all tenants, summary
#   sudo bash scripts/status.sh --tenant dev     # one tenant, verbose
#   sudo bash scripts/status.sh --watch          # refresh every 5s (Ctrl-C to exit)
#   sudo bash scripts/status.sh --json           # machine-readable
#   sudo bash scripts/status.sh --config /opt/deployment/config.dev.env
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.env"
TENANT_FILTER=""
WATCH=false
JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)  CONFIG_FILE="$2"; shift 2 ;;
        --tenant)  TENANT_FILTER="$2"; shift 2 ;;
        --watch)   WATCH=true; shift ;;
        --json)    JSON=true; shift ;;
        -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
        *)         echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BASE_DOMAIN="${BASE_DOMAIN:-<unset>}"
MYSQL_MASTER_DB="${MYSQL_MASTER_DB:-zatca_master}"

# ---- Colors (auto-disabled if not a TTY or --json) ---------------------------
if $JSON || [ ! -t 1 ]; then
    R=""; G=""; Y=""; B=""; D=""; N=""
else
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
    B=$'\033[0;34m'; D=$'\033[2m';   N=$'\033[0m'
fi

# ---- Helpers -----------------------------------------------------------------
have_dokku_container() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'dokku'
}

# Echoes status of the dokku container itself: "running"/"stopped"/"missing"
dokku_state() {
    if ! docker inspect dokku &>/dev/null; then
        echo "missing"; return
    fi
    docker inspect -f '{{.State.Status}}' dokku 2>/dev/null
}

# Returns the running container ID for an app's web process (empty if none)
app_container_id() {
    local app="$1"
    docker ps --filter "name=^${app}\.web\." --format '{{.ID}}' | head -1
}

# Returns image:tag currently running for an app (empty if not running)
app_image() {
    local app="$1"
    local cid; cid=$(app_container_id "$app")
    [ -z "$cid" ] && return 0
    docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null
}

# Restart count for the app's running container
app_restart_count() {
    local app="$1"
    local cid; cid=$(app_container_id "$app")
    [ -z "$cid" ] && { echo "-"; return; }
    docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null
}

# Internal Dokku-network port the app listens on (parsed from `dokku ports:report`)
app_internal_port() {
    local app="$1"
    docker exec -i dokku dokku ports:report "$app" 2>/dev/null \
        | awk -F: '/Ports map:/ {print $NF}' \
        | tr -d ' ' | head -1
}

# Host-published port if Dokku is itself published (only meaningful in standalone)
dokku_host_port() {
    docker port dokku 80/tcp 2>/dev/null | awk -F: '{print $NF}' | head -1
}

# HTTP probe inside the dokku container against the app's web service
app_http_probe() {
    local app="$1"
    local path="${2:-/}"
    docker exec -i dokku bash -lc \
        "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://${app}.web${path}" \
        2>/dev/null || echo "000"
}

# Per-tenant pin from master DB (echoes "<backend>|<frontend>|<enabled>")
tenant_pin() {
    local name="$1"
    if ! command -v mysql &>/dev/null && [ "${_MYSQL_VIA:-host}" = "docker" ]; then
        echo "|"; return
    fi
    run_mysql -N -B -e \
        "SELECT IFNULL(backend_image,''), IFNULL(frontend_image,''), enabled
           FROM \`${MYSQL_MASTER_DB}\`.tenant
          WHERE name='${name//\'/}' LIMIT 1;" 2>/dev/null \
        | awk -F'\t' '{printf "%s|%s|%s", $1, $2, $3}'
}

cron_has_autopull() {
    crontab -l 2>/dev/null | grep -q 'auto-pull.sh' && echo "yes" || echo "no"
}

colorize_state() {
    case "$1" in
        running)               echo "${G}running${N}" ;;
        restarting|created)    echo "${Y}$1${N}" ;;
        exited|dead|paused)    echo "${R}$1${N}" ;;
        missing|"")            echo "${R}missing${N}" ;;
        *)                     echo "$1" ;;
    esac
}

colorize_http() {
    local code="$1"
    case "$code" in
        2*|3*) echo "${G}${code}${N}" ;;
        000)   echo "${R}no-resp${N}" ;;
        *)     echo "${Y}${code}${N}" ;;
    esac
}

# ---- One pass of the report --------------------------------------------------
render_once() {
    local dstate; dstate=$(dokku_state)
    if ! $JSON; then
        echo ""
        echo "${B}===========================================================${N}"
        echo "${B}  Dokku Status — *.${BASE_DOMAIN}   $(date '+%F %T %Z')${N}"
        echo "${B}===========================================================${N}"
        printf "  Dokku container : %s\n" "$(colorize_state "$dstate")"
        printf "  Auto-pull cron  : %s\n" "$(cron_has_autopull)"
        local hp; hp=$(dokku_host_port)
        [ -n "$hp" ] && printf "  Dokku host port : 80 -> ${hp}\n"
        echo ""
    fi

    if [ "$dstate" != "running" ]; then
        $JSON || echo "${R}Dokku is not running — no app data to report.${N}"
        $JSON && echo '{"dokku":"'"$dstate"'","tenants":[]}'
        return
    fi

    # Build tenant list from app names ending in -backend or -frontend
    local apps; apps=$(docker exec -i dokku dokku apps:list 2>/dev/null | tail -n +2 || true)
    local -A tenants_seen=()
    local tenant_list=()
    while IFS= read -r app; do
        [ -z "$app" ] && continue
        local t=""
        case "$app" in
            *-backend)  t="${app%-backend}"  ;;
            *-frontend) t="${app%-frontend}" ;;
            *) continue ;;
        esac
        if [ -z "${tenants_seen[$t]:-}" ]; then
            tenants_seen[$t]=1
            tenant_list+=("$t")
        fi
    done <<< "$apps"

    if [ -n "$TENANT_FILTER" ]; then
        local filtered=()
        for t in "${tenant_list[@]}"; do
            [ "$t" = "$TENANT_FILTER" ] && filtered+=("$t")
        done
        tenant_list=("${filtered[@]}")
    fi

    if [ ${#tenant_list[@]} -eq 0 ]; then
        $JSON && echo '{"dokku":"running","tenants":[]}' || echo "  (no tenants)"
        return
    fi

    if $JSON; then
        printf '{"dokku":"running","host_port":"%s","tenants":[' "$(dokku_host_port)"
    else
        printf "  ${D}%-12s %-9s %-8s %-3s %-5s %-32s %-5s %s${N}\n" \
            "TENANT" "APP" "STATE" "RST" "HTTP" "IMAGE (running)" "PORT" "DOMAINS"
    fi

    local first=true
    for t in "${tenant_list[@]}"; do
        local pin; pin=$(tenant_pin "$t")
        local pin_be; pin_be="${pin%%|*}"
        local rest="${pin#*|}"
        local pin_fe; pin_fe="${rest%%|*}"
        local enabled; enabled="${rest##*|}"

        for kind in backend frontend; do
            local app="${t}-${kind}"
            docker exec -i dokku dokku apps:exists "$app" &>/dev/null || continue

            local cid; cid=$(app_container_id "$app")
            local state="missing" rcount="-" image="-" port="-" probe="000" path="/"
            if [ -n "$cid" ]; then
                state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo missing)
                rcount=$(app_restart_count "$app")
                image=$(app_image "$app")
            fi
            port=$(app_internal_port "$app")
            [ "$kind" = "backend" ] && path="/healthz"
            [ -n "$cid" ] && probe=$(app_http_probe "$app" "$path")
            local domains; domains=$(docker exec -i dokku dokku domains:report "$app" --domains-app-vhosts 2>/dev/null | tr -s ' ')

            if $JSON; then
                $first || printf ','
                first=false
                printf '{"tenant":"%s","app":"%s","state":"%s","restarts":"%s","http":"%s","image":"%s","port":"%s","domains":"%s","pinned_backend":"%s","pinned_frontend":"%s","enabled":"%s"}' \
                    "$t" "$app" "$state" "$rcount" "$probe" "$image" "$port" "$domains" "$pin_be" "$pin_fe" "$enabled"
            else
                printf "  %-12s %-9s %s %-3s %s %-32s %-5s %s\n" \
                    "$t" "$kind" "$(printf '%-9s' "$(colorize_state "$state")")" \
                    "$rcount" \
                    "$(printf '%-5s' "$(colorize_http "$probe")")" \
                    "${image:--}" "${port:--}" "${domains:--}"
            fi
        done

        if ! $JSON && [ -n "$TENANT_FILTER" ]; then
            echo ""
            echo "  ${D}Pinned in master DB :${N} backend=${pin_be:-<unset>} frontend=${pin_fe:-<unset>} enabled=${enabled:-?}"
            echo ""
            echo "  ${D}Recent backend logs:${N}"
            docker exec -i dokku dokku logs "${t}-backend" --tail 15 2>/dev/null | sed 's/^/    /' || true
        fi
    done

    $JSON && printf ']}\n'
    $JSON || echo ""
}

# ---- Main --------------------------------------------------------------------
if $WATCH; then
    while :; do
        clear
        render_once
        sleep 5
    done
else
    render_once
fi
