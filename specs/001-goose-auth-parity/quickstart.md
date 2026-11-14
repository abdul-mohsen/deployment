# Quickstart: Goose MySQL Authentication Parity

## Prerequisites

- Run from the deployment repository root in an environment with Bash.
- Do not use production database credentials for the contract tests.
- No live Dokku or MySQL server is required for the deterministic regression.

## Validate the regression

```bash
bash -n scripts/migrate-zatca-master.sh scripts/tests/test-migrate-zatca-master.sh
bash scripts/tests/test-migrate-zatca-master.sh
git diff --check
```

Expected result: the migration contract test passes, including the case that
verifies punctuation in a dummy password reaches Goose without transformation
and checks the five-second TCP connection bound. The existing failed-preflight
case must still prove that no backup is created.

## Deployment rehearsal limitation

A production-equivalent Dokku-to-host-MySQL authentication rehearsal is not
available in this local environment. Do not treat the stubbed contract test as
live database evidence; the deployed server must confirm the connection using
its protected configuration through the normal release process.
