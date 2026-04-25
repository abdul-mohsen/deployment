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

| Branch  | Image tag | Deploy behavior                                                  |
|---------|-----------|------------------------------------------------------------------|
| `dev`   | `:dev`    | **Auto-deployed** to the single dev tenant by `auto-pull.sh` cron |
| `main`  | `:latest` | **Not auto-deployed.** Ops runs `deploy-all.sh` per client manually |
| any     | `:<sha>`  | Always pushed; reference for rollbacks                           |

## Required GitHub secrets in each app repo

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`
- `WEBHOOK_URL_DEV`  *(optional — instant dev deploy)*
- `WEBHOOK_SECRET`   *(optional — must match `config.env` on the server)*
