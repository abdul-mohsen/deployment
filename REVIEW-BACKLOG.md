# Review Backlog

> **Status:** Deferred. Captured for later triage — not being worked on now.
> **Source:** Multi-agent code review run 2026-08-12 against `deployment-qa-branch-only-automation` (Go dashboard + Bash scripts).
> **Ordering:** Findings within each section are ordered by severity/priority as reported by the review, not by directory. Line references were accurate at the time of review — treat as starting points, not gospel, if code has moved.

---

## Security

**Snapshot:** 0 CRITICAL, 6 HIGH, 8 MEDIUM, 4 LOW. Core architecture is sound (bcrypt, chi middleware for auth, arg allow-list on script runner, dedicated sidecar container for shell execution, no committed secrets). Findings below are hardening opportunities, not "your dashboard is on fire."

### HIGH

1. **`fmt.Sprintf`-built DSNs** — `db.go` and `backup.go:378-379`, `web.go:1126`. Passwords with `@`, `?`, or `/` characters break DSN parsing. Switch to `mysql.Config{}.FormatDSN()`.
2. **Non-constant-time webhook secret compare** — `scripts/webhook-server.sh:112`. Bash `[` is timing-leaky. Bigger issue: whole webhook design is fragile — consider moving auth into the Go dashboard.
3. **Dead scanner + unbounded read in backup download** — `backup.go:261-278`. `bufio.Scanner` is allocated then ignored; real read has no upper bound and no `Range` header support. Fix with `http.ServeContent` / `http.ServeFile`.
4. **`SESSION_KEY` silently regenerates on restart when unset** — `config/config.go:82-87`. Every restart invalidates all sessions, and two replicas produce mutually incompatible cookies. Fail-fast when `DASHBOARD_ENV=prod` and no key is set.
5. **No CSRF middleware on state-changing POSTs** — `web.go:98-128`. `SameSite=Lax` (set at `web.go:77`) blocks most cross-origin, but not subdomain attacks. Add gorilla `csrf` middleware.
6. **`dbName` interpolated directly into DSN** — one hop from `validAppName` (a-z/0-9/hyphen). Safe today but the guarantee is spatial. Add explicit `validDBSuffix()`.

### MEDIUM

1. **Webhook JSON parsed with `grep -o`** — `scripts/webhook-server.sh:130-153`. Field ordering breaks matching; `type` field is unquoted in shell-out to `deploy-all.sh`. Validate `type ∈ {backend,frontend}` and `image` against strict regex.
2. **`config.env` (real password, gitignored)** — file permissions default to 0644 on Linux. `chmod 0600` in `install.sh`.
3. **HTTP calls to Docker Hub without timeout** — `web.go:540-570`, `web.go:575-608`. Wrap with `&http.Client{Timeout: 10 * time.Second}`.
4. **`template.JS` on JSON in `<script>` tags** — `web.go:133-139`. `json.Marshal` doesn't escape `</`; a tenant name containing `</script>` would break out. Post-process to escape `</`.
5. **`os.Setenv` for password hash in shared process** — `web.go:226`. Anything reading `/proc/self/environ` sees it. Small container = small risk, but worth noting.
6. **`filepath.Base` missing on `m.DBArtifact` in backup download** — `backup.go:229-247`. Not reachable today, but defensive check is one line.
7. **`log.Fatalf` at startup lists only "config: ADMIN_USER and ADMIN_PASSWORD_HASH are required"** — should enumerate every missing required var.
8. **`AUTO_REDEPLOY_DISABLED` has two sources of truth** — `auto-pull.sh:76-82` reads config file; dashboard writes `tenantstate` JSON. Consolidate.

### LOW

- Colored escape sequences leak into log files (only `status.sh` disables when not on TTY).
- `gzip -t` verifies CRC, not tar contents. Fine for corruption detection only.
- Missing security headers (`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`). Add `middleware.SetHeader`.
- `cmd/hashpw/main.go:44` uses `fmt.Println` → trailing `\n` in the hash. Manual paste can trip on it.

---

## Quality & Style

### HIGH

1. **`web.go` is 1,377 lines** — mixes routes, auth, HTTP helpers, JSON, templates, MySQL, Docker Hub. Split into `router.go`, `auth.go`, `tenants.go`, `scripts.go`, `imagetags.go`, `snapshot_handlers.go`.
2. **`fetchImageTags` and `fetchImageTagsWithMeta` are near-duplicates** — `web.go:457-531` and `web.go:612-661`. Delete the former; route its one caller through the latter.
3. **Dead-code scanner in `handleTenantBackupDownload`** — `backup.go:261-278`. See HIGH #3 in Security; fix once, close both findings.
4. **Inline Python inside a bash inside docker-exec** — `create-tenant.sh:335-347`. Rewrites nginx.conf via a `python3 -c "…"` inside `dokku_shell`. Extract to `scripts/lib/fix-nginx-upstream.py` and mount it.
5. **Runner-bootstrap heredoc duplicated 3×** — `scripts.go:582-599`, `backup.go:129-160`, `retention.go:94-100`. Same `mkdir /tmp/dep; cp -r scripts; find … sed -i 's/\r$//'` preamble in all three. Extract to `Runner.buildBootstrapBash()`.
6. **`buildAccountingExcel` hardcodes tenant schema knowledge** — `db.go:62-215`. Baked-in SELECTs. If backend schema drifts, silent "No Data" sheets. Introspect `information_schema.tables` or version-map.

### MEDIUM

1. **16 `_ =` error swallows in `web.go`** — some legitimate, some hide real errors (`_ = os.Setenv` at `web.go:226`).
2. **`validName` is an IIFE-assigned closure** — `web.go:1334-1349`. Clever but non-idiomatic; plain function is clearer.
3. **`fieldFromReport` scrapes Dokku CLI output** — `dokku.go:475-482`. A Dokku version bump silently breaks everything. Use `dokku --format json` where available.
4. **Manual JSON writing via `fmt.Fprintf` with `%q`** — `snapshot.go:137-153`. Doesn't handle nested quoting semantics. Use `json.Marshal(snap)` and cache the bytes.
5. **`create-tenant.sh` is 699 lines** — 12 numbered steps; `--update` path intertwined with fresh-create. Extract steps 4/5/6/8 into functions.
6. **Bcrypt cost 10 hardcoded everywhere** — `web.go:216`, `db.go:223`, `cmd/hashpw/main.go:39`. Extract `const BcryptCost = 10`.
7. **`os.Getenv("MYSQL_ROOT_PASSWORD")` at request time** — `web.go:1117`, `backup.go:376`, `web.go:1304`. Load once into `cfg` at startup.
8. **`.env` merger silently skips existing keys** — `envfile.go:49-51`. Correct behavior but no debug log; hard to trace precedence.
9. **`handleTenantAction` has hardcoded 2-min timeout** — `web.go:338`. Doesn't scale with `len(apps)`.
10. **`releases.go:67-83` walks 5 candidate paths with no logging** — add `log.Printf("[releases] loaded from %s", path)`.

### LOW

- Public methods on `*server` under-documented (many). `TagMeta` etc. are well-documented — good.
- Test bcrypt cost 4 in `backup_test.go:31` — fine, call out with comment.
- Dead functions: `dokku.go:207-220` `containerIDAny`, `scripts.go:277-284` `exposedPort`.
- `logbuf.go` uses 3 separate maps keyed by app; single `map[string]*ring` is cleaner.
- ANSI color helpers duplicated in every top-level `.sh`. Move to `lib.sh`.

---

## Test Coverage

### Baseline

| Package | Tests | Est. coverage | Verdict |
|---|---|---:|---|
| `internal/config` | 4 (envfile) | ~70% envfile, 0% Load | **PARTIAL** |
| `internal/tenantstate` | 5 | ~90% | **GOOD** |
| `internal/scripts` | 3 (releases only) | ~30% releases, 0% Runner | **POOR** |
| `internal/web` | ~20 across 6 files | ~35% web.go, ~40% backup, 0% snapshot, 0% db | **PARTIAL** |
| `internal/dokku` | **0** | **0%** | **CRITICAL GAP** |
| `internal/logbuf` | **0** | **0%** | **GAP** |
| `internal/retention` | **0** | **0%** | **GAP** |
| `cmd/hashpw` | **0** | **0%** | **GAP** (small file) |

### Critical missing tests

1. **`internal/dokku` (482 LoC, 0 tests)** — shells out to `docker` and `dokku`. Pure parsers (`RoleOf`, `TenantOf`, `FirstLine`, `ImageTag`, `FieldFromReport`, `ValidateAppName`) are trivial to test but currently break silently on Dokku CLI format changes.
2. **`internal/scripts.Runner`** — the code we've been debugging. 0% test coverage on the runner itself (only `releases.go` covered).
3. **`internal/retention`** — cron that deletes old backups. 0% coverage.
4. **`internal/logbuf`** — ring buffers per app. 0% coverage.

### Shell script tests

Live under `scripts/tests/`: `test-deployctl.sh`, `test-backups.sh`, `test-restart-stack.sh`. **CI integration is unverified** — need to check if the GitHub workflow actually runs them.

---

## Suggested triage priority when we return to this

1. **Add `internal/dokku` unit tests for pure parsers** — highest silent-breakage risk, smallest fix.
2. **Rewrite `handleTenantBackupDownload` with `http.ServeFile`** — closes 1 HIGH security + 1 HIGH quality in one PR.
3. **Fail-fast on missing `SESSION_KEY` in prod** — tiny, real ops footgun.
4. **DSN via `mysql.Config{}.FormatDSN()`** — small refactor, 3 files, closes latent password-injection risk.
5. **Extract runner-bootstrap heredoc** — the exact code we've been debugging today; centralizing it prevents divergence.

Larger structural work (splitting `web.go`, dedup `fetchImageTags`) — hold off until the above land.
