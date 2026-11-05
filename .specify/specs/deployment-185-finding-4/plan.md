# Deployment #185 Finding #4 Plan

## Architecture and boundaries

Keep the deployment-side migration boundary in `scripts/lib.sh` and
`scripts/init-tenant-db.sh`. The backend image remains the owner of embedded
goose migrations and exposes `/app/migrate`; no compose migration service is
invented in this repository.

## Implementation phases

1. **Contract hardening:** reject unsupported `goose_run` subcommands before
   Docker execution; retain `up` and read-only `status`.
2. **Regression evidence:** extend existing shell tests for exact argv,
   create/update/fleet ordering, existing-data validation, and status-only
   behavior. Keep the rollback harness unchanged unless a gap is found.
3. **Documentation/status:** document the allow-listed command contract and
   record the remaining live-runtime gap.
4. **Validation:** run focused shell checks, dashboard migration Go tests,
   build/vet as practical, then inspect the final diff and artifact alignment.

## Data and failure behavior

- Migration runs as the tenant DB user with `HOST`, `DBNAME`, `DBUSER`, and
  `PASSWORD`.
- A verified backup precedes goose for backend create/update/fleet flows.
- Required existing tables and `company.tenant_key` are checked after goose.
- Migration failure prevents the backend image swap.
- Backend rollback remains explicitly confirmed and never runs goose.
- Unsupported helper commands fail before Docker is invoked.

## Compatibility

Valid callers continue to use `up` and `status`. Existing tenant databases
continue through goose and required-table/key checks; no migration is skipped
because data already exists.

## Validation strategy

- Shell syntax and focused contract scripts run without Docker, Dokku, MySQL,
  or a network.
- A stub Docker function captures every migration argv and confirms absence of
  removed aliases.
- Static line-order checks protect deployment sequencing.
- Go migration parsing tests remain the relevant dashboard check.
- Live migration, restore, and compose/runtime behavior remains unproven and
  must be stated in the final report.
