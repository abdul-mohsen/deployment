# Research: Deployment Migration Contract Blockers

## Baseline

- Current branch is `fix/pr185-migration-safety-92ee2c7`, clean before this
  task, with prior local fix `0fbcf696` and audit-rollback follow-up
  `92ee2c7`.
- The deployment repository contains no backend migration files and no
  compose migration service. The deployment contract is the backend image's
  `/app/migrate`.
- Existing prior work already restricts `goose_run` to `up` and `status`,
  runs goose before backend swaps, and refuses automatic post-migration image
  rollback.

## Findings

### Migration sequence and bill-counter backfill

No backend migration files are present in this repository. Backend-agent
confirmation says the authoritative goose sequence remains contiguous
`00001..00010`: `00001` owns `last_icv`/`previous_invoice_hash`, `00005`
owns branch reservation columns, `00008` is an idempotent bill-counter
backfill, and `00010` owns `zatca_submission` chain columns/unique keys.
Deployment must not recreate this SQL. The safe boundary is to execute goose
`up` from the exact target backend image and validate final metadata before
startup. Existing `init-tenant-db.sh` already runs `ensure_tenant_database`,
goose, required-table validation, and tenant-key propagation before callers
deploy the image.

### Chain-owner ownership confirmation

ZATCA-agent confirmation says the ZATCA daemon's `queue.SQLChain` is the single
runtime chain owner. It locks and updates `branch_zatca_config` fields
`last_icv`, `previous_invoice_hash`, `icv_reservation_key`,
`icv_reservation_token`, `reserved_icv`, and
`reservation_lease_expires_at`. It owns `zatca_submission` chain records and
the chain/outcome/signed-XML columns, `zatca_consumer_claim` claim fields, and
the unique `uq_zatca_invoice_chain`, `uq_zatca_bill`, and
`uq_zatca_invoice_uuid` constraints. Deployment must not write these fields or
reproduce their SQL. It can validate their presence through `information_schema`
after goose for fresh and existing tenants.

### Existing-database adoption

`create-tenant.sh` currently uses `CREATE DATABASE IF NOT EXISTS` and an
`ON DUPLICATE KEY UPDATE enabled=1` master insert. Its `--update` flag only
guards existing Dokku apps and does not explicitly acknowledge an existing
database or registry row. This permits ambiguous adoption of data that may
belong to another provisioning attempt.

The deployment account can safely read:

- `information_schema.schemata` for tenant database existence;
- the master `tenant` table for a matching tenant name or database name.

These checks belong before Dokku app creation and before `CREATE DATABASE` or
master-row mutation. A new `--adopt-existing` flag is the smallest explicit
operator acknowledgement. The existing app `--update` guard remains
independent.

### Startup ordering

`create-tenant.sh`, `update-tenant.sh`, and `deploy-all.sh` all call
`init-tenant-db.sh --schema-only` before their backend image swap. Create
configures apps with `--no-restart` and deploys images only after migration.
Tests should make this contract explicit for adoption and existing-data
backfill rather than relying on the backend migration filename.

### Destructive down and rollback

`goose_run` already has an allow-list, so `down` is rejected before Docker.
`rollback-tenant.sh` requires `--confirm-schema-compatible` for backend image
rollback and does not call the migration initializer. The missing evidence is
an explicit `down` regression, a contract check that no deployment script
references `pkg/egschain`, and a read-only final chain schema check.

## Decision

Implement a deployment-only adoption guard and database/registry existence
helpers. Add read-only chain-owner metadata validation after goose. Keep goose
version/backfill behavior and all chain DDL in the backend image/ZATCA-owned
code. Expand focused shell contracts for version delegation, ownership,
adoption, startup ordering, and destructive rollback protection. Do not edit
backend code or invent migration SQL.

## Remaining uncertainty

Only a live backend image and tenant database can prove that the bill-counter
backfill succeeds on existing data and that the full goose ledger is compatible
with a pre-existing tenant. Repository tests can prove the deployment boundary,
ownership assumptions, metadata checks, and refusal behavior only.
