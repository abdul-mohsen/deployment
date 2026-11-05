# Research: Deployment #185 Finding #4

## Repository baseline

- The target worktree is clean on `feat/dp1-goose-migrate-6` at commit
  `3f4127f`.
- Recent branch history shows the migration path was changed to goose, the
  legacy `--skip-migrations` path was removed, and backend rollback was changed
  to require `--confirm-schema-compatible` without running goose.
- The worktree contains no deployment-owned schema/migration directory and no
  compose migration service definition. The deployment-side contract is the
  backend image's `/app/migrate` executable.

## Current migration contract

`scripts/lib.sh` defines `goose_run <image> <up|status> <host> <port> <db>
<user> <password>`. It runs:

```text
docker run --rm --add-host=host.docker.internal:host-gateway
  -e HOST=<host>:<port>
  -e DBNAME=<db>
  -e DBUSER=<user>
  -e PASSWORD=<password>
  --entrypoint /app/migrate <image> <up|status>
```

The backend template builds and copies `/app/migrate` from `./cmd/migrate`.
Existing tests already reject `DATABASE_URL` and `DB_*` migration aliases, but
they do not assert the complete argv sequence for both supported subcommands or
reject an unsupported subcommand before Docker is called.

## Deployment path evidence

- `scripts/create-tenant.sh` takes a verified database backup, calls
  `init-tenant-db.sh <tenant> --schema-only --backend-image <image>`, and only
  later deploys the verified backend component.
- `scripts/update-tenant.sh` takes a verified backup, calls the same schema-only
  initializer, sets `MIGRATIONS_APPLIED`, and deploys the backend afterward.
  Migration failure records failure and exits before the swap.
- `scripts/deploy-all.sh` repeats the backup → schema-only initializer →
  `deploy_one` ordering for each backend tenant and refuses to continue when
  migration fails.
- `scripts/rollback-tenant.sh` refuses backend rollback before any Dokku call
  unless `--confirm-schema-compatible` is supplied. Confirmed rollback calls
  only `dokku_git_from_image`; it does not call the migration initializer.
- `scripts/init-tenant-db.sh` applies goose before `validate_tenant_schema` and
  `ensure_company_tenant_key`. The required existing-data tables are
  `company`, `branches`, `store`, and `user`. The company tenant key is copied
  from the master registry and updated with `WHERE id = 1`; it is not
  generated.

## Existing test coverage and gaps

Existing focused tests cover:

- basic goose environment names and `/app/migrate` entrypoint;
- dry-run migration planning;
- update/fleet static migration ordering;
- backend rollback refusal and confirmed image-only rollback;
- migration-status JSON parsing and failure reporting;
- the absence of legacy SQL-copy/Atlas/admin-trigger migration paths.

The reviewer finding is not fully proven because:

1. create-tenant ordering is not covered alongside update/fleet ordering;
2. existing-data validation order and status-only read-only behavior are only
   partially asserted;
3. the goose helper test checks individual arguments but not an exact argv
   contract for both `up` and `status`;
4. unsupported migration subcommands were not rejected by the helper itself.

## Decision

Keep the current backend-image migration architecture. Do not invent a compose
service in this deployment repository or restore removed legacy validation
paths. Strengthen `goose_run` with an allow-list for the two commands used by
the deployment (`up` and read-only `status`) and add deterministic shell
regressions for the identified gaps. This design was implemented without
changing migration ordering or rollback behavior.

## Runtime evidence boundary

The repository tests can prove script ordering, command construction, failure
guards, and compatibility checks using stubs. They cannot prove a real
Docker/Dokku/MySQL migration against an existing tenant database, a backup
restore, or an end-to-end compose/runtime image. That remains an explicit
runtime evidence gap.
