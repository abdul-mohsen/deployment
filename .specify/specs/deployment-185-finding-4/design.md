# Design: Deployment #185 Finding #4

## Approach

Retain the existing forward-only migration flow and make the smallest
contract-strengthening change:

1. Restrict the shared `goose_run` helper to the two intentional commands,
   `up` and `status`, before invoking Docker.
2. Expand existing shell contract tests instead of adding a new test harness
   or live dependency.
3. Document that the deployment control plane owns the command allow-list and
   that runtime migration/restore evidence still requires a real environment.

## Component boundaries

- `scripts/lib.sh`: validates the migration subcommand and constructs the
  backend image invocation.
- `scripts/init-tenant-db.sh`: remains the single tenant schema entry point;
  no ordering or database mutation behavior changes.
- `scripts/create-tenant.sh`, `scripts/update-tenant.sh`, and
  `scripts/deploy-all.sh`: remain responsible for backup-before-migration and
  migration-before-swap ordering.
- `scripts/rollback-tenant.sh`: remains schema-forward-only and never invokes
  goose.
- `scripts/tests/test-lib.sh`: exact argv and unsupported-command regression.
- `scripts/tests/test-init-tenant-db.sh` and
  `scripts/tests/test-tenant-migration-deploy.sh`: existing-data and
  create/update/fleet ordering regressions.
- `scripts/tests/test-rollback-tenant.sh`: existing side-effect guard
  regression, retained as the rollback proof.

## Failure handling

An unsupported `goose_run` command returns non-zero before Docker is called.
Existing callers (`apply_schema` and `show_migration_status`) continue to use
`up` and `status`, so valid behavior is unchanged. Existing migration failures
continue to fail closed before image swaps; rollback still refuses automatic
schema rollback.

## Existing-data compatibility

The test contract asserts that:

- `goose_run ... up` precedes required-table validation;
- required table names remain present;
- registry `tenant_key` is read and written to company row 1 with a `WHERE`
  clause;
- `--status` exits through the read-only status path before schema application;
- no legacy SQL-file copying or privileged migration bypass is reintroduced.

## Test strategy

- Use shell stubs already established by the repository to capture Docker argv
  without Docker or MySQL.
- Use line-order assertions for each deployment path; assert the migration
  command includes `--backend-image`.
- Keep the rollback harness asserting no Dokku/goose side effects on refusal
  and no goose invocation on confirmed rollback.
- Run focused shell tests first, then dashboard Go migration tests and the
  relevant build/vet checks if time permits.

## Requirement traceability

| Requirement | Design evidence |
|---|---|
| FR-1 | create/update/fleet order assertions |
| FR-2 | migration failure-before-swap assertions and existing failure-closed code |
| FR-3 | rollback harness and no-goose static check |
| FR-4 | existing-data ordering, required-table, tenant-key, and status assertions |
| FR-5 | exact `goose_run` argv tests plus command allow-list |
| FR-6 | focused shell/Go validation and explicit runtime-gap report |

## Rollout and rollback

This is a deployment-script safety hardening and test-only evidence change.
The new helper validation is backward-compatible for current callers. If a
future caller needs another migration operation, it must explicitly update the
allow-list and its tests; arbitrary commands are not accepted implicitly.
