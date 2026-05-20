# Multi-Tenant Deployment

Server-side automation for a Dokku-based multi-tenant platform.

The primary operator entrypoint is now one git-style command:

```bash
sudo ./scripts/deployctl.sh <area> <command> [args]
```

Use `--plan` to see the underlying script before running it:

```bash
./scripts/deployctl.sh --plan tenant update acme --restart
# bash scripts/update-tenant.sh acme --restart
```

**Two repos own their own build:**

```
backend repo  →  push to dev  ──────────┐
                 push to main ────┐     │
                                  │     │       Docker Hub
                                  ▼     ▼
                            myuser/api:latest    myuser/api:dev
                                  │                   │
                                  │ manual            │ auto every 2 min
                                  ▼                   ▼
                          deployctl fleet sync   deployctl fleet auto-pull
                                  │                   │
                              prod tenants       dev tenant
```

- **Dev**: a single tenant; `auto-pull.sh` polls `:dev` every 2 min and redeploys.
- **Prod**: ops runs `deploy-all.sh <image> --tenant <client>` per client when promoting a build.
- **App repos own**: Dockerfile, docker-compose for local dev, `.env.example`, and the GitHub Actions workflow that builds + pushes the image.
- **This repo owns**: server provisioning, tenant lifecycle, image polling, manual rollouts, backups, rollbacks.

## Repo layout

```
.gitignore
config.env.example          # copy to config.env on each server
README.md
scripts/                    # ops automation (run on the server)
  deployctl.sh              # one command: tenant/fleet/stack/setup/db/dokku/webhook
  setup.sh                  # one-time install: Dokku, MySQL wiring, cron, webhook
  setup-dev-tenant.sh       # creates the single dev tenant pinned to :dev
  create-tenant.sh          # provision a new prod tenant
  remove-tenant.sh
  update-tenant.sh
  deploy-all.sh             # MANUAL prod deploy (per-client or all)
  auto-pull.sh              # cron: dev-only auto-deploy from :dev tag
  rollback-tenant.sh
  set-tenant-image.sh       # pin a tenant to a specific image
  list-tenants.sh
  tail-logs.sh
  backup-tenant.sh
  cleanup-old-files.sh
  webhook-server.sh         # optional: instant dev deploy on push
  webhook-tls.sh            # TLS in front of webhook
  webhook-deploy.service    # systemd unit
  Dockerfile.webhook
  lib.sh                    # shared helpers
templates/                  # COPY these into your backend / frontend repos
  README.md
  backend/
    Dockerfile
    docker-compose.yml
    .env.example
    .dockerignore
    .gitignore
    .github/workflows/deploy.yml
  frontend/
    Dockerfile
    docker-compose.yml
    .env.example
    .dockerignore
    .gitignore
    .github/workflows/deploy.yml
```

## Server prerequisites

- Linux + Docker Engine
- MySQL on the host (or reachable via `host.docker.internal`)
- Wildcard DNS: `*.app.example.com → server IP`

## Initial setup

```bash
git clone <this-repo> /opt/deployment
cd /opt/deployment
cp config.env.example config.env
$EDITOR config.env

sudo ./scripts/setup.sh
sudo ./scripts/deployctl.sh setup dev-tenant        # creates the one dev tenant
```

## Day-2 operations

| Task | Command |
|---|---|
| Create prod tenant | `sudo ./scripts/deployctl.sh tenant create acme` |
| Manual prod deploy (one client) | `sudo ./scripts/deployctl.sh fleet sync myuser/api:latest --tenant acme` |
| Manual prod deploy (all clients) | `sudo ./scripts/deployctl.sh fleet sync myuser/api:latest` |
| Pin a tenant to a fixed image | `sudo ./scripts/deployctl.sh tenant pin acme --backend myuser/api:v1.4` |
| Rollback | `sudo ./scripts/deployctl.sh tenant rollback acme --to myuser/api:abc1234` |
| List tenants | `sudo ./scripts/deployctl.sh tenant list` |
| Tenant status | `sudo ./scripts/deployctl.sh tenant status acme` |
| Tail logs | `sudo ./scripts/deployctl.sh tenant logs acme --type backend` |
| Backup | `sudo ./scripts/deployctl.sh fleet backup` |
| Restart platform | `sudo ./scripts/deployctl.sh stack restart --env all` |

The old `scripts/*.sh` files remain as readable implementation units and compatibility entrypoints. New operations should be exposed through `deployctl.sh` first.

## Bootstrapping the app repos

```bash
# In the backend repo:
cp -r /opt/deployment/templates/backend/. .
cp .env.example .env       # local dev only — never commit
docker compose up          # local dev stack

# In the frontend repo: same with templates/frontend
```

Each app repo CI builds:
- `:dev` on push to `dev` → server's `auto-pull.sh` deploys it within ~2 min.
- `:latest` on push to `main` → **not auto-deployed**. Ops promotes manually with `deploy-all.sh`.
- `:<sha>` on every push → used for rollbacks.

## GitHub secrets to set in each app repo

| Secret | Required | Notes |
|---|---|---|
| `DOCKERHUB_USERNAME` | yes | |
| `DOCKERHUB_TOKEN` | yes | Docker Hub access token |
| `WEBHOOK_URL_DEV` | optional | for instant dev deploy |
| `WEBHOOK_SECRET` | optional | must match `WEBHOOK_SECRET` in `config.env` |

Polling (cron + `auto-pull.sh`) is the safety net and works without any webhook.
