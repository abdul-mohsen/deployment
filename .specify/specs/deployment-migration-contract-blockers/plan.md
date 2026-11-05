# Plan: Deployment Migration Contract Blockers

## Phase 1 — Guard implementation

1. Add escaped, read-only DB/registry existence helpers to `lib.sh`.
2. Add `--adopt-existing` parsing, help text, and fail-closed preflight to
   `create-tenant.sh`.
3. Add read-only chain-owner schema validation after goose; do not add DDL.
4. Keep existing goose and rollback semantics unchanged.

## Phase 2 — Regression evidence

1. Test existence helper outcomes with stubbed MySQL.
2. Test create fresh-only refusal and explicit adoption.
3. Test migration-before-start/backfill ordering for create, update, and fleet.
4. Test chain-owner metadata and the no-`pkg/egschain` ownership boundary.
5. Test no destructive `down`.

## Phase 3 — Documentation and validation

1. Update README and deployment requirements with the adoption contract.
2. Run focused shell tests with normalized copies where Windows CRLF prevents
   direct Bash execution.
3. Run relevant dashboard Go tests/vet if unchanged code paths are affected.
4. Review the diff and preserve unrelated worktree changes.

## Constraints

- No backend repository or migration SQL changes.
- No remote/GitHub writes or pushes.
- No weakening of backup, migration, or rollback guards.
- The previous cleanup intentionally removed the old feature Markdown and
  constitution; this new feature directory is scoped only to the new blockers.
