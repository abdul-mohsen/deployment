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

# Host-published ports for the app's container, formatted as "host:container,...".
# Empty when Dokku fronts traffic via its own nginx (the usual case).
app_host_ports() {
    local app="$1"
    local cid; cid=$(app_container_id "$app")
    [ -z "$cid" ] && return 0
    docker inspect -f \
        '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}}->{{$p}} {{end}}{{end}}' \
        "$cid" 2>/dev/null | xargs 2>/dev/null
}

# Dokku's own host-published ports (the entry point all tenant traffic goes through)
dokku_host_ports() {
    docker port dokku 2>/dev/null | awk '{print $1" -> "$3}' | paste -sd ', ' -
}

# What process types does this app expose? (e.g. "web cron worker")
app_process_types() {
    local app="$1"
    docker exec -i dokku dokku ps:scale "$app" 2>/dev/null \
        | awk 'NR>2 && $1!="" {print $1}' | xargs 2>/dev/null
}

# Detect role from app name suffix; falls back to "app" for arbitrary names.
app_kind() {
    case "$1" in
        *-backend)  echo backend  ;;
        *-frontend) echo frontend ;;
        *)          echo app      ;;
    esac
}

# Tenant inferred from app name ("-backend"/"-frontend" stripped if present).
app_tenant() {
    local app="$1"
    case "$app" in
        *-backend)  echo "${app%-backend}"  ;;
        *-frontend) echo "${app%-frontend}" ;;
        *)          echo "$app" ;;
    esac
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
    local dports; dports=$(dokku_host_ports)
    if ! $JSON; then
        echo ""
        echo "${B}===========================================================${N}"
        echo "${B}  Dokku Status — *.${BASE_DOMAIN}   $(date '+%F %T %Z')${N}"
        echo "${B}===========================================================${N}"
        printf "  Dokku container : %s\n" "$(colorize_state "$dstate")"
        printf "  Dokku host ports: %s\n" "${dports:-<none>}"
        printf "  Auto-pull cron  : %s\n" "$(cron_has_autopull)"
        echo ""
    fi

    if [ "$dstate" != "running" ]; then
        $JSON || echo "${R}Dokku is not running — no app data to report.${N}"
        $JSON && echo '{"dokku":"'"$dstate"'","apps":[]}'
        return
    fi

    # All Dokku apps (one per line). Strip the "=====> My Apps" header by keeping
    # only lines that look like a Dokku app name (lowercase, digits, hyphens).
    local apps; apps=$(docker exec -i dokku dokku --quiet apps:list 2>/dev/null \
                       | grep -E '^[a-z0-9][a-z0-9-]*$' || true)

    if [ -n "$TENANT_FILTER" ]; then
        apps=$(printf '%s\n' "$apps" \
               | awk -v t="$TENANT_FILTER" '$0==t || $0==t"-backend" || $0==t"-frontend"')
    fi

    if [ -z "$apps" ]; then
        if $JSON; then
            printf '{"dokku":"running","host_ports":"%s","apps":[]}\n' "$dports"
        else
            echo "  ${Y}No Dokku apps registered.${N}"
            echo "  ${D}Raw 'dokku apps:list' output:${N}"
            docker exec -i dokku dokku apps:list 2>&1 | sed 's/^/    /' || true
            echo ""
            echo "  Hints:"
            echo "    • Did setup-dev-tenant.sh complete?  sudo bash scripts/setup-dev-tenant.sh"
            echo "    • Create one manually:                 dokku apps:create dev-backend"
        fi
        return
    fi

    if $JSON; then
        printf '{"dokku":"running","host_ports":"%s","apps":[' "$dports"
    else
        printf "  ${D}%-18s %-8s %-9s %-3s %-5s %-6s %-7s %-32s %s${N}\n" \
            "APP" "ROLE" "STATE" "RST" "HTTP" "INTPORT" "PROCS" "IMAGE (running)" "DOMAINS"
    fi

    local first=true
    while IFS= read -r app; do
        [ -z "$app" ] && continue
        local tenant; tenant=$(app_tenant "$app")
        local kind;   kind=$(app_kind "$app")
        local cid;    cid=$(app_container_id "$app")

        local state="missing" rcount="-" image="-" probe="000" path="/"
        if [ -n "$cid" ]; then
            state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo missing)
            rcount=$(app_restart_count "$app")
            image=$(app_image "$app")
        else
            state="not-deployed"
        fi
        local intport;   intport=$(app_internal_port "$app")
        local hostports; hostports=$(app_host_ports "$app")
        local procs;     procs=$(app_process_types "$app")
        [ "$kind" = "backend" ] && path="/healthz"
        [ -n "$cid" ] && probe=$(app_http_probe "$app" "$path")
        local domains; domains=$(docker exec -i dokku dokku domains:report "$app" --domains-app-vhosts 2>/dev/null | tr -s ' ')

        if $JSON; then
            $first || printf ','
            first=false
            local pin; pin=$(tenant_pin "$tenant")
            local pin_be; pin_be="${pin%%|*}"
            local rest="${pin#*|}"
            local pin_fe; pin_fe="${rest%%|*}"
            local enabled="${rest##*|}"
            printf '{"app":"%s","tenant":"%s","role":"%s","state":"%s","restarts":"%s","http":"%s","internal_port":"%s","host_ports":"%s","processes":"%s","image":"%s","domains":"%s","pinned_backend":"%s","pinned_frontend":"%s","enabled":"%s"}' \
                "$app" "$tenant" "$kind" "$state" "$rcount" "$probe" "$intport" "$hostports" "$procs" "$image" "$domains" "$pin_be" "$pin_fe" "$enabled"
        else
            printf "  %-18s %-8s %s %-3s %s %-6s %-7s %-32s %s\n" \
                "$app" "$kind" "$(printf '%-9s' "$(colorize_state "$state")")" \
                "$rcount" \
                "$(printf '%-5s' "$(colorize_http "$probe")")" \
                "${intport:--}" "${procs:--}" "${image:--}" "${domains:--}"
            [ -n "$hostports" ] && printf "  ${D}%-18s   host-published: %s${N}\n" "" "$hostports"
        fi

        if ! $JSON && [ -n "$TENANT_FILTER" ]; then
            local pin; pin=$(tenant_pin "$tenant")
            local pin_be; pin_be="${pin%%|*}"
            local rest="${pin#*|}"
            local pin_fe; pin_fe="${rest%%|*}"
            local enabled="${rest##*|}"
            echo ""
            echo "  ${D}Pinned in master DB :${N} backend=${pin_be:-<unset>} frontend=${pin_fe:-<unset>} enabled=${enabled:-?}"
            echo ""
            echo "  ${D}Recent ${app} logs:${N}"
            docker exec -i dokku dokku logs "$app" --tail 15 2>/dev/null | sed 's/^/    /' || true
        fi
    done <<< "$apps"

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
