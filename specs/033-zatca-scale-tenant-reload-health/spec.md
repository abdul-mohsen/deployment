# T033 — Tenant Reload, Worker Bounds, and Queue Health

## User stories

### US1 — New tenants become daemon-visible

As an operator, I want creating a tenant to register it and refresh the
enabled daemon so the tenant does not wait for an unrelated stack restart.

### US2 — Operations remain bounded

As an operator, I want finite worker and backlog settings forwarded through the
deployment contract so scale is explicit and queue growth is actionable.

### US3 — Queue health is observable

As an operator, I want one authenticated health command to show daemon
readiness, stream existence, consumers, pending messages, and thresholds.

## Functional requirements

- Tenant creation must verify the enabled master-registry row before requesting
  daemon reload.
- Reload must be opt-in, idempotent, bounded, and health-gated.
- Disabled daemon mode must retain T009 behavior without side effects.
- The daemon service must receive finite worker and pending-limit settings from
  operator config without any credential literals.
- Queue health must read the existing authenticated monitor and expose
  non-fabricated ZATCA stream/consumer/pending counts.
- Threshold failures must be non-zero and retryable; no tenant or message may
  be deleted as a health response.

## Success criteria

- A focused deployment test is red on e289a72 and green after T033.
- New tenant creation has an observable registry/read-back/reload/readiness
  sequence when the daemon is enabled.
- Queue health completes within its configured timeout and reports stream,
  consumer, pending, and acknowledgement-pending values.
- Existing T009-focused tests and dashboard build gates pass unchanged.
- No credentials, SDK files, or unrelated repositories are changed.
