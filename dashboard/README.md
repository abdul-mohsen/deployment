# Dokku Dashboard

Argo-CD-style web UI for the Dokku tenants on this server.

- Live status grid (SSE; updates every 3s with smooth state-change animations)
- Per-app actions: start / stop / restart / rebuild
- Live log streaming (SSE) + ring-buffer log aggregation + downloadable dump
- Form-driven scripts (`/scripts/<name>`) with streamed output
- Command palette (Ctrl/Cmd+K)
- Single-admin login (bcrypt) with signed cookie session

## Deployment model

One container per environment (dev box, prod box). The container mounts
`/var/run/docker.sock` and shells out via `docker exec dokku dokku ...`, so
no SSH keys, no Dokku CLI install inside the dashboard image, no extra
runtime besides the docker socket.

## Configuration

| Var                   | Required | Default         |
| --------------------- | -------- | --------------- |
| `ADMIN_USER`          | yes      | —               |
| `ADMIN_PASSWORD_HASH` | yes      | — (bcrypt)      |
| `DASHBOARD_ENV`       | no       | `dev`           |
| `LISTEN`              | no       | `:8080`         |
| `DOCKER_BIN`          | no       | `docker`        |
| `DOKKU_CONTAINER`     | no       | `dokku`         |
| `BASE_DOMAIN`         | no       | `localhost`     |
| `SESSION_KEY`         | no       | random per boot |
| `LOG_BUFFER_LINES`    | no       | `2000`          |
| `COOKIE_SECURE`       | no       | `false`         |

Generate a password hash:

```sh
go run ./cmd/hashpw 'your-password'
# -> $2a$10$....
```

Generate a session key (so sessions survive restarts):

```sh
openssl rand -hex 32
```

## Run locally (dev)

```sh
docker compose -f docker-compose.dev.yml up --build
# UI:  http://localhost:8088
# Login: admin / admin   (override via ADMIN_USER / ADMIN_PASSWORD_HASH env)
```

The dashboard talks to whatever container is named `dokku` on the **same Docker
daemon as the host's socket**. If you don't have a Dokku container locally, the
UI still loads but the apps grid will be empty and the Dokku pill will say
`down` — that proves the container, network, auth, and live updates work.

## Deploy on a server

```sh
cd /opt/deployment/dashboard
cp docker-compose.prod.yml /opt/dashboard/
cat > /opt/dashboard/dashboard.env <<EOF
ADMIN_USER=admin
ADMIN_PASSWORD_HASH=$(go run ./cmd/hashpw 'pick-something-strong')
SESSION_KEY=$(openssl rand -hex 32)
BASE_DOMAIN=ifritah.com
EOF
cd /opt/dashboard
docker compose -f docker-compose.prod.yml up -d --build
```

Then expose it via Dokku just like any other app, e.g. as `admin-prod`:

```sh
dokku apps:create admin-prod
dokku ports:set admin-prod http:80:8080
dokku domains:set admin-prod admin.prod.ifritah.com
dokku letsencrypt:enable admin-prod
```

(Or front it with the host's nginx — the container already binds to
`127.0.0.1:8080`.)

## Security notes

- `/var/run/docker.sock` is **root-equivalent** on the host. Treat the
  dashboard like sudo: strong password, short-lived sessions, TLS in front.
- `SESSION_KEY` controls cookie integrity — set it to a stable 32-byte hex
  value or every restart logs everyone out.
- The container does not need its own `dokku` user; commands execute inside
  the dokku container via `docker exec`.
