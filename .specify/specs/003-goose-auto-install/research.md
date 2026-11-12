# Research: Automatic Goose acquisition

## Repository evidence

- `scripts/migrate-zatca-master.sh` currently defaults
  `GOOSE_BIN` to `goose` and fails when it is absent.
- The script already loads `DEPLOY_STATE_DIR` through `scripts/lib.sh` and uses
  a state-backed lock file, so a cache under that state area follows existing
  deployment conventions.
- The existing contract test stubs Goose in `PATH`, making explicit binary
  behavior a regression requirement.
- The ZATCA artifact remains external and is validated for the required SQL
  files; automatic acquisition must not copy or generate that artifact.

## Upstream release evidence

The official Pressly Goose GitHub release API was checked on 2026-11-12. The
current release was `v3.30.0`, with these raw Linux assets and SHA-256 digests:

| Platform | Asset | SHA-256 |
|---|---|---|
| Linux amd64 | `goose_linux_x86_64` | `cce6e6371670f0654adc0ece407b81a22e53ba51e24e17a80ff7a0e25cda8548` |
| Linux arm64 | `goose_linux_arm64` | `624ae3159e221494c5e780c772cc000d788a4afe34a791553e43b2419174a715` |

The immutable URL pattern is:

`https://github.com/pressly/goose/releases/download/v3.30.0/<asset>`

## Decisions

1. Pin `v3.30.0` and both supported Linux asset digests in the script. This
   avoids a mutable latest-release lookup and keeps verification offline after
   the bytes are downloaded.
2. Prefer an explicit binary, then `goose` on `PATH`, then the verified cache
   download. This preserves existing operator control and avoids unnecessary
   network access.
3. Use `curl` when present and `wget` as a fallback. Require `sha256sum` for
   verification; do not silently skip integrity checks.
4. Cache under
   `${ZATCA_MASTER_GOOSE_CACHE_DIR:-${DEPLOY_STATE_DIR:-<project>/state}/bin}`.
   The override is optional; no new mandatory environment variable is introduced.
5. Restrict automatic acquisition to Linux `x86_64` and `aarch64`/`arm64`.
   Other hosts must use an explicit binary.

## Alternatives rejected

- **Install through `go install`:** requires a Go toolchain and resolves a
  module build rather than verifying the published release artifact.
- **Use the `latest` release URL:** mutable and not suitable for a migration
  control-plane dependency.
- **Download the ZATCA migration artifact too:** violates the repository
  ownership boundary and would require separate artifact provenance.
