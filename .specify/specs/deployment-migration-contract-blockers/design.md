# Design: Deployment Migration Contract Blockers

## Components

- `scripts/lib.sh`: add read-only helpers for tenant database and master
  registry existence checks; retain the goose command allow-list and add
  read-only chain-owner metadata validation.
- `scripts/create-tenant.sh`: add explicit `--adopt-existing`; refuse
  ambiguous existing DB/registry state before Dokku or database mutation.
- `scripts/tests/test-create-tenant.sh`: assert the guard and explicit flag.
- `scripts/tests/test-tenant-migration-deploy.sh`: assert target-image
  migration ordering, version delegation, and adoption/startup contracts.
- `scripts/tests/test-lib.sh` and `test-rollback-tenant.sh`: cover `down`
  refusal and no-goose rollback behavior.
- `README.md`/`REQUIREMENTS.md`: document fresh provisioning versus adoption
  and backend-owned migration versions.

## Data flow

1. Create validates tenant name and required images.
2. If database provisioning is enabled, the deployment account checks the
   tenant schema name and master registry for existing state.
3. Existing state without `--adopt-existing` fails before app creation,
   `CREATE DATABASE`, or master-row mutation.
4. Explicit adoption continues through the existing backup → goose `up` →
   required-table/key and chain-owner metadata validation → backend image
   deployment sequence.
5. Update/fleet paths remain unchanged and continue to run goose before swaps.
6. Rollback remains image-only and explicit; no goose `down` is possible.

## Failure handling

- Query failure while detecting existing state is a hard failure.
- A partial existing state (DB without registry or registry without DB) is
  still treated as existing and requires explicit adoption.
- Missing chain-owner columns, consumer-claim fields, or any of the three
  submission unique keys is a hard failure after goose; deployment never
  repairs them with SQL.
- Migration failure remains fail-closed and retains backup restore guidance.
- Unsupported goose commands return non-zero before Docker.

## Compatibility

Fresh tenants with no DB or registry row behave as before. Existing
reprovisioning must add `--adopt-existing`; existing app reruns still require
`--update`. Update/deploy-all/rollback command interfaces remain unchanged.

## Test strategy

- Stub `run_mysql` to exercise existence helpers without live MySQL.
- Use static order assertions for create, update, and fleet deployment.
- Assert `branch_zatca_config` reservation/chain columns and
  `zatca_submission` chain/outcome/signed-XML columns, its three unique keys,
  and `zatca_consumer_claim` fields through read-only metadata contract checks.
- Assert no `pkg/egschain` references or deployment-owned chain SQL exists.
- Capture goose argv and assert `down` does not reach Docker.
- Keep tests deterministic and avoid backend migration SQL duplication.

## Traceability

| Requirement | Design evidence |
|---|---|
| FR-1 | Backend-owned goose sequence; target-image contract |
| FR-2 | Existing create/update/fleet order assertions |
| FR-2a | Read-only chain-owner metadata validation after goose |
| FR-3 | DB/registry helpers and create adoption guard |
| FR-4 | Create migration-before-deploy and seed-after-deploy checks |
| FR-5 | Goose allow-list and rollback no-goose tests |
| FR-6 | Focused shell contracts and runtime-gap report |
