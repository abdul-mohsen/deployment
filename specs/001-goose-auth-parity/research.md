# Research: Goose Host-MySQL Migration Authentication Parity

## Repository baseline and scope

- The deployment repository is the bare repo at
  `C:\ssda\chatGPT\ifritah\deployment.git`.
- The prior local ZATCA migration worktree was stale (`fix/zatca-master-auto-migration`,
  commit `5560a48`) and did not contain the code shown in the operator log.
- A new worktree was created from refreshed `origin/main` at `9d81cef`
  (`fix(deployment): use MySQL image for preflight (#252)`). All implementation
  work will stay in that worktree.
- Current main already contains the bridge-network change and the two
  pre-migration MySQL-client checks. PR #250 corrected a source-host mismatch;
  PRs #251 and #252 added/fixed the checks. The reported failure occurs after
  these changes, so repeating the host-gateway or helper-image fixes would not
  address the remaining discrepancy.

## Findings

### Credential handling differs between the client checks and Goose

1. `scripts/lib.sh` resolves the same admin username/password for deployment
   operations. `run_mysql` supplies the password as `MYSQL_PWD`, without
   transforming the value.
2. `scripts/migrate-zatca-master.sh` builds Goose's DSN in `goose_dsn()`.
   Before inserting the username and password into
   `user:password@tcp(host:port)/database`, `mysql_dsn_escape()` percent-encodes
   `%`, `/`, `@`, `:`, `?`, `#`, and `;`.
3. `preflight_mysql_connection()` runs the MySQL command-line client with
   `MYSQL_PWD` both through the deployment helper and, when configured, from
   the Goose bridge network. It does not parse or use Goose's DSN.
4. `goose_run_in_bridge()` passes the DSN to Goose in the bridge container.
   The bridge host mapping and database endpoint match the successful client
   check, but the credential representation does not.
5. Pressly Goose v3.30.0 pins `github.com/go-sql-driver/mysql` v1.10.1.
   That driver's `dsn.go` writes `Config.Passwd` directly in `FormatDSN` and
   assigns the password substring directly in `ParseDSN`; it does not
   URL-decode the username/password fields. Therefore a value such as `%40`
   remains the literal three characters `%40`, rather than the original `@`.

This explains how the mysql-client checks can pass while Goose receives a
different password and returns MySQL 1045. It is a reproducible code defect for
credentials containing any character transformed by `mysql_dsn_escape()`.
The production password is redacted, so its character set cannot be confirmed
from the supplied log. If it contains none of those characters, this
formatter defect alone would not explain that specific 1045.

### Connection path and early failure behavior

- `goose_connection_host()` uses `host.docker.internal` for containerized
  Goose, and both the client preflight and Goose bridge execution use the
  Docker bridge network with a host-gateway mapping.
- `scripts/verify-mysql.sh` already sets `--connect-timeout=5` for its client
  connection checks. The pinned Go MySQL driver accepts a `timeout` DSN
  parameter and parses it as a duration, so the migration connection can use
  the same five-second connection bound without changing query/read timeouts.
- The log's successful authenticated-user output and matching Docker bridge
  connection context are consistent with the earlier source-host mismatch
  having been corrected. The `sudo` hostname-resolution warning is separate:
  the SQL checks continue and return results after it.
- The existing preflight runs before the migration lock, backup, or schema
  mutation. Preserve this order.
- Calling Goose `version` as an earlier generic probe is not appropriate:
  the existing legacy-baseline flow intentionally calls `version` to initialize
  Goose's ledger. A probe that initializes that ledger before state detection
  or backup could change the database being inspected.

## Decisions

- Remove the percent-encoding helper and place the raw configured user and
  password in the MySQL driver's DSN format. Keep the existing source of
  credentials, host resolution, bridge behavior, and migration ordering.
- Apply the existing five-second connection-timeout convention to both
  MySQL-client preflights and the Goose TCP dial; do not set a query/read
  timeout that could interrupt a long migration.
- Add a focused contract test with a dummy password containing several
  characters previously encoded. Assert that the Goose bridge receives the
  original bytes, while the existing preflight failure test continues to
  prove no backup is made on failure.
- Do not change MySQL grants, DNS, account host patterns, or host networking;
  the current report shows those checks are already passing.
- Do not add a new legacy DSN fallback or alter the tenant command interface.
- Document that the migration uses the configured host/port and
  `MYSQL_ADMIN_*`/existing fallback credentials, and that credential values
  are passed in Go MySQL DSN form rather than URL form.

## Remaining uncertainty and validation limits

- The production password is not available in the redacted log and was not
  read from server configuration. The incident is consistent with the
  formatter defect but cannot be proven against the live secret locally.
- No local host MySQL/Dokku runtime is available for a production-equivalent
  authentication rehearsal; deterministic contract tests will validate the
  code-level mismatch.
- Repository guidance specifies `abdulmohsenssda`; `gh auth status` confirmed
  it is the active CLI identity. The connected GitHub MCP identity is not
  authorized for this repository.
