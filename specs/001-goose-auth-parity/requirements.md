# Requirements: Goose Host-MySQL Migration Authentication Parity

## Problem

Tenant provisioning runs in a Dokku/containerized deployment environment and
connects to MySQL on the host machine. In the reported run, the deployment
MySQL-client check and the check from Goose's Docker bridge context both
authenticate as `dokku_admin`, but Goose fails with MySQL error 1045 while
initializing the `zatca_master` migration ledger.

The host database and deployment environment are reachable, and other MySQL
connections work. The production password is redacted, so its exact characters
cannot be confirmed from the report.

## Goals

- Identify why the successful MySQL-client checks do not predict Goose's
  authentication result.
- Ensure that the credentials passed to Goose represent the configured MySQL
  credentials exactly.
- Preserve prompt, fail-closed behavior before backup, schema changes, or
  tenant provisioning when required database access is unavailable.
- Give operators useful, secret-safe failure output.

## Scope

### In scope

- The deployment repository's ZATCA master migration connection construction
  and existing preflight path.
- Focused regression tests for credential representation and fail-fast
  behavior.
- Operator-facing README guidance for the host-MySQL migration connection.

### Out of scope

- Changing MySQL accounts, passwords, grants, firewall rules, or the host's
  MySQL configuration.
- Changing tenant application behavior or unrelated migrations.
- Adding a legacy or dual-configuration fallback for the migration runner.
- Inspecting or logging the production database password.

## User stories

1. As a deployment operator, I need Goose to use the exact configured MySQL
   credentials so a working client preflight is not followed by an avoidable
   authentication failure.
2. As an operator diagnosing a failed migration, I need provisioning to stop
   before tenant state changes and report actionable context without
   disclosing credentials.

## Functional requirements

- **FR-1:** The deployment helper and Goose must use the same effective MySQL
  host, port, database, user, and credential source.
- **FR-2:** Goose's MySQL data source must preserve the configured username and
  password exactly as required by its MySQL driver; it must not apply
  URL-encoding semantics to credential fields.
- **FR-3:** The existing deployment and Goose-bridge preflight checks must
  remain before backup and schema mutation, and failures must stop
  provisioning.
- **FR-4:** Failure output must name safe connection context (host, port,
  database, and user as appropriate), describe the failure category, and
  never print the password or a credential-bearing connection string.
- **FR-5:** The existing tenant-provisioning command interface and documented
  MySQL environment names must remain unchanged. No legacy Goose DSN fallback
  is required.

## Non-functional requirements

- **NFR-1:** TCP connection attempts used by readiness and Goose must be
  bounded to five seconds; a failed connection must not proceed to migration.
- **NFR-2:** The change must not weaken migration ordering, backup safeguards,
  or fail-closed provisioning behavior.
- **NFR-3:** Tests must be deterministic and must not require production
  credentials or a live deployment database.

## Acceptance criteria

- **AC-1:** Repository and driver evidence explains the difference between
  the successful MySQL-client preflights and Goose's failed authentication.
- **AC-2:** A regression test uses a non-secret fixture containing characters
  that the old DSN formatter encoded and proves Goose receives the original
  credential value.
- **AC-3:** Failed preflight still stops before backup or tenant provisioning,
  and logs contain no password or DSN.
- **AC-4:** Relevant README guidance describes the host-MySQL connection and
  the operator action for a failed migration check.
- **AC-5:** Focused validation passes, or any unavailable runtime check is
  explicitly recorded with its limitation.
- **AC-6:** The readiness clients and Goose connection have an explicit
  five-second TCP connection timeout.

## Compatibility

The deployment uses Dokku/containerized execution with MySQL on the host
machine. The existing tenant-provisioning interface and documented MySQL
environment names remain unchanged. The internal Goose DSN must follow the
driver's format; no backward-compatible fallback for an incorrect internal
encoding is requested.

## Assumptions, constraints, risks, and unknowns

### Assumptions

- The successful client preflight uses the configured host endpoint and
  password bytes from the deployment configuration.
- A five-second connection timeout follows the existing verifier's
  operational convention and is short enough for fail-fast setup checks.
- MySQL error 1045 in the report is an authentication rejection, not a DNS or
  network failure.
- The same configured password must be supported whether or not it contains
  punctuation or DSN-reserved characters.

### Constraints

- Do not alter host MySQL grants or secrets as part of this repository change.
- Use the authorized `abdulmohsenssda` GitHub identity for remote work; do not
  use `almaabd16` or `almaabd16_bhgithub`.
- Preserve secret hygiene in logs, tests, documentation, and PR content.

### Risks

- A local test environment may not reproduce Dokku-to-host routing or
  server-side `user@host` matching.
- The redacted production password prevents confirming whether this incident
  exercised one of the characters affected by the formatter; the code defect
  can still be reproduced with a safe test fixture.

### Research status

- **Resolved:** Goose's pinned MySQL driver treats DSN credentials literally;
  the current formatter percent-encodes them, while the client preflight
  passes them unchanged.
- **Resolved:** Current main already routes Goose and both client checks
  through the Docker bridge/host gateway and checks before backup.
- **Resolved:** The migration contract test and deployment README are the
  focused locations for regression coverage and operator guidance.
- **Resolved:** `gh auth status` reports `abdulmohsenssda` as the active
  GitHub identity for the deployment repository.
- **Remaining:** The redacted production password prevents confirming whether
  it contains a character transformed by the faulty formatter.
- **Remaining:** The local environment does not provide the production
  Dokku-to-host MySQL runtime for an authenticated rehearsal.
