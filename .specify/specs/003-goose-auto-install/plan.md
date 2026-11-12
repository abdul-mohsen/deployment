# Implementation Plan: Automatic Goose acquisition

1. Add source-pinned release metadata, platform detection, cache resolution,
   verified download, and atomic installation to
   `scripts/migrate-zatca-master.sh`.
2. Extend the existing offline shell contract test with download, cache reuse,
   and checksum-failure cases.
3. Document the optional `ZATCA_MASTER_GOOSE_CACHE_DIR` override and the
   precedence rules in `config.env.example` and `README.md`.
4. Run syntax checks, focused tests, diff validation, convergence, and
   self-review.

## Current status

- Implementation, focused tests, documentation, and self-review are complete.
- The repository-wide suite is environment/baseline blocked because Go is not
  available and unrelated tests require missing MySQL/Compose fixtures.
- The follow-up PR is pending creation; designated QA approval remains open.
