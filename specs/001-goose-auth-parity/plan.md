# Implementation Plan: Goose MySQL Authentication Parity

**Branch**: `fix/goose-dsn-auth-parity-20261114` | **Date**: 2026-11-14 |
**Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-goose-auth-parity/spec.md`

## Summary

The deployment MySQL checks pass the configured password literally, but the
Goose DSN formatter percent-encodes credential characters that the pinned Go
MySQL driver does not decode. Remove that transformation, add a focused
special-character regression test, and document the verified host-MySQL
credential behavior without changing routing, grants, or command interfaces.
Also bound TCP connection attempts to five seconds using the deployment's
existing preflight convention.

## Technical Context

**Language/Version**: Bash for deployment orchestration; Goose v3.30.0 is a
verified Linux binary.

**Primary Dependencies**: Shared `scripts/lib.sh` MySQL helpers, Docker bridge
network, Goose's MySQL driver.

**Storage**: Existing host MySQL database `zatca_master`; no schema changes.

**Testing**: `scripts/tests/test-migrate-zatca-master.sh`, `bash -n`, and
`git diff --check`.

**Target Platform**: Linux deployment host with Docker/Dokku and host-machine
MySQL.

**Project Type**: Deployment shell scripts and operational documentation.

**Performance Goals**: No new database calls, retries, or provisioning delay.

**Constraints**: Preserve fail-fast ordering, backup safeguards, existing
environment names, and secret hygiene. The production credential is
unavailable and must not be read. Bound readiness and Goose TCP connection
attempts to five seconds without setting query/read timeouts.

**Scale/Scope**: One DSN construction helper, its focused contract test, and
the deployment README.

## Constitution Check

- **Contract ownership**: Deployment owns this migration orchestration; no
  backend or ZATCA migration SQL is changed.
- **Secret hygiene**: Use only dummy test credentials; do not log the password
  or DSN.
- **Evidence-driven testing**: Add a regression test that fails on the current
  encoded representation and passes for literal driver credentials.
- **Reversible delivery**: No database state or schema changes are introduced.
- **Compatibility**: Keep existing documented MySQL environment names and
  tenant command interface; no legacy DSN fallback is added.

**Gate**: Pass. The change remains within the deployment boundary and does
not violate the shared Afrita constitution.

## Project Structure

### Documentation (this feature)

```text
specs/001-goose-auth-parity/
├── requirements.md
├── research.md
├── spec.md
├── design.md
├── plan.md
├── data-model.md
├── quickstart.md
├── tasks.md
├── STATUS.md
└── checklists/
    ├── requirements.md
    └── database.md
```

### Source Code

```text
scripts/
├── migrate-zatca-master.sh
└── tests/
    └── test-migrate-zatca-master.sh
README.md
```

**Structure Decision**: Keep the fix in the existing migration script and
contract test. Update the root deployment README because it documents
host-MySQL prerequisites and configuration. No new runtime module or public
interface is needed.

## Complexity Tracking

No constitution violations or additional architectural components.
