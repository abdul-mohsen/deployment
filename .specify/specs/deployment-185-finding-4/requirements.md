# Deployment #185 Finding #4: Migration Safety Evidence

## Problem

The deployment branch now uses the backend image's goose runner for tenant
schema work and has removed legacy migration-validation paths. Reviewer finding
#4 requires evidence that the remaining deployment paths still protect tenant
data and preserve the forward-only schema rule.

## Goals

- Prove, with focused repository checks, that tenant creation and upgrades run
  the target backend migration command before an image swap.
- Prove that migration failure prevents an unsafe image deployment.
- Prove that backend rollback remains guarded and never attempts a schema
  rollback.
- Prove that existing tenant data remains compatible with the new migration
  entry point and required base-schema checks.
- Prove the exact environment and command contract consumed by the backend
  migration binary.

## In scope

- `scripts/init-tenant-db.sh` and its goose/tenant-database contract.
- `scripts/update-tenant.sh`, `scripts/deploy-all.sh`, and
  `scripts/create-tenant.sh` migration ordering and failure guards.
- `scripts/rollback-tenant.sh` rollback refusal and explicit confirmation.
- Focused shell regression tests and directly related deployment documentation.

## Out of scope

- Running a live production migration, Dokku deployment, or database restore.
- Changing migration ordering, rollback policy, or the backend migration
  implementation.
- GitHub, registry, or remote deployment operations.
- Reintroducing legacy SQL-copy, Atlas, migration bypass, or privileged
  validation paths.

## Functional requirements

### FR-1 Tenant migration path

For a backend image deployment, the target image's migration runner must be
invoked before the backend image swap, after a verified pre-migration backup.
The test contract must fail if the order changes or the migration step is
removed.

### FR-2 Upgrade failure safety

A failed goose migration must stop the upgrade before the target backend image
is deployed and must preserve an actionable restore-before-retry diagnostic.
The check must cover both single-tenant update and fleet deployment paths.

### FR-3 Rollback guard

Backend rollback must be refused before any Dokku or migration command unless
the operator supplies the existing explicit schema-compatibility confirmation.
When confirmed, rollback must swap only the image and must not run goose.

### FR-4 Existing-data compatibility

The migration entry point must operate against an existing tenant database using
the tenant account, must verify required base tables after migration, and must
set the registry tenant key without generating a replacement key. Tests must
cover the existing-data/read-only compatibility contract without requiring a
live database.

### FR-5 Exact backend migration command

The deployment helper must invoke exactly `/app/migrate` with the supported
`up` or `status` subcommand and the backend binary's exact environment names:
`HOST=host:port`, `DBNAME`, `DBUSER`, and `PASSWORD`. It must not pass removed
`DATABASE_URL` or `DB_*` aliases.

### FR-6 Validation and evidence

Focused shell tests and relevant Go tests must pass. The final report must
distinguish repository-level proof from the remaining live-runtime evidence
gap.

## Non-functional requirements

- Preserve `set -euo pipefail` and existing failure-closed behavior.
- Do not weaken schema-forward-only rollback rules.
- Tests must be deterministic and runnable without Docker, Dokku, MySQL, or
  network access unless an existing test explicitly uses a stub.
- Changes must be minimal and limited to the target worktree.

## Acceptance criteria

1. A focused migration/deployment test covers backup → migration → image-swap
   ordering and failed-migration refusal for tenant update and fleet paths.
2. A focused rollback test covers refusal before side effects and confirmed
   image-only rollback without goose.
3. A focused existing-data compatibility test covers tenant-account goose
   execution, required-table validation, and registry tenant-key propagation.
4. A focused command-contract test asserts `/app/migrate`, `up`/`status`, and
   the exact four backend environment names while rejecting legacy aliases.
5. All focused shell checks and relevant dashboard Go tests pass.
6. No migration or rollback rule is weakened, and the final report names any
   unproven live-runtime behavior.

## Assumptions, risks, and unknowns

- Assumption: the backend image remains the owner of embedded goose migrations
  and exposes `/app/migrate`; this must be verified against the current
  deployment templates and helper.
- Assumption: existing shell tests are the preferred regression surface for
  deployment scripts.
- Risk: static tests can prove command construction and ordering but cannot
  prove a real Docker/Dokku/MySQL migration or restore.
- Risk: tests that copy scripts into a stub directory can accidentally mask
  path or environment differences; retain exact argument assertions.
- Unknown: whether the reviewer expects a compose service in the backend app
  repository or the deployment-side `/app/migrate` container contract. Resolve
  from current repository evidence before implementation; do not invent a
  compose migration path.
- Unknown: whether existing-data compatibility has a live fixture available.
  If not, record the live fixture/runtime gap rather than weakening checks.
