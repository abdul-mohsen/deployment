# T033 Validation Guide

## Static and shell checks

From the deployment worktree:

```sh
bash scripts/tests/test-zatca-scale.sh
bash -n scripts/create-tenant.sh scripts/reload-zatca-daemon.sh \
  scripts/health-zatca-daemon.sh scripts/setup-zatca-daemon.sh \
  scripts/deployctl.sh
```

The focused test must fail against e289a72 before implementation and pass after
the T033 changes.

## Operator configuration

Copy the existing private deployment config and keep all T009 credentials
operator-owned. Set the approved daemon image, existing DB/encryption/monitor
values, and finite T033 limits:

```text
ZATCA_DAEMON_ENABLED=1
ZATCA_MAX_WORKERS_PER_TENANT=1
ZATCA_MAX_WORKERS_PER_BRANCH=1
ZATCA_MAX_PENDING=1000
ZATCA_MAX_ACK_PENDING=100
```

Do not copy these values into a committed secret file; the numeric values are
safe defaults and the existing secret values remain deployment inputs.

## Live checks

```sh
sudo bash scripts/setup-zatca-daemon.sh --config /opt/deployment/config.env
sudo bash scripts/health-zatca-daemon.sh --config /opt/deployment/config.env
sudo bash scripts/health-zatca-daemon.sh --config /opt/deployment/config.env --json
sudo bash scripts/deployctl.sh tenant create acme --config /opt/deployment/config.env
```

Expected behavior: the tenant registry row is read back as enabled, the daemon
is recreated only when enabled, readiness is restored, and queue health reports
the `ZATCA` stream plus current consumer/pending counts.

## Runtime limitation

The live sequence requires Docker, MySQL, an approved daemon image, operator
credentials, and a running NATS monitor. If any is unavailable, run the static
and shell gates and record the limitation; do not substitute invented
credentials or claim runtime evidence.
