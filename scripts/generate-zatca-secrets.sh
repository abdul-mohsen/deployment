#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    echo "Usage: bash scripts/generate-zatca-secrets.sh" >&2
    exit 2
}

if (($# > 0)); then
    usage
fi

env_file=".env"

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required to generate secrets." >&2
    exit 1
fi
if [[ -L "$env_file" ]]; then
    echo "ERROR: refusing to write through a symlink: $env_file" >&2
    exit 1
fi
if [[ -e "$env_file" && ! -f "$env_file" ]]; then
    echo "ERROR: env file is not a regular file: $env_file" >&2
    exit 1
fi
if [[ ! -d "$(dirname -- "$env_file")" ]]; then
    echo "ERROR: parent directory does not exist: $(dirname -- "$env_file")" >&2
    exit 1
fi

keys=(
    ZATCA_DB_PASSWORD
    NATS_PASSWORD
    ZATCA_ENCRYPT_KEY
    ZATCA_MONITOR_PASSWORD
)

declare -A counts=()
for key in "${keys[@]}"; do
    counts["$key"]=0
done

if [[ -f "$env_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        for key in "${keys[@]}"; do
            pattern="^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*="
            if [[ "$line" =~ $pattern ]]; then
                counts["$key"]=$((counts["$key"] + 1))
            fi
        done
    done < "$env_file"
fi

for key in "${keys[@]}"; do
    if ((counts["$key"] > 1)); then
        echo "ERROR: multiple assignments for $key in $env_file; resolve them before generating secrets." >&2
        exit 1
    fi
done

is_empty_value() {
    local value=$1

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ -z "$value" || "$value" == \#* || "$value" == '""' || "$value" == "''" ]]; then
        return 0
    fi

    [[ "$value" =~ ^\"\"[[:space:]]+\#.*$ || "$value" =~ ^\'\'[[:space:]]+\#.*$ ]]
}

generate_value() {
    if [[ "$1" == ZATCA_ENCRYPT_KEY ]]; then
        openssl rand -base64 32
    else
        openssl rand -hex 32
    fi
}

declare -A assigned=()
declare -A generated=()

if [[ -f "$env_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        for key in "${keys[@]}"; do
            pattern="^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*="
            if [[ "$line" =~ $pattern ]]; then
                assigned["$key"]=1
                value="${line#*=}"
                value="${value%$'\r'}"
                if is_empty_value "$value"; then
                    generated["$key"]="$(generate_value "$key")"
                fi
                break
            fi
        done
    done < "$env_file"
fi

for key in "${keys[@]}"; do
    if [[ -z "${assigned[$key]+x}" ]]; then
        generated["$key"]="$(generate_value "$key")"
    fi
done

tmp_file=$(mktemp -- "${env_file}.tmp.XXXXXX")
trap 'rm -f -- "$tmp_file"' EXIT

line_count=0
if [[ -f "$env_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_count=$((line_count + 1))
        matched=0
        for key in "${keys[@]}"; do
            pattern="^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*="
            if [[ "$line" =~ $pattern ]]; then
                matched=1
                if [[ -n "${generated[$key]+x}" ]]; then
                    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
                        printf 'export %s=%s\n' "$key" "${generated[$key]}" >> "$tmp_file"
                    else
                        printf '%s=%s\n' "$key" "${generated[$key]}" >> "$tmp_file"
                    fi
                else
                    printf '%s\n' "$line" >> "$tmp_file"
                fi
                break
            fi
        done
        if ((matched == 0)); then
            printf '%s\n' "$line" >> "$tmp_file"
        fi
    done < "$env_file"
fi

append_missing=0
for key in "${keys[@]}"; do
    if [[ -z "${assigned[$key]+x}" ]]; then
        append_missing=1
        break
    fi
done

if ((append_missing == 1)); then
    if ((line_count > 0)); then
        printf '\n' >> "$tmp_file"
    fi
    for key in "${keys[@]}"; do
        if [[ -z "${assigned[$key]+x}" ]]; then
            printf '%s=%s\n' "$key" "${generated[$key]}" >> "$tmp_file"
        fi
    done
fi

chmod 600 "$tmp_file"
mv -f -- "$tmp_file" "$env_file"
trap - EXIT

generated_keys=()
for key in "${keys[@]}"; do
    if [[ -n "${generated[$key]+x}" ]]; then
        generated_keys+=("$key")
    fi
done

if ((${#generated_keys[@]} > 0)); then
    printf 'Generated or filled %s in %s (permissions: 600).\n' \
        "${generated_keys[*]}" "$env_file"
else
    printf 'All four secret values were already set in %s; values were preserved (permissions: 600).\n' \
        "$env_file"
fi
