# Tenant Backend Deployment — Gotchas & Required Env

If a tenant backend container restarts forever after `create-tenant.sh`, it is almost
always one of the items below. Verify with:

```bash
dokku config:show <tenant>-backend
dokku logs <tenant>-backend --tail 100
```

## 1. MySQL admin user (`dokku_admin`) needs the right privileges

The dashboard / `create-tenant.sh` connect to MySQL as `dokku_admin@'172.%'`.
Minimum privileges (run **once** as root on the host MySQL):

```sql
GRANT ALL PRIVILEGES ON `tenant_%`.* TO 'dokku_admin'@'172.%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON `zatca_master`.* TO 'dokku_admin'@'172.%';
GRANT CREATE USER  ON *.*           TO 'dokku_admin'@'172.%';
```

Notes:
- Use **backticks** around `tenant_%` (single quotes give a syntax error).
- Don't add `WITH GRANT OPTION` on `*.*` — `dokku_admin` only needs to grant on the
  tenant DB it just created.
- **No `RELOAD` priv** — the script does not call `FLUSH PRIVILEGES` (`CREATE USER`/`GRANT`
  apply immediately in MySQL 8).

## 2. Tenant DB user lives at `'usr_<tenant>'@'172.%'`

`create-tenant.sh` always runs `ALTER USER ... IDENTIFIED BY '<random>'` so re-creating
a tenant works even if the user already exists from a prior failed run.

`remove-tenant.sh` drops `'usr_<tenant>'@'172.%'` (must match `MYSQL_TENANT_HOST`).
If you used an older script and have stale users, drop them by hand as MySQL root.

## 3. Backend reads **legacy env names** (`ifritah-go`)

`pkg/db/db.go`:
- `HOST`     — full `host:port`, NOT `DB_HOST`
- `DBUSER`   — NOT `DB_USER`
- `PASSWORD` — NOT `DB_PASSWORD`
- `DBNAME`   — NOT `DB_NAME`

`main.go`:
- `SERVER_PORT` — listener port

`pkg/handlers/handler.go` / `pub.go`:
- `JWT_SECERT_KEY` — yes, that spelling. Required at request time, fine to be empty at boot.
- `NATS_URL`       — required at boot (`NewZATCAPublisher` fatals if it can't connect).
- `BASEURL`        — URL prefix for routes (e.g. `/api/`).

`create-tenant.sh` sets all of these. Override `NATS_URL` / `BASEURL` / `JWT_SECERT_KEY`
in `config.env` if you want fixed values.

## 4. NATS server must be running on the host

The backend will not boot without a reachable NATS server. Run once per host:

```bash
sudo bash scripts/setup-nats.sh
# or via dashboard: Scripts → Setup NATS
```

Verify:
```bash
docker exec -it <any-app>-web sh -c 'nc -zv host.docker.internal 4222'
```

## 5. Docker bridge subnet must match `MYSQL_TENANT_HOST`

`MYSQL_TENANT_HOST` defaults to `172.%`. If your Docker bridge uses a different
subnet (rare), set `MYSQL_TENANT_HOST` in `config.env` and re-grant `dokku_admin`
on the new pattern.

## 6. Dokku container needs `--hostname dokku`

Otherwise `sudo` inside the dokku container prints
`sudo: unable to resolve host <containerid>`. Fresh installs from `setup-dokku.sh` get
this for free; existing installs can run:

```bash
sudo bash scripts/fix-dokku-hostname.sh
```

## 7. Dashboard reads MySQL admin creds from `install.env` first

The dashboard's MySQL banner reads `MYSQL_ROOT_USER` / `MYSQL_ROOT_PASSWORD` from
`install.env` (preferred), then `config.env`. If you change creds, restart the
dashboard container or it will keep reading the old values.
