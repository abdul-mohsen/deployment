# Design: Goose MySQL Authentication Parity

## Architecture and data flow

The deployment uses two existing connection paths before and during the
ZATCA master migration:

1. The shared MySQL helper resolves the configured host, port, account, and
   password. It passes the password to the MySQL client through `MYSQL_PWD`.
2. The Goose wrapper resolves the same host, port, and account and constructs
   the driver's MySQL data source from those values. In the dashboard
   configuration, Goose and the client preflight run on the Docker bridge with
   `host.docker.internal` mapped to the host gateway.

The mismatch is limited to the representation of the username/password in the
second path. The current formatter applies URL percent encoding, while Goose's
MySQL driver treats those credential fields literally. The implementation
will remove that encoding and pass the configured credential bytes unchanged.
Host resolution, bridge routing, database selection, and credential source
remain untouched.

Both MySQL-client preflight paths will use the existing five-second
`--connect-timeout` convention from `scripts/verify-mysql.sh`. The Goose DSN
will set the MySQL driver's five-second TCP `timeout` parameter. No read or
query timeout is added.

## Interfaces

- **External command/config interface:** No change to tenant-provisioning
  arguments or documented MySQL environment names.
- **Internal migration interface:** Goose continues to receive a MySQL DSN
  through the current invocation. Its user/password components will follow
  the MySQL driver's literal credential format.
- **Operational error interface:** Existing connection/authentication
  classification and safe context remain unchanged.

No separate public contract file is required because the command interface is
unchanged.

## Persistence and migration behavior

- No application schema, migration SQL, or Goose ledger schema changes.
- Keep the client preflight before backup, database creation, or migration
  work.
- Do not add a generic Goose `version` probe ahead of backup/state detection:
  the legacy baseline path uses that command to initialize the ledger, so
  moving it earlier could mutate the database before its state is classified
  and backed up.
- The only persistent effect remains the existing migration behavior after a
  successful preflight.

## Failure handling

- A failed client preflight remains fail-closed and stops before backup.
- A connection attempt that cannot reach the server is bounded to five
  seconds; authentication failures continue to fail immediately.
- A Goose authentication failure remains classified as authentication, with
  safe connection context but no password or DSN in logs.
- If the operator's production password contains no character transformed by
  the old formatter, the local code defect may not explain that particular
  failure; the error classification will still direct the operator to verify
  the matching MySQL account and password without weakening failure behavior.

## Security and performance

- Tests use only a fixed dummy password and must assert that the password is
  absent from command output.
- Do not read the production secret or make a production database connection.
- No extra database call or retry is introduced; only failed TCP connection
  attempts are bounded to five seconds.
- Preserve the existing use of a bridge container for source-host parity.

## Test strategy

- Extend `scripts/tests/test-migrate-zatca-master.sh` with a quoted dummy
  password containing percent, at-sign, colon, slash, question mark, hash, and
  semicolon characters. Assert the client preflight arguments and Goose DSN
  carry the five-second connection bound.
- Capture the Goose bridge's `GOOSE_DSN` in the existing Docker stub and
  assert it contains the exact dummy credential value rather than percent
  escapes.
- Retain the preflight-failure assertion that no backup is created.
- Run the focused contract test, Bash syntax checks, and `git diff --check`.
- A live MySQL/Dokku rehearsal is unavailable locally and must remain recorded
  as unrun rather than claimed as passed.

## Rollout and rollback

Deploy the script change through the normal deployment-repository pull request
and release flow. The change does not require a database migration or
credential rotation. Rollback is the ordinary deployment-script rollback; no
new persistent state is created by the fix.

## Requirement traceability

| Requirement | Design response |
|---|---|
| FR-001 | Keep the existing shared configuration and host resolution for both paths. |
| FR-002 | Remove percent-encoding from the Goose user/password fields. |
| FR-003 | Preserve the current preflight ordering before backup and schema changes. |
| FR-004 | Preserve error classification and omit secrets/DSNs from diagnostics. |
| FR-005 | Keep the documented CLI and environment interface unchanged. |
| FR-006 / NFR-1 | Bound readiness and Goose TCP connection attempts to five seconds. |
| NFR-2 | Do not change backup, migration ordering, or ledger behavior. |
| NFR-3 | Use deterministic stubs and dummy credentials only. |
