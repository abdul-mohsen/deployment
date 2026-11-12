# Requirements: Automatic Goose acquisition

## Problem

The ZATCA master migration orchestration currently requires the `goose` executable
to be installed on the deployment host or supplied through
`ZATCA_MASTER_GOOSE_BIN`. A fresh deployment can therefore fail before its first
tenant is created even when the migration artifact and database credentials are
configured.

## Goals

- Let the migration script acquire a known Goose release when no explicit binary
  was configured and no `goose` executable is already on `PATH`.
- Keep explicit operator-provided binaries authoritative.
- Fail closed on unsupported platforms, unavailable download tools, failed
  downloads, or checksum mismatches.
- Avoid adding any new mandatory environment variable.
- Document the fallback and preserve the existing ZATCA artifact ownership
  boundary.

## Scope

### In scope

- `scripts/migrate-zatca-master.sh` automatic Goose resolution and caching.
- Focused shell contract tests for PATH resolution, download, cache reuse, and
  checksum failure.
- `config.env.example` and `README.md` setup documentation.

### Out of scope

- Downloading or generating the ZATCA-owned migration SQL artifact.
- Changing tenant migrations, Goose invocation arguments, or database ownership.
- Supporting non-Linux deployment hosts in the automatic download path.
- Replacing an explicitly configured `ZATCA_MASTER_GOOSE_BIN`.

## User stories

1. As an operator who leaves `ZATCA_MASTER_GOOSE_BIN` unset, I can run the
   ZATCA master migration on a supported Linux host without manually installing
   Goose first.
2. As an operator with a managed Goose installation, I can set
   `ZATCA_MASTER_GOOSE_BIN` and the script uses that executable unchanged.
3. As a security-conscious operator, I receive a hard failure if the downloaded
   Goose artifact does not match the pinned checksum.

## Functional requirements

- **FR-1 Explicit binary precedence:** A non-empty `ZATCA_MASTER_GOOSE_BIN` or
  `--goose-bin` value must be validated and used; the script must not download
  over it.
- **FR-2 PATH precedence:** When no explicit binary is configured, an executable
  named `goose` on `PATH` must be used without downloading.
- **FR-3 Automatic acquisition:** When neither FR-1 nor FR-2 applies, the script
  must download the pinned Goose release for Linux `amd64` or `arm64` into a
  persistent cache and use it.
- **FR-4 Integrity:** The downloaded bytes must be checked against a
  source-pinned SHA-256 digest before becoming executable. Partial or invalid
  files must not be used.
- **FR-5 Failure reporting:** Unsupported architecture, missing download/hash
  tools, network failure, checksum mismatch, and installation failure must
  produce an actionable error and non-zero exit status.
- **FR-6 Existing behavior:** The resulting Goose invocation must remain
  `goose -dir <artifact> mysql <dsn> <action>`, with all current migration
  backup, locking, legacy-policy, and verification behavior unchanged.

## Non-functional requirements

- **NFR-1 Supply chain:** The default release version, asset names, URLs, and
  checksums are pinned in source; no mutable "latest" URL is used.
- **NFR-2 Atomicity:** Cache installation must use a temporary file and atomic
  rename; a failed download must not leave a usable-looking cached binary.
- **NFR-3 Permissions:** The cached executable must be mode `0755`, and the
  cache must use the existing deployment state area by default.
- **NFR-4 Operability:** Logs must identify whether PATH, cache, or download
  resolution was used without printing DSNs or credentials.

## Acceptance criteria

- **AC-1** Existing tests continue to pass with an explicit stub Goose binary.
- **AC-2** A test proves an unset binary downloads the pinned fixture, verifies
  it, caches it, and runs it.
- **AC-3** A test proves a cached binary is reused without a second download.
- **AC-4** A test proves checksum mismatch fails and leaves no installed binary.
- **AC-5** Documentation states that no new mandatory Goose environment variable
  is required and explains the optional cache override and explicit binary
  behavior.

## Assumptions, risks, and unknowns

### Assumptions

- Production deployment hosts are Linux and use `amd64` or `arm64`.
- The host can reach GitHub Releases when the fallback is needed.
- The operator has write access to the default deployment state directory.

### Risks

- A first-run network dependency can delay migration when GitHub is unavailable.
- A future Goose release requires a source change to update its pinned digest.

### Resolved unknowns

- Goose publishes raw Linux binaries named `goose_linux_x86_64` and
  `goose_linux_arm64` with release checksums.
- The current migration script already has a persistent state directory
  convention suitable for a binary cache.

### Open questions

- None blocking implementation; non-Linux automatic acquisition remains
  intentionally out of scope.
