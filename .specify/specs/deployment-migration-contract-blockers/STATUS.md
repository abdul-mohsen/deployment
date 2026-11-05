# STATUS

## Completed

- [x] Requirements, research, design, plan, and dependency tasks created.
- [x] Existing backend-image goose boundary and current deployment ordering
  inspected.
- [x] Backend/ZATCA findings coordinated: backend goose retains `00001..00010`
  including `00005`, `00008`, and `00010`; ZATCA `queue.SQLChain` owns runtime
  chain reservation/commit behavior.
- [x] Added read-only validation for branch chain/reservation columns,
  `zatca_submission` fields and unique keys, and `zatca_consumer_claim` fields.
- [x] Added explicit fresh/adoption guard and ownership/order/destructive
  migration regressions.
- [x] README and REQUIREMENTS document backend goose/ZATCA ownership.
- [x] Previous unrelated branch commit `92ee2c7` and current clean baseline
  preserved.

## In Progress

- Finalizing validation evidence and preparing a local deployment-only commit.

## Blocked

- None identified.

## Backlog

- Commit only this task's files; do not alter unrelated history.

## Risks

- The actual `00008` and bill-counter SQL are not in this repository; only
  backend-image goose execution can validate them at runtime.
- The final chain-owner columns and unique key are backend goose/ZATCA-owned;
  deployment must fail closed on missing metadata but never repair it with SQL.
- Existing shell files use CRLF in this Windows checkout; normalized validation
  may be required.
- Current branch may receive unrelated edits while this work proceeds; preserve
  anything outside this task's explicit scope.

## Next Actions

- Commit the scoped deployment changes after final status/diff review; preserve
  any unrelated worktree edits.
