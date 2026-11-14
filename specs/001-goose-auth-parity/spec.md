# Feature Specification: Goose MySQL Authentication Parity

**Feature Branch**: `fix/goose-dsn-auth-parity-20261114`

**Created**: 2026-11-14

**Status**: Draft

**Input**: Investigate and correct the ZATCA master migration failure where
MySQL client checks reach host-machine MySQL from the containerized Dokku
environment but Goose receives an authentication rejection. Keep provisioning
fail-closed and prepare a pull request using the authorized GitHub identity.

## User Scenarios & Testing

### User Story 1 - Provision a tenant with the configured host database (Priority: P1)

As a deployment operator, I need the migration runner to authenticate to the
host database with the configured credentials so that tenant provisioning
works whenever those credentials are valid.

**Why this priority**: The master migration is a prerequisite for tenant
creation, and a mismatch between the readiness check and migration prevents
all new tenant provisioning.

**Independent Test**: Run the migration contract test with a dummy password
containing punctuation and verify the configured value reaches the migration
runner unchanged.

**Acceptance Scenarios**:

1. **Given** the host database accepts the configured account and password,
   **When** tenant provisioning starts the master migration, **Then** the
   migration runner authenticates with the same effective credentials and
   connection endpoint as the readiness checks.
2. **Given** the host database rejects the configured account or cannot be
   reached, **When** migration readiness runs, **Then** provisioning stops
   before a backup, schema change, or tenant creation.

### User Story 2 - Diagnose a failed database check (Priority: P2)

As a deployment operator, I need an actionable and secret-safe failure message
so that I can distinguish a connection problem from rejected credentials and
correct the deployment configuration.

**Why this priority**: Clear failure context avoids repeated provisioning
attempts and unsafe changes to database grants or network settings.

**Independent Test**: Simulate an authentication failure and a connection
failure, then verify each is classified and the configured password is absent
from output.

**Acceptance Scenarios**:

1. **Given** the database rejects authentication, **When** readiness fails,
   **Then** the operator sees an authentication category and safe connection
   context without a password or credential-bearing connection string.
2. **Given** the database cannot be reached, **When** readiness fails,
   **Then** the operator sees a connection category and provisioning stops
   before migration side effects.

### Edge Cases

- The configured username or password contains punctuation that a generic URL
  encoder would transform.
- The database is on the host machine and the migration executes from a Docker
  bridge container.
- The ordinary MySQL-client check succeeds but the migration runner receives
  a different credential representation.
- The database rejects credentials after the network connection itself
  succeeds.

## Requirements

### Functional Requirements

- **FR-001**: The deployment readiness check and migration runner MUST use the
  same effective database host, port, database, user, and credential source.
- **FR-002**: The migration runner MUST receive the configured username and
  password in the format expected by its database connection interface,
  without altering the credential values.
- **FR-003**: A failed connectivity or authentication check MUST stop tenant
  provisioning before backup or schema changes.
- **FR-004**: Failure output MUST identify safe connection context and the
  failure category, and MUST NOT include a password or credential-bearing
  connection string.
- **FR-005**: The documented tenant-provisioning command and MySQL environment
  names MUST remain unchanged.
- **FR-006**: Readiness and migration TCP connection attempts MUST be bounded
  to five seconds and MUST stop promptly when the host database cannot be
  reached.

### Key Entities

- **Database connection configuration**: The operator-owned host, port,
  database, username, and secret used by deployment operations.
- **Migration readiness result**: The success or safe failure classification
  produced before migration side effects.
- **Master migration ledger**: The existing record of applied master
  migrations; this feature does not change its schema.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Every added credential fixture containing punctuation reaches
  the migration runner with the same value configured by the operator.
- **SC-002**: All simulated connection and authentication failures stop before
  backup or tenant provisioning.
- **SC-003**: No regression-test output contains the dummy password or a
  credential-bearing connection string.
- **SC-004**: Operators can distinguish connection failures from
  authentication failures using the reported category and safe context.
- **SC-005**: Readiness and migration connection paths use a five-second
  connection bound, so an unreachable host cannot stall provisioning.

## Assumptions

- Dokku/containerized deployment reaches the host database through the
  configured host endpoint, as demonstrated by the successful client checks.
- Existing deployment credentials and command-line arguments remain the
  authoritative interface.
- The production password remains private; regression cases use only dummy
  values.
