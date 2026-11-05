<!--
Sync Impact Report
Version change: template scaffold -> 1.0.0
Modified principles: placeholder principles -> deployment safety, single-source
migrations, testable contracts, fail-closed operations, and scoped changes
Added sections: Operational and Security Constraints; Development Workflow and
Quality Gates
Removed sections: unresolved template placeholders
Follow-up TODOs: none
-->

# Ifritah Deployment Constitution

## Core Principles

### I. Forward-Only Migration Safety

Database schema changes MUST run forward-only from the target backend image
before its image is swapped. A verified pre-migration backup MUST exist before
the migration starts. Backend rollback MUST remain explicitly guarded because
an image swap cannot undo schema or data changes.

### II. Single-Source Migration Contract

The backend image owns tenant migrations through `/app/migrate`. Deployment
MUST pass only the backend binary's documented environment names and supported
subcommands, and MUST NOT reintroduce copied SQL files, Atlas paths, migration
bypasses, or privileged validation workarounds.

### III. Testable Operational Contracts

Every change to migration, upgrade, rollback, backup, or deployment ordering
MUST have a deterministic focused regression check. Contract tests MUST assert
observable command arguments, ordering, and side-effect boundaries using
stubs where live infrastructure is unavailable.

### IV. Fail-Closed and Observable Operations

Deployment scripts MUST preserve strict shell failure handling, refuse unsafe
or untracked operations before side effects, and emit actionable bounded
diagnostics without exposing credentials. A static or stubbed test MUST NOT be
reported as proof of live Docker, Dokku, MySQL, or restore behavior.

### V. Minimal, Scoped Changes

Changes MUST stay within the requested worktree and feature scope, preserve
existing migration and rollback rules, update directly related documentation,
and avoid remote or GitHub writes unless explicitly requested.

## Operational and Security Constraints

- Tenant migrations run as the tenant database account; deployment-owned
  administrative credentials are not passed to the backend migration binary.
- Secrets MUST NOT be written to source, tests, logs, artifacts, or reports.
- Existing tenant data compatibility MUST be validated through required-table
  and registry-key checks before a deployed backend is considered ready.
- Runtime evidence gaps MUST be recorded explicitly instead of being hidden by
  weaker tests or permissive fallbacks.

## Development Workflow and Quality Gates

- Complex work MUST follow Specify, Research, Plan, Tasks, Analyze, Implement,
  Converge, and Self-review with reviewable artifacts.
- Implementation MUST be preceded by requirements, design, and dependency-
  ordered tasks; status MUST identify completed, active, blocked, backlog,
  risks, and next actions.
- Focused shell checks MUST run before broader build, vet, or Go test checks.
- Before completion, review the final diff, documentation, artifact
  consistency, requirement coverage, and any remaining runtime evidence gap.

## Governance

This constitution governs deployment work in this repository. Amendments MUST
state the changed principle, rationale, version impact, and affected
validation. Every implementation review MUST verify compliance with the
forward-only migration, fail-closed, secret-handling, and scoped-change rules.
If a requested change conflicts with a MUST rule, the conflict MUST be resolved
through an explicit constitution amendment before implementation.

**Version**: 1.0.0 | **Ratified**: 2026-11-05 | **Last Amended**: 2026-11-05
