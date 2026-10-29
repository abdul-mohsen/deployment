# T033 Research

## Repository evidence

| Question | Evidence | Decision |
|---|---|---|
| How is a tenant registered today? | `scripts/create-tenant.sh` inserts `name` and `db_name` into the configured `MYSQL_MASTER_DB.tenant` table with `enabled=1` on duplicate. | Keep that registry as the daemon's source of truth; add an explicit post-write verification before reload. |
| How does the T009 daemon discover tenants? | The dependent daemon loads enabled tenants once during startup, opens each tenant DB, queries active branches, starts workers, and starts one onboarding consumer per tenant. | A new tenant requires a controlled daemon recreation on the T009 image; do not invent a reload API. |
| What does T009 expose for readiness? | `dashboard/docker-compose.zatca.yml` publishes an authenticated loopback monitor and checks `/healthz`; `setup-zatca-daemon.sh` waits for the container health state. | Reuse the existing `/healthz` gate and add a separate bounded JetStream state check. |
| Where are queue metrics available? | The T009 image embeds NATS JetStream. NATS monitoring `/jsz?streams=true&consumers=true` reports stream detail and consumer `num_pending`/`num_ack_pending`. | Health reads a scoped `/jsz` response, selects stream `ZATCA`, and reports aggregate consumer/pending values. |
| Can deployment change daemon worker internals? | The T008 daemon source in sibling worktree has sequential `Fetch(1)` workers per `(doc type, tenant, branch)` and no worker-limit/reload environment handling. | Keep the T009 command line unchanged. Forward explicit T033 operational knobs for compatible images and make the health/backlog thresholds enforceable by deployment without claiming unsupported image behavior. |
| What credentials may be used? | T009 requires operator-supplied `ZATCA_DB_*`, encryption, and monitor values; the daemon account is separate from the deployment admin account. | Reload/health source the existing config only; tests use placeholders and never print values. |

## External evidence

- NATS monitoring documentation describes the monitor port as read-only HTTP
  JSON and identifies `/jsz` as the JetStream stream/consumer view.
- NATS server source bundled in the T008 worktree defines consumer fields
  `num_pending`, `num_ack_pending`, `num_redelivered`, and `num_waiting`, and
  stream `stream_detail`/`consumer_detail` response fields.

## Decisions

### Controlled recreation is the T009 reload mechanism

The T009 daemon has no signal/reload endpoint and its tenant map is built only
at startup. T033 therefore invokes the existing `setup-zatca-daemon.sh`
overlay lifecycle with `--force-recreate`, then waits for both container
readiness and queue health. This is bounded, idempotent, and preserves the
T009 service identity, volumes, port mappings, and opt-in behavior.

### Registry access remains pattern-based

The existing daemon account is documented to receive access to the master
registry and tenant database pattern. T033 verifies the newly inserted enabled
registry row but does not create grants, copy passwords, or reuse the
deployment admin account. A missing account or grant remains a setup failure
with the existing actionable configuration error.

### Operational bounds are additive configuration

The compose overlay forwards finite, operator-controlled
`ZATCA_MAX_WORKERS_PER_TENANT`, `ZATCA_MAX_WORKERS_PER_BRANCH`,
`ZATCA_MAX_PENDING`, and `ZATCA_MAX_ACK_PENDING` values. Current T009 images
retain their command-line behavior; T033-capable images can consume the worker
limits. The deployment health command always applies the pending thresholds,
so a growing queue cannot be reported as healthy merely because `/healthz`
responds.

### Queue health is separate from liveness

`/healthz` remains the existing liveness/readiness contract. The new health
command additionally checks that the `ZATCA` stream exists and reports stream
messages, consumers, pending messages, acknowledgement-pending messages,
redeliveries, and threshold status. Empty consumer sets are valid for an empty
registry; a missing stream is not.

## Alternatives considered

1. **Add a new daemon HTTP reload endpoint** — rejected because it would change
   the dependent daemon repository and create an unverified T009 API.
2. **Always restart the whole stack after tenant creation** — rejected because
   it unnecessarily disrupts Dokku/dashboard services and violates the
   deployment-only scope.
3. **Run a second broker or per-tenant broker** — rejected because T009 makes
   the daemon's embedded JetStream the single service of record.
4. **Use a host cron watcher as the default** — rejected because it introduces
   hidden state and an unbounded polling process; post-registration reload is
   deterministic and easier to retry.
5. **Parse `/jsz` with an unbounded shell grep pipeline** — rejected because
   consumer count grows with tenants and branches; a bounded JSON parser keeps
   selection scoped and avoids false positives.

## Remaining uncertainty

The exact future daemon image that consumes the worker-limit environment
variables is outside this deployment repository. T033 deliberately forwards
the values without changing the T009 command line and records this limitation
in the runbook and final status.
