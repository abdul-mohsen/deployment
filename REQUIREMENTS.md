# Deployment App — Minimum Requirements

Reference for what this repo (`deployment/`) needs to provision multi-tenant
backend + frontend apps on Dokku. Plain HTTP only — TLS is the operator's
responsibility on the host nginx in front of Dokku.

---

## 1. Topology (only supported)

```
Internet
   │
   ▼
host nginx  (operator-managed; terminates TLS if any)
   │  proxy_pass http://127.0.0.1:DOKKU_PORT;
   │  proxy_set_header Host $host;          # CRITICAL — Dokku routes by Host
   ▼
Dokku container  (published as -p 8080:80)
   │
   ▼
Dokku internal nginx  (one vhost per app, server_name <tenant>.BASE_DOMAIN)
   │
   ▼
tenant frontend  ──/api──▶  tenant backend
```

- This repo never installs certificates and never touches port 443.
- One-time host nginx vhost template lives at
  [templates/nginx/host-shared.conf](templates/nginx/host-shared.conf).

---

## 2. Host prerequisites

| Requirement | Notes |
|---|---|
| Linux + Docker | tested with Docker Engine on Ubuntu |
| Dokku container | run with `-p 8080:80` (do **not** publish 443) and `--hostname dokku` |
| External MySQL on host | **single MySQL server hosts both dev and prod tenants** — isolation is per-database (`tenant_<name>`) and per-user. Reachable from containers as `host.docker.internal:3306` (containers get `--add-host=host.docker.internal:host-gateway`). |
| NATS on host | exposed at `nats://host.docker.internal:4222` (backend fatals without it) |
| ZATCA submitter on host | separate process running on the host that reads tenant DBs from MySQL and submits invoices to ZATCA. Not deployed by this repo — must already be running. The `zatca_env` column in the master `tenant` table (default `production`, also accepts `sandbox`, `simulation`) tells the submitter which ZATCA endpoint to use per tenant. |
| Wildcard DNS | `*.BASE_DOMAIN` → server IP |
| Host nginx wildcard vhost | template ready in [templates/nginx/host-shared.conf](templates/nginx/host-shared.conf); points to `127.0.0.1:DOKKU_PORT` |

### dev vs prod

- **One Dokku host, one MySQL** serves both. Tenants are separated only by app
  name and database name. There is no separate "dev cluster".
- The `DEV_TENANT` (default `dev`) in [config.env](config.env.example) is a
  single tenant that can track `DEV_TAG` via `auto-pull.sh`, but the preferred
  release flow is exact SemVer image tags from each repo's `VERSION` file.
  All other tenants are deployed manually via [scripts/deploy-all.sh](scripts/deploy-all.sh).
- The string `production` you may see in scripts refers to:
  - the `zatca_env` column default (which ZATCA endpoint to submit to — has
    nothing to do with the tenant being a "production tenant"), and
  - comments distinguishing dev vs real deploy flow.
  It does **not** mean the backend runs in a different mode. The Go backend has
  no concept of `NODE_ENV` (that variable was a dead leftover and has been
  removed from `create-tenant.sh`).

---

## 3. Required `config.env` keys

Copy from [config.env.example](config.env.example) and fill:

- `BASE_DOMAIN` — tenants become `<tenant>.BASE_DOMAIN`.
- `DOKKU_PORT=8080` — host port the dokku container publishes.
- `STORAGE_ROOT=/opt/tenant-data`
- `MYSQL_HOST=host.docker.internal`, `MYSQL_PORT=3306`,
  `MYSQL_ADMIN_USER`, `MYSQL_ADMIN_PASSWORD` — the least-privileged
  deployment account; it does not need to be the MySQL root account.
- `MYSQL_MASTER_DB=zatca_master` — registry table `tenant(name, db_name, enabled, tenant_key)`,
  owned by ZATCA's zatca_master migrations (zatca_integration README section 1a). This repo
  writes rows there and never creates or alters its tables. Apply ZATCA's migrations first:
  `create-tenant.sh` refuses to run until `tenant.tenant_key` and the trigger
  `tenant_key_default` exist.
- `DEPLOY_STATE_DB=deployment_state` (optional) — the deployment-owned database for per-tenant
  image pins (`tenant_image`), verified identity (`tenant_identity`) and the deploy audit log
  (`tenant_deployment_audit`). `setup.sh` creates it.
- `MYSQL_TENANT_HOST=172.%` — docker bridge subnet; **must match** the host
  pattern used in [scripts/remove-tenant.sh](scripts/remove-tenant.sh)
- `DOCKERHUB_USERNAME`, optional `BACKEND_IMAGE` / `FRONTEND_IMAGE`,
  `PULL_TAG=dev` (the shared backend/frontend branch tag)
- `MIGRATION_STATUS_INTERVAL=5m` — dashboard interval for the read-only goose status check
  (`init-tenant-db.sh --status`); checks also run at dashboard startup.
- Production dashboard updates require the deployment checkout on `main` to
  match the published dashboard image commit. `update.sh` fast-forwards the
  checkout, and `dashboard/prod-up.sh` refuses a revision mismatch before
  replacing the running dashboard.
- Optional: `PUBLIC_PROTOCOL=https|http` (controls the canonical public link
  scheme and the frontend `API_URL`; production must use `https`),
  `NGINX_CLIENT_MAX_BODY_SIZE=50m`
- Optional non-production verification controls:
  `TENANT_PROVENANCE_OVERRIDE=1` together with `DEPLOY_ENV=dev|test|qa|sandbox|simulation`,
  plus `TENANT_VERIFY_RETRIES` and `TENANT_VERIFY_DELAY`. The override is
  refused for production deployments.

---

## 4. One-time MySQL admin grants

Required for the deployment-side admin user (`MYSQL_ADMIN_USER`) to create per-tenant
DBs and users. The account is intentionally not MySQL root, and it has no `ALL PRIVILEGES`
on `zatca_master`:

```sql
GRANT ALL PRIVILEGES ON `tenant_%`.* TO 'dokku_admin'@'172.%' WITH GRANT OPTION;
GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON `zatca_master`.`tenant` TO 'dokku_admin'@'172.%';
GRANT CREATE, SELECT, INSERT, UPDATE, DELETE ON `deployment_state`.* TO 'dokku_admin'@'172.%';
GRANT CREATE USER ON *.* TO 'dokku_admin'@'172.%';
```

What each privilege is for. The statements were checked in `scripts/`; the defaults are
`MYSQL_MASTER_DB=zatca_master` and `DEPLOY_STATE_DB=deployment_state`.

| Object | Privileges | Statements |
|---|---|---|
| `zatca_master.tenant` | SELECT | reads of `tenant_key` (`lib.sh`, `tenant_registry_key`); joins on `tenant` (`deploy-all.sh`, `status.sh`, `set-tenant-image.sh`); column check (`lib.sh`, `require_registry_tenant_key`) |
| `zatca_master.tenant` | INSERT, UPDATE | `INSERT INTO tenant ... ON DUPLICATE KEY UPDATE enabled=1` (`create-tenant.sh`); `UPDATE tenant SET enabled=0` (`cleanup-broken-tenant.sh`) |
| `zatca_master.tenant` | DELETE | `DELETE FROM tenant` (`remove-tenant.sh`, `cleanup-broken-tenant.sh`) |
| `zatca_master.tenant` | TRIGGER | the trigger check (`lib.sh`, `require_registry_tenant_key`) reads `information_schema.triggers`. MySQL shows a table's triggers only to accounts with the TRIGGER privilege on that table |
| `deployment_state.*` | CREATE | `CREATE DATABASE` and `CREATE TABLE IF NOT EXISTS` (`lib.sh`, `ensure_deployment_state_schema`), run by `setup.sh`, `create-tenant.sh`, `deploy-all.sh` and `update-tenant.sh` |
| `deployment_state.*` | SELECT, INSERT, UPDATE, DELETE | `tenant_image` and `tenant_identity` reads and writes (`set-tenant-image.sh`, `status.sh`, `deploy-all.sh`, `tenant-provenance.sh`, `remove-tenant.sh`, `cleanup-broken-tenant.sh`); `tenant_deployment_audit` inserts (`tenant-provenance.sh`) |
| `tenant_%`.* | ALL PRIVILEGES, WITH GRANT OPTION | unchanged. Creates and drops tenant DBs and grants their users. The dashboard's accounting export and password update connect as this account to tenant DBs (`dashboard/internal/web/backup.go`, `web.go`). `goose` connects as the tenant user, not as this account |
| `*.*` | CREATE USER | unchanged. `CREATE USER` and `ALTER USER` for tenant users |

`scripts/tests/test-no-git-push-and-master-grants.sh` fails if a doc or an example grants
`ALL PRIVILEGES` on `zatca_master`.

Rules learned the hard way:
- Use **backticks** for `tenant_%`, never single quotes.
- `.*` is mandatory in `GRANT \`tenant_%\`.*` — without it MySQL treats it as a
  table-level grant in the current database.
- Tenant schema and migrations are applied as the tenant DB user. Backend
  migrations must avoid trigger creation so MySQL 8 binary logging does not
  require global trigger-related privileges.
- No `FLUSH PRIVILEGES` — needs `RELOAD` priv and isn't required in MySQL 8 for
  `CREATE USER` / `GRANT`.
- `CREATE USER IF NOT EXISTS` does **not** update an existing password — always
  pair with `ALTER USER … IDENTIFIED BY` for idempotency.
- Existing-tenant schema replay uses the tenant's `DB_USER`/`DB_PASSWORD`
  account and does not require `MYSQL_ADMIN_PASSWORD`; the deployment account
  is needed only when a tenant database or user must be provisioned.
- Fresh `create-tenant.sh` provisioning refuses an existing tenant database or
  master-registry row before creating Dokku apps or mutating MySQL. Use
  `--adopt-existing` only after confirming that the state belongs to the
  requested tenant; adoption still runs the verified backup and goose migration
  before the backend image starts. `--update` remains the separate acknowledgement
  for existing Dokku apps.
- Schema changes are forward-only. A backend rollback across a schema change needs a
  restore first, and `rollback-tenant.sh` requires `--confirm-schema-compatible` for a
  backend rollback.
- Deployment never names backend migration files or versions; removed or
  modified migration SQL is not recreated here. The backend image owns the
  contiguous goose sequence `00001..00010`, including chain-owner migrations
  and the idempotent `00008` existing-data backfill. Deployment must not
  remove or renumber `00005`/`00008`; it only runs the target image's goose
  command and validates the final metadata contract.
- The ZATCA daemon's `queue.SQLChain` owns runtime ICV reservation/commit
  behavior. Deployment only verifies the read-only chain schema contract:
  `branch_zatca_config` contains `last_icv`, `previous_invoice_hash`, all four
  reservation columns, and `zatca_submission` has a unique
  `(branch_id, invoice_icv)` key plus its chain/outcome/signed-XML columns and
  the `zatca_consumer_claim` claim columns.
  Deployment never references removed `pkg/egschain` code or writes these
  chain-owned fields.
- Tenant image updates resolve tags to OCI digests, require the canonical
  BuildIdentity labels, pass `APP_IMAGE_VERSION`/`APP_IMAGE_COMMIT`,
  `APP_IMAGE_CHANNEL`, `APP_IMAGE_REF`, `APP_IMAGE_DIGEST`,
  `APP_WORKFLOW_RUN_ID`, optional `APP_WORKFLOW_RUN_URL`, and `APP_BUILT_AT`
  to Dokku, and verify the app `/version` response before persisting the new
  identity. Legacy `APP_VERSION`/`APP_WORKFLOW_RUN` aliases are retained only
  for migration.

---

## 5. What `create-tenant.sh` provisions per tenant

- Apps: `<tenant>-backend`, `<tenant>-frontend`.
- Domain: `<tenant>.BASE_DOMAIN` on the frontend app only. The backend app is
  internal-only and must not own the same public domain, otherwise Dokku nginx
  generates duplicate `server_name` blocks.
- Ports: `dokku ports:set <app> http:80:<container_port>`
  (backend default 8090, frontend 8000; override via `--backend-port` /
  `--frontend-port`).
- Frontend `/api` → backend via
  the frontend app's own proxy, using `BACKEND_URL=http://<backend>.web:<BACKEND_PORT>`
  on the per-tenant Docker network. Do not add custom Dokku nginx `/api`
  snippets for this.
- MySQL: db `tenant_<name>`, user `usr_<name>@'172.%'`, registered in
  `zatca_master.tenant`.
- Storage mounts:
  `$STORAGE_ROOT/<tenant>/{uploads,data}` → `/app/{uploads,data}`.
- CHECKS files seeded: backend `/healthz`, frontend `/`.

---

### Tenant `--env` overrides

`create-tenant.sh` and `update-tenant.sh` accept repeatable `--env
KEY=VALUE` flags for tenant **application** settings. The scripts keep this
surface open for new application settings rather than maintaining a brittle
application allow-list. `DATABASE_URL`, the documented modern `DB_*`
connection keys, the legacy backend database keys (`HOST`, `DBUSER`,
`PASSWORD`, `DBNAME`), `ADMIN_*`/`MANAGER_*` seed values, `COMPANY_NAME`, and
arbitrary application keys such as `FEATURE_FLAG` remain valid.

Before any Dokku command runs, the scripts reject reserved deployment keys:

- **Control plane and runtime identity:** `APP_*`,
  `AUTO_BACKUP_BEFORE_REDEPLOY`, `AUTO_REDEPLOY_DISABLED`, `BACKEND_IMAGE`,
  `BASE_DOMAIN`, `BASEURL`, `BACKUP_DIR`, `DASHBOARD_*`, `DEPLOY_*`,
  `DEPLOY_ENV`, `DEV_TAG`, `DEV_TENANT`, `DOCKERHUB_*`,
  `IMAGE_PULL_POLICY`, `LOG_DIR`, `MSG_HOST`, `MSG_PORT`, `NATS_URL`,
  `NGINX_*`, `PORT`, `PUBLIC_PROTOCOL`, `PULL_TAG`, `SERVER_PORT`,
  `STORAGE_ROOT`, `TENANT_APP_NETWORK`, `TENANT_ID`,
  `TENANT_IMAGE_PULL_POLICY`, `TENANT_NAME_PREFIX`, `TENANT_NETWORK`,
  `TENANT_PROVENANCE_*`, `TENANT_STATE_DIR`, `TENANT_VERIFY_*`, and
  `WEBHOOK_SECRET`.
- **Database administration:** `MYSQL_*`, `MYSQL_PWD`, and `DB_ADMIN_*`.
- **Migration controls:** `MIGRATION_*` is reserved for deployment (goose runs from the
  backend image; tenants cannot set migration controls).
- **Docker execution:** `DOCKER_*` and `DOKKU_*`.
- **Telemetry and telemetry secrets:** `OPENOBSERVE_*`, `OTEL_*`, and
  `METRICS_TOKEN`.

Keys must match shell environment-name syntax (`[A-Za-z_][A-Za-z0-9_]*`).
Only the key is inspected; values may contain `=`. Reserved values must be
provided through the operator-owned `config.env`/observability configuration,
not through a tenant `--env` override.

## 6. Backend container env (LEGACY names — required)

The `ifritah-go` backend reads the legacy variable names below. Setting only
the modern `DB_*` names is **silently ignored**.

| Var | Meaning |
|---|---|
| `HOST` | `host:port` string (NOT `DB_HOST`) |
| `DBUSER` | DB username |
| `PASSWORD` | DB password |
| `DBNAME` | DB name |
| `SERVER_PORT` | listener port inside the container |
| `JWT_SECERT_KEY` | JWT signing key (intentional misspelling) |
| `NATS_URL` | required at boot — fatals without it |
| `BASEURL` | route prefix, e.g. `/api/v2` (default in script) |
| `TENANT_ID` | tenant slug |

Modern duplicates (`DATABASE_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
`DB_PASSWORD`) are also set for forward compatibility.

---

## 7. Frontend container env

- `TENANT_ID`
- `API_URL=${PUBLIC_PROTOCOL}://<tenant>.BASE_DOMAIN/api`

---

## 8. Dashboard (Go web app)

- Local: `http://localhost:8088` · Live: `https://odoo.ifritah.com`
- Login: `admin` / `admin`.
- Apps page lists tenants with health, log tail per app at `/apps/<name>/logs.txt`.
- Scripts page (`/scripts`) runs the curated form-driven scripts (e.g.
  `create-tenant`) with their output streamed back as SSE.
- **No `/console`**. Arbitrary `dokku <verb>` execution from the dashboard was
  removed in this PR — it was a remote-code-execution surface even with the
  allow-list, and every legitimate use is already covered by the Apps and
  Scripts pages plus per-tenant logs.

---

## 9. Out of scope (do NOT add back)

- TLS certificates, Let's Encrypt, cert renewal.
- Per-tenant host port allocation.
- Multiple `NGINX_MODE` values — single mode only.
- "Standalone" Dokku where Dokku owns :443 — operator nginx is mandatory.
- Deploying or managing the on-host ZATCA submitter — it lives outside this repo.
- Git-push deploys to Dokku. Tenant apps are deployed by the scripts only, from Docker Hub images, and no SSH key for git push may be registered with Dokku.

---

## 10. Test workflow (no direct prod access)

I (the agent) only have:
- the local workspace at `c:\ssda\chatGPT\clone\deployment`
- the live dashboard at `https://odoo.ifritah.com` (admin/admin) — Apps and
  Scripts pages, plus per-tenant log dumps at `/apps/<name>/logs.txt`. No
  arbitrary command surface (the old `/console` was removed for security).

I do **not** have shell on the production server. The user does.

So the loop is:
1. Reproduce locally first — full stack runs on this machine
   (MySQL `:13306`, NATS `:4222`, Dokku container `:8080`, dashboard `:8088`).
2. Run the changed script (e.g. `create-tenant.sh`) against the local Dokku;
   verify with `dokku ps:report`, curl, and the local dashboard.
3. Only after local pass, hand the change to the user to apply on the real
   server, or drive it remotely via the dashboard `/console` for `dokku`
   subcommands and ask the user to run anything that needs host shell
   (`sudo nginx -t`, `ss -ltnp`, file edits in `/etc/nginx/`, etc.).
