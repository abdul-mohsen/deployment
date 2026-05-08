#!/usr/bin/env bash
# Adds the dokku container's hostname to its /etc/hosts so sudo stops warning
# `unable to resolve host <containerid>`. Idempotent.
set -euo pipefail

HOST=$(docker exec dokku hostname)
docker exec -u root dokku sh -c "grep -q ' ${HOST}\$' /etc/hosts || echo '127.0.1.1 ${HOST}' >> /etc/hosts"
docker exec dokku sudo -n echo OK
