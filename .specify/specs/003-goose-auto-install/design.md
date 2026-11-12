# Design: Automatic Goose acquisition

## Resolution flow

`migrate-zatca-master.sh` will resolve `GOOSE_BIN` after command-line parsing
and before database/artifact validation:

1. If `--goose-bin` or `ZATCA_MASTER_GOOSE_BIN` is non-empty, validate that
   executable and use it. No fallback is attempted.
2. Otherwise, resolve `goose` with `command -v` and validate the result.
3. Otherwise, map `uname -s`/`uname -m` to one of the pinned Linux assets.
4. Check the cache path for an executable named
   `goose-v3.30.0-<arch>`, verify its digest, and use it if valid.
5. If the cache is absent, download to a temporary file, verify its digest,
   set mode `0755`, and atomically rename it into the cache. Use the cache path
   for the migration.

The cache filename includes the pinned version and platform so a source update
cannot accidentally reuse a binary for another version or architecture.

## Interfaces

- Existing `ZATCA_MASTER_GOOSE_BIN` and `--goose-bin` retain their meaning.
- New optional `ZATCA_MASTER_GOOSE_CACHE_DIR` controls only the local cache
  directory. Its default is the deployment state `bin` directory.
- No new mandatory environment variable is introduced.
- No change is made to `goose_run` arguments or DSN construction.

## Failure handling

- Explicit binary missing/not executable: fail with the configured path.
- Unsupported OS/architecture: fail with the detected values and explain that
  an explicit binary can be supplied.
- Neither `curl` nor `wget`: fail before attempting download.
- Missing `sha256sum`: fail before accepting a download.
- Download failure, empty file, checksum mismatch, chmod failure, or rename
  failure: remove the temporary file and return non-zero.
- Existing cache checksum mismatch: remove the invalid cache file and redownload.

Errors must not include the DSN or password. Success logs include only release,
platform, and cache path.

## Security and operational considerations

- URLs and checksums are source-pinned.
- Downloaded content is never executed until checksum verification succeeds.
- Temporary files are created inside the cache directory and removed on
  failure.
- The cache directory is created with normal deployment permissions; the final
  binary is executable but not world-writable.
- Existing migration lock and verified-backup behavior remains unchanged.

## Test strategy

Extend `scripts/tests/test-migrate-zatca-master.sh` with fake `curl` and
`sha256sum` commands:

- exercise download and execution with no explicit Goose binary;
- run again to prove cache reuse;
- force a digest mismatch and assert non-zero status plus no cached binary;
- retain the current explicit PATH stub tests.

No live network is used by tests.

## Requirement traceability

| Requirement | Design element |
|---|---|
| FR-1/FR-2 | Explicit/PATH precedence |
| FR-3 | Platform mapping and cache download |
| FR-4/NFR-1 | Pinned digest verification |
| FR-5 | Fail-closed validation and cleanup |
| FR-6 | Unchanged `goose_run` contract |
| NFR-2/NFR-3 | Temporary file, atomic rename, mode 0755 |
| NFR-4 | Sanitized resolution logs |
