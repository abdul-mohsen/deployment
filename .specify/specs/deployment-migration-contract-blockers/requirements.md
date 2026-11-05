# Deployment Migration and Chain-Owner Contract Blockers

## Problem

Reviewer feedback identifies deployment risks around backend migration
ownership, an existing bill-counter backfill, ambiguous adoption of existing
tenant databases, unsafe use of a `00008` down migration, and the final
chain-owner schema after `pkg/egschain` removal and goose `00005`. Deployment
must align with the backend image migration contract without reimplementing or
editing backend migrations.

## Goals

- Keep migration version ownership in the backend image's goose runner.
- Ensure existing-data backfills complete before a backend can start.
- Validate the final chain-owner schema contract for fresh and existing tenants
  using read-only metadata checks.
- Make fresh provisioning distinct from explicit existing-database adoption.
- Preserve forward-only rollback and reject destructive migration commands.
- Add deterministic deployment-side regression evidence.

## In scope

- `scripts/lib.sh`, `create-tenant.sh`, `init-tenant-db.sh`,
  `update-tenant.sh`, `deploy-all.sh`, and `rollback-tenant.sh`.
- Deployment shell tests and directly related README/requirements wording.
- Detection of an existing tenant database or master-registry row before fresh
  provisioning.

## Out of scope

- Editing backend migration files or backend application code.
- Reconstructing migration `00008`, its bill-counter SQL, or its `Down`
  implementation; the backend contract keeps its `Down` non-destructive.
- Live Docker, Dokku, MySQL, backup-restore, or registry operations.
- Changing the existing explicit backend rollback confirmation policy.

## Functional requirements

### FR-1 Version ownership and sequence

Deployment MUST NOT enumerate, require, or synthesize backend migration SQL or
version files. It MUST invoke the target image's supported goose `up`/`status`
contract. The backend migration sequence remains authoritative and retains
goose `00001`, `00005`, `00008`, and `00010`; deployment must not renumber,
remove, or replace those migrations.

### FR-2 Existing-data backfill ordering

Create, explicit adoption, update, and fleet backend deployment MUST run the
target image's schema migration before the backend image swap or startup. A
migration failure MUST prevent the swap and preserve restore-before-retry
guidance. This ordering is the deployment-side guarantee that an existing bill
counter backfill runs before application use.

### FR-2a Chain-owner schema contract

After goose completes, deployment MUST verify the chain-owner metadata required
by the ZATCA daemon: `branch_zatca_config` MUST contain `last_icv`,
`previous_invoice_hash`, and all four reservation columns
(`icv_reservation_key`, `icv_reservation_token`, `reserved_icv`,
`reservation_lease_expires_at`). The tenant schema MUST also expose
`zatca_submission` with the unique `(branch_id, invoice_icv)` key. Deployment
MUST read this metadata only; backend/ZATCA migrations own its DDL and runtime
writes.

### FR-3 Fresh versus adoption guard

Fresh tenant provisioning MUST refuse when the tenant database or master
registry entry already exists unless the operator supplies an explicit
`--adopt-existing` acknowledgement. The refusal MUST happen before Dokku app
creation or database mutation. Existing app reruns remain subject to the
existing `--update` guard.

### FR-4 Startup ordering

Provisioning MUST keep schema migration and required existing-data validation
before the backend image is deployed. User seeding may occur only after the
verified backend/frontend deployment path completes.

### FR-5 Rollback and migration-down guard

The deployment migration helper MUST reject `down` and every unsupported
subcommand before Docker execution. Backend rollback MUST remain image-only,
must not run goose, and must require the existing explicit schema-compatible
confirmation.

### FR-6 Evidence

Focused tests MUST cover version delegation, existing-data ordering, adoption
refusal/acknowledgement, startup ordering, and destructive/rollback guards.
Documentation MUST state the runtime evidence boundary.

## Non-functional requirements

- Preserve strict shell failure handling and fail closed before side effects.
- Escape database identifiers/values used in existence checks.
- Do not log credentials or store secrets in tests.
- Keep changes deployment-side and minimal.

## Acceptance criteria

1. A fresh create with an existing DB or registry entry is refused before
   Dokku/database mutation unless `--adopt-existing` is explicit.
2. The adoption path still runs goose and required schema/key validation before
   backend deployment; no migration bypass is introduced.
3. Deployment tests prove the target image owns migration sequence/backfill and
   the final chain-owner metadata is validated for fresh/existing flows.
4. `goose_run` rejects `down` before Docker and rollback tests prove no goose
   invocation.
5. Focused shell tests pass; existing unrelated worktree changes are not
   included in the commit.
6. The final report names the absence of live Docker/Dokku/MySQL evidence.

## Assumptions, risks, and unknowns

- The backend image remains the authoritative source of goose migrations and
  exposes `/app/migrate`.
- Backend/ZATCA ownership is confirmed: the ZATCA daemon `queue.SQLChain` owns
  runtime reservation/commit behavior; backend goose owns the contiguous
  `00001..00010` schema sequence, including `00005` reservation columns,
  `00008` idempotent bill-counter backfill, and `00010` submission chain keys.
- The SQL details are unavailable in this deployment repository; deployment
  must enforce ordering and read-only metadata presence, not duplicate SQL.
- An existing master row or database without the other is treated as ambiguous
  and requires explicit adoption.
- Deployment must not reference the removed `pkg/egschain` package or invent a
  replacement chain owner.
- Static/stub tests cannot prove a real backfill or startup race in production.
