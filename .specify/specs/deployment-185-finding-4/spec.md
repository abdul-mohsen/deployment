# Deployment #185 Finding #4 Specification

## Overview

This feature closes reviewer finding #4 by proving that the deployment
repository's goose-based tenant migration path remains safe after legacy
validation paths were removed. The work is limited to focused safety
hardening and deterministic regression evidence.

## User stories

### US-1 — Operator upgrades a tenant safely

As an operator, I need a verified backup and successful target-image migration
before an upgraded backend is swapped in, so a failed migration cannot leave a
new binary running against an incompatible schema.

### US-2 — Operator rolls back without undoing schema accidentally

As an operator, I need backend rollback to stop before side effects unless I
explicitly confirm schema compatibility, so an image rollback cannot be
mistaken for a database rollback.

### US-3 — Existing tenants remain compatible

As an operator, I need the target image migration to run using the tenant
database account and validate required existing tables and the registry
tenant key, so existing data is not treated as migration-free or silently
reinitialized.

## Functional requirements

- **FR-1:** Backend create, update, and fleet deployment paths MUST preserve
  verified-backup → target-image migration → image-swap ordering.
- **FR-2:** Migration failure MUST stop deployment before the target backend
  image swap and preserve restore-before-retry diagnostics.
- **FR-3:** Backend rollback MUST be refused before Dokku/goose side effects
  without `--confirm-schema-compatible`; confirmed rollback MUST be image-only.
- **FR-4:** Existing-data checks MUST retain required-table validation and
  registry tenant-key propagation after goose completes; status mode MUST be
  read-only.
- **FR-5:** The migration helper MUST invoke `/app/migrate` with only
  `HOST=host:port`, `DBNAME`, `DBUSER`, and `PASSWORD`, and only `up` or
  `status`.
- **FR-6:** Focused shell and relevant Go tests MUST pass, with live-runtime
  evidence gaps explicitly reported.

## Edge cases

- A backend image is unavailable or lacks the migration runner.
- The tenant already has data and all required base tables.
- A migration fails after the backup but before the image swap.
- A frontend component fails after backend migration; automatic backend
  rollback remains refused.
- A caller attempts an unsupported migration subcommand.
- The operator requests status while the migration ledger is unavailable.

## Success criteria

- SC-1: Focused shell tests detect any ordering regression in create, update,
  or fleet backend deployment.
- SC-2: Focused tests detect any rollback side effect before confirmation or
  any goose invocation during confirmed rollback.
- SC-3: Focused tests assert existing-data table/key validation order and
  read-only status behavior.
- SC-4: Focused tests compare the exact `/app/migrate` argv/environment for
  both supported subcommands and reject unsupported commands.
- SC-5: Focused checks and relevant dashboard Go tests pass without live
  infrastructure.
- SC-6: Final review distinguishes repository proof from live Docker/Dokku/
  MySQL/restore evidence.

## Constraints

- Work only in the specified deployment worktree.
- Do not push, call GitHub write APIs, or change remote state.
- Do not weaken migration ordering, backups, or rollback guards.
- Do not restore legacy SQL-copy, Atlas, or migration-bypass behavior.
