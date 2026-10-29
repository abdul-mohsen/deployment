# Templates for App Repos

These files are **not used by the deployment server**. Copy them into your
backend / frontend repos so each app owns its own build, local-dev compose,
and CI workflow.

```
templates/
  backend/
    Dockerfile
    docker-compose.yml         # local dev stack (api + mysql)
    .env.example               # rename to .env locally
    .dockerignore
    .gitignore
    .github/workflows/deploy.yml
  frontend/
    Dockerfile
    docker-compose.yml         # local dev stack (web)
    .env.example
    .dockerignore
    .gitignore
    .github/workflows/deploy.yml
```

## How to install in an app repo

```bash
# From inside your backend repo:
cp -r ../deployment/templates/backend/. .
mv .env.example .env   # edit values
docker compose up      # local dev
```

## Branch → tag → deploy flow

Each app repo owns a committed `VERSION` file. The value must be strict SemVer
with a `v` prefix, for example `vX.X.X`. The starting version is `v0.0.1`.

| Source | Image tag | Deploy behavior |
|---|---|---|
| `VERSION` | `:vX.X.X` | Primary deploy tag. Re-running CI with the same version overwrites this tag. |
| commit SHA | `:<sha>` | Immutable reference for rollback/debug. |

Backend and frontend must use the same `VERSION` value for a compatible release.
The dashboard deploys one selected version tag to both images.

The workflow fails if `VERSION` is lower than the latest GitHub Release tag in
that repo. Equal is allowed so a rebuild can overwrite the same Docker tag.

## Required GitHub secrets in each app repo

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`
- `WEBHOOK_URL_DEV`  *(optional — instant dev deploy)*
- `WEBHOOK_SECRET`   *(optional — must match `config.env` on the server)*

## ZATCA daemon and backend NATS

The deployment repository can run the ZATCA daemon as an optional first-class
service with:

```bash
sudo ./scripts/deployctl.sh --config /opt/deployment/config.env setup zatca
```

When enabled, the daemon owns the single embedded NATS/JetStream instance.
Tenant backend containers must receive the same host-reachable endpoint through
`NATS_URL`/`ZATCA_NATS_URL` (normally
`nats://host.docker.internal:4222`). Do not add a second NATS service to an app
deployment.

The daemon image is supplied by the ZATCA integration build lane and must
already contain the Go daemon, Java runtime, and approved Fatoora SDK artifact.
Set the following in the deployment server's private `config.env`; none are
hard-coded in these templates:

- `ZATCA_DAEMON_IMAGE`
- `ZATCA_DB_USER` / `ZATCA_DB_PASSWORD`
- `ZATCA_ENCRYPT_KEY`
- `ZATCA_MONITOR_PASSWORD`
- `ZATCA_XML_ROOT` and `ZATCA_NATS_DATA_ROOT`

The runtime account needs access to the master tenant registry and the
tenant-database pattern. Optional onboarding credentials are configured with
`ZATCA_ADMIN_DB_USER` / `ZATCA_ADMIN_DB_PASSWORD`. Signed XML and JetStream
data are persisted on the configured host paths, and readiness is the
authenticated daemon monitor `GET /healthz`.

## Release notes

Keep release notes in GitHub Releases as the source of truth. Mirror the released
versions into the deployment dashboard release catalog when they are ready to
deploy. The dashboard marks a version broken from Dokku deployment state when an
app currently running that version is stopped, restarting, or otherwise not
running.
