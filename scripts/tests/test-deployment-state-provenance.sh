#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

source scripts/lib.sh
source scripts/tenant-provenance.sh

CAPTURE=""
run_mysql() {
    local args="$*"
    if [[ "$args" == *"-e"* ]]; then
        CAPTURE+="${args}"$'\n'
    else
        cat >/dev/null
    fi
}

ensure_tenant_provenance_schema
tenant_record_identity tenant_acme backend repo/api:v1 repo/api:v1 sha256:abc release \
    v1.2.3 commitsha commitshort 42 https://github.com/example/api/actions/runs/42 \
    2026-11-07T10:00:00Z
tenant_record_failure tenant_acme backend "verification failed"
tenant_record_audit tenant_acme backend repo/api:v1 repo/api@sha256:abc sha256:abc \
    release v1.2.3 commitsha commitshort 42 \
    https://github.com/example/api/actions/runs/42 2026-11-07T10:00:00Z \
    repo/api:v0 sha256:old failed "verification failed"
tenant_clear_identity tenant_acme backend "cleared"
tenant_current_identity tenant_acme backend >/dev/null

grep -Fq 'deployment_state' <<<"$CAPTURE" ||
    { echo "provenance helpers did not target deployment_state" >&2; exit 1; }
grep -Fq 'tenant_identity' <<<"$CAPTURE" ||
    { echo "provenance helpers did not target tenant_identity" >&2; exit 1; }
grep -Fq 'tenant_deployment_audit' <<<"$CAPTURE" ||
    { echo "audit helper did not target tenant_deployment_audit" >&2; exit 1; }
if grep -Eq 'UPDATE tenant |FROM tenant WHERE|INSERT INTO tenant ' <<<"$CAPTURE"; then
    echo "provenance helpers still mutate the ZATCA tenant registry" >&2
    exit 1
fi

echo "PASS: tenant provenance uses deployment-owned state schema"
