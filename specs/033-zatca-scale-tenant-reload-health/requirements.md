# T033 — Tenant Reload, Worker Bounds, and Queue Health

## Problem

The deployment can create a tenant row and its Dokku applications, but the
long-running ZATCA daemon discovers tenants and branches at process startup.
A newly created tenant can therefore remain invisible to the daemon until an
operator performs an unrelated restart. The deployment also does not expose a
bounded operational contract for tenant/branch work or a queue health view
that distinguishes a ready daemon from a growing JetStream backlog.

## Goal

Make tenant creation and daemon operation observable and restart-safe without
changing the existing T009 service contract or introducing credentials,
proprietary artifacts, or a second broker.

## In scope

- Registering a successfully provisioned tenant for daemon discovery using the
  existing master tenant registry.
- Automatically reloading the enabled daemon after registration, or using a
  controlled discovery/reload path when the daemon image supports one.
- Waiting for daemon readiness after reload and reporting stream, consumer, and
  pending-message health.
- A deployment configuration contract for bounded per-tenant/branch worker
  concurrency and backlog thresholds.
- Focused deployment contract tests covering tenant registration, reload,
  readiness, worker/backlog bounds, and queue-health reporting.
- Deployment runbook and configuration-template updates needed to operate the
  new contract.

## Out of scope

- Changes to the ZATCA daemon source repository, backend/frontend source
  repositories, database schema, NATS subjects, or provider behavior.
- Inventing, generating, or committing database, monitor, encryption, SMTP, or
  tenant credentials.
- Starting a second NATS/JetStream service.
- Replacing the Dokku tenant lifecycle or dashboard control plane.
- Claiming live Docker, MySQL, NATS, or ZATCA-provider evidence when those
  services are unavailable.

## User scenarios

### Scenario 1: New tenant becomes daemon-visible

Given a tenant database and enabled master-registry row are successfully
created, when tenant creation completes with the daemon enabled, then the
deployment performs the configured daemon reload/discovery action and verifies
daemon readiness before reporting success.

### Scenario 2: Legacy installation remains unchanged

Given the daemon is disabled, when an operator creates or updates a tenant,
then the existing tenant/Dokku/NATS behavior remains unchanged and no daemon
container, secret, or reload is required.

### Scenario 3: Bounded operational configuration

Given an operator configures worker and backlog limits, when the daemon service
starts, then the service receives those operator-supplied limits and the
deployment health contract reports a failure or warning when the configured
backlog bound is exceeded.

### Scenario 4: Queue health is actionable

Given a running daemon, when an operator checks deployment health, then the
result identifies daemon readiness, the expected ZATCA stream, consumer count,
pending messages, and acknowledgement-pending messages without exposing
monitor credentials.

### Scenario 5: Idempotent retry

Given tenant creation is retried after a partial failure, when the existing
registry row is enabled again, then the reload and health actions are safe to
repeat and do not create duplicate tenants, brokers, or workers.

## Functional requirements

- **FR-001 — Registry registration:** A tenant successfully provisioned by
  `create-tenant.sh` MUST be present as an enabled row in the configured master
  registry before daemon reload/discovery is requested.
- **FR-002 — Reload/discovery:** When `ZATCA_DAEMON_ENABLED` is true and
  registration succeeds, tenant creation MUST invoke one controlled daemon
  reload/discovery path. When the flag is false, this path MUST be a no-op.
- **FR-003 — Readiness gate:** A requested reload MUST wait for the existing
  authenticated daemon readiness contract and MUST fail with bounded,
  actionable diagnostics if readiness is not restored.
- **FR-004 — Worker bounds:** Deployment configuration MUST expose explicit,
  operator-adjustable bounds for per-tenant/branch worker concurrency and
  per-consumer pending/acknowledgement-pending backlog. Defaults MUST be
  finite and documented.
- **FR-005 — Queue health:** Deployment health MUST expose the ZATCA stream,
  consumer count, stream messages, pending messages, acknowledgement-pending
  messages, and whether configured limits are satisfied.
- **FR-006 — Secret boundary:** Health, reload, tests, and templates MUST
  consume existing operator-provided daemon credentials only through the
  existing configuration boundary; no credential value may be invented or
  printed.
- **FR-007 — Compatibility:** T009 daemon compose identity, NATS endpoint,
  persistent volumes, authenticated `/healthz`, opt-in enable flag, legacy
  standalone NATS path, and restart ordering MUST remain compatible.
- **FR-008 — Contract regression:** A focused deployment test MUST fail against
  the T009 baseline because tenant creation lacks reload/health and worker or
  queue-bound contracts, and MUST pass after implementation.

## Non-functional requirements

- Reload and health operations MUST be idempotent and safe after partial tenant
  creation.
- Health collection MUST be bounded in time and must not require a live Docker
  engine for static contract tests.
- Queue-health output MUST be safe for logs and dashboards: no passwords,
  encryption keys, OTPs, or connection strings containing secrets.
- The change MUST remain isolated to the deployment repository and be
  reviewable as one commit.

## Acceptance criteria

1. A focused T033 contract test is recorded red against e289a72 before source
   changes because tenant creation has no daemon reload/readiness/queue-health
   contract and no explicit worker/backlog bound contract.
2. The final contract registers/enables the tenant before reload, reloads or
   discovers it only when the daemon is enabled, and verifies authenticated
   readiness.
3. Compose/config templates expose finite worker and backlog settings without
   hard-coded credentials and preserve T009 service behavior.
4. A health command or equivalent reports stream, consumer, pending, and
   acknowledgement-pending state and applies configured thresholds.
5. Shell syntax, focused deployment tests, relevant existing shell tests, and
   dashboard `go test`, `go vet`, and `go build` pass.
6. Docker/MySQL/NATS runtime limitations are explicitly recorded if those
   services are unavailable.
7. The final commit contains only T033 changes, includes the required
   co-author trailer, and is not pushed or opened as a PR.

## Assumptions

- The daemon image used by T009 discovers enabled tenants from the configured
  master registry at startup.
- The daemon's existing authenticated monitor port exposes NATS `/healthz` and
  JetStream `/jsz` data, including stream and consumer state.
- The daemon runtime account's existing tenant-database grant pattern is the
  access mechanism for newly created tenant databases; deployment must not
  create a new credential path.
- The deployment repository may use a controlled container recreation when the
  approved image does not expose a live reload API.

## Constraints

- Work only in `C:\ssda\chatGPT\worktrees\zatca-fix-t033-deployment` on
  `fix/zatca/scale-tenant-reload-health`.
- Base behavior is deployment commit `e289a72`.
- Preserve T009 service behavior when the daemon is disabled or when existing
  operators omit T033-specific optional settings.
- Do not push, create a pull request, or modify sibling repository worktrees.

## Risks and open questions

- The T009 image does not expose a daemon-specific reload endpoint; a bounded
  controlled recreation is therefore the compatibility default unless a future
  image advertises a reload command.
- The T009 daemon source creates one sequential worker per document type and
  branch but does not yet consume deployment worker-limit environment variables.
  The deployment contract must forward limits without changing the T009
  command line, and must not claim enforcement by an image that ignores them.
- `/jsz` response size grows with the number of consumers; health collection
  must request only the scoped ZATCA stream and use bounded timeouts.

## Observable success measures

- A new enabled tenant is visible to the daemon after the create command's
  reload/readiness gate, without a manual unrelated stack restart.
- Queue health reports the expected ZATCA stream and non-fabricated consumer and
  pending counts in a bounded command.
- Worker and backlog settings are finite, operator-controlled, documented, and
  present in the daemon service contract.
- Disabled-daemon tenant creation produces no daemon side effects and retains
  the T009 compatibility path.
