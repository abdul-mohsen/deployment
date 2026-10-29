# T033 Design

## Boundary

```text
create-tenant.sh
    -> enabled master tenant row
    -> verify registration
    -> reload-zatca-daemon.sh
         -> setup-zatca-daemon.sh
              -> compose recreation
              -> authenticated /healthz
              -> health-zatca-daemon.sh
                   -> scoped /jsz stream/consumer snapshot
```

The change stays in the deployment repository. The existing tenant, Dokku,
dashboard, NATS fallback, and T009 daemon service remain the compatibility
boundary.

## Components

### Tenant registration and reload

`create-tenant.sh` marks registration complete only after the existing
`INSERT ... ON DUPLICATE KEY UPDATE enabled=1` succeeds and a read-back query
confirms the exact tenant/database row is enabled. After the rest of the
tenant provisioning path completes, an enabled daemon invokes
`reload-zatca-daemon.sh --tenant <name>`. The helper:

1. sources the selected config file;
2. returns without side effects when the daemon is disabled;
3. validates bounded numeric limits;
4. delegates controlled recreation and readiness to the existing setup
   script; and
5. reports queue health before returning success.

A reload failure returns non-zero after the tenant row exists, so the operator
receives an actionable failure and can safely retry the reload without
recreating the tenant.

### Operational limits

The compose overlay maps host-level names to daemon container names and
forwards:

- `MAX_WORKERS_PER_TENANT` from `ZATCA_MAX_WORKERS_PER_TENANT` (finite
  positive integer);
- `MAX_WORKERS_PER_BRANCH` from `ZATCA_MAX_WORKERS_PER_BRANCH` (finite
  positive integer);
- `MAX_PENDING` from `ZATCA_MAX_PENDING` (finite positive integer);
- `MAX_ACK_PENDING` from `ZATCA_MAX_ACK_PENDING` (finite non-negative integer).

The setup and reload scripts validate these values before Compose starts.
`ZATCA_MAX_PENDING` and `ZATCA_MAX_ACK_PENDING` are also applied by the queue
health command. Worker values are additive runtime inputs for images that
support T033 scaling; the T009 image's existing one-fetch-per-branch behavior
is not changed by this deployment lane.

### Queue health command

`health-zatca-daemon.sh` uses the selected config's loopback monitor port and
monitor password to perform bounded GETs:

- `/healthz` for the existing readiness gate;
- `/jsz?accounts=true&streams=true&consumers=true` for JetStream state. The
  `accounts=true` flag is required for NATS to include `account_details` in
  the response; the embedded daemon uses one account, so this remains bounded
  to the local JetStream instance.

It selects the `ZATCA` stream from `stream_detail`, flattens its
`consumer_detail` rows, sums `num_pending`, `num_ack_pending`, and
`num_redelivered`, and emits a safe JSON or human-readable summary. It fails
when the readiness request fails, the stream is missing, JSON is malformed, or
configured backlog thresholds are exceeded. It does not expose credentials or
raw monitor payloads.

### Deployment command surface

`deployctl.sh setup zatca-health` provides the operator-facing health command.
The existing `setup zatca` and `stack restart` command paths remain unchanged.
`script health-zatca-daemon` remains available through the existing allow-list
for dashboard/script compatibility.

## Failure handling

- Missing config, Docker, Python, required daemon inputs, or invalid limits
  fails before recreation.
- Disabled daemon mode is a no-op for tenant creation and retains T009's
  standalone NATS behavior.
- A failed registry read-back prevents reload.
- A failed `/healthz` or `/jsz` check includes bounded endpoint/diagnostic
  information but never the response body or password.
- A queue threshold violation is non-zero and remains retryable; it does not
  remove a tenant or purge messages.

## Security

- No new credentials are introduced.
- The monitor remains loopback-bound by the T009 compose overlay.
- Health obtains the password from the selected operator config and emits only
  aggregate counts.
- Tenant names are validated by the existing `tenant_full_name` path and are
  passed as log context only; no tenant value is interpolated into a shell
  command.

## Test strategy

The focused `scripts/tests/test-zatca-scale.sh` is static and deterministic:

- it asserts registration read-back/reload wiring in tenant creation;
- it asserts the reload and health scripts and their bounded options;
- it asserts the compose worker/backlog environment and all T009 service
  contracts remain present; and
- it asserts `deployctl --plan setup zatca-health`.

The same test is run before source changes as red evidence and afterward as
the green deployment contract. Shell syntax and the existing deployment shell
suite provide regression coverage. Live Docker/MySQL/NATS behavior is recorded
as an environment limitation when unavailable.

## Rollout and rollback

With `ZATCA_DAEMON_ENABLED=0`, rollout is inert. With the daemon enabled,
operators first set the existing T009 image and credentials, then configure
finite limits and run `setup zatca`. New tenant creation becomes a
register/read-back/recreate/readiness/queue-health gate. Rollback is a git
revert or setting the enable flag back to `0`; the legacy standalone NATS path
remains available.

## Requirement traceability

| Requirement | Design element |
|---|---|
| FR-001 | Registry write plus exact enabled-row read-back in `create-tenant.sh`. |
| FR-002 | Opt-in `reload-zatca-daemon.sh` controlled recreation after registration. |
| FR-003 | Existing setup health wait plus queue-health gate. |
| FR-004 | Compose environment and numeric validation for worker/backlog limits. |
| FR-005 | Authenticated `/healthz` plus scoped `/jsz` aggregation/reporting. |
| FR-006 | Existing config boundary; safe aggregate output and no new secrets. |
| FR-007 | T009 service fields, ports, volumes, health, restart, and fallback retained. |
| FR-008 | Static red/green `test-zatca-scale.sh`. |
