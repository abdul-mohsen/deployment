# Research: ZATCA Daemon Deployment Service

## Baseline evidence

| Area | Evidence from `aea7b6e` | Decision |
|---|---|---|
| Deployment service layout | `dashboard/docker-compose.dev.yml` and `dashboard/docker-compose.prod.yml` run the dashboard; `scripts/restart-stack.sh` owns stack restart order. | Keep dashboard compose behavior unchanged and add the daemon through a dedicated compose overlay managed by existing scripts. |
| Existing NATS | `scripts/setup-nats.sh` runs a standalone `nats:2-alpine -js` container on host port `4222`; `scripts/create-tenant.sh` defaults backend `NATS_URL` to `nats://host.docker.internal:4222`. | The T008 daemon's embedded JetStream must own the shared client port when enabled. Existing standalone NATS remains available when the daemon is disabled; the setup script must reject/avoid a port conflict rather than silently create a second broker. |
| Backend contract | `templates/backend/docker-compose.yml` uses explicit `environment` overrides and `depends_on` health conditions; backend runtime documentation uses `NATS_URL`. | Preserve the host-reachable NATS URL contract and make the configured `ZATCA_NATS_URL` the tenant default. |
| Tenant database contract | `config.env.example` and `install.env.example` define `MYSQL_HOST`, `MYSQL_PORT`, and `MYSQL_MASTER_DB`; `create-tenant.sh` registers `tenant_<name>` databases in the master registry. | Map these shared host/database values into the daemon, but use a dedicated operator-supplied daemon DB account instead of the deployment admin account. |
| Persistent storage | `STORAGE_ROOT` is the deployment's persistent host root for tenant files; dashboard production already bind-mounts it. | Use separate configurable `ZATCA_XML_ROOT` and `ZATCA_NATS_DATA_ROOT` bind paths, defaulting under the operator's persistent storage convention, so daemon data survives recreation without exposing all tenant files. |
| Daemon runtime | T008 `docker-compose.yml` requires `DB_PASS`, `ENCRYPT_KEY`, and `MONITOR_PASS`; starts the daemon with embedded JetStream and exposes NATS `4222` plus authenticated monitoring `8222`. | Reuse the T008 variable names inside the container and map deployment-prefixed config names to them. Do not copy SDK files or fabricate credentials in deployment. |
| Health contract | T008 daemon wraps the NATS monitor with Basic Auth and exposes the NATS `/healthz` endpoint through the monitor port. The backend image uses a real GET health check rather than HEAD. | Compose healthcheck uses authenticated GET `/healthz` on the daemon's internal monitor endpoint; monitor host binding is loopback-only. |
| Command/test conventions | Shell tests live in `scripts/tests/test-*.sh`; `deployctl.sh` maps stable command areas to scripts; `run-all.sh` discovers shell tests automatically. | Add one focused shell contract test, a `setup zatca` command mapping, and a dedicated setup script. |

## Dependent T008 contract

The dependent ZATCA repository's daemon image (inspected at
`C:\ssda\chatGPT\worktrees\zatca-fix-t008-zatca`) contains:

- an executable daemon entrypoint;
- an embedded NATS server with JetStream;
- `--nats-data=/data/nats` and `--nats-monitor=8222` runtime flags;
- MySQL inputs `DB_USER`, `DB_PASS`, `DB_HOST`, `DB_PORT`, `MASTER_DB`;
- optional onboarding admin inputs `ADMIN_DB_USER`, `ADMIN_DB_PASS`;
- required `ENCRYPT_KEY` and authenticated `MONITOR_PASS`;
- `/data/zatca-xml` signed XML storage.

The image Dockerfile supplies the Java runtime and Fatoora SDK artifact. The
deployment repository must therefore consume an image reference and document
that build/runtime prerequisite; it must not copy or manufacture the SDK.

## Resolved unknowns

1. **Where does the service live?** A dedicated
   `dashboard/docker-compose.zatca.yml` overlay avoids making existing
   dashboard-only commands require new secrets while remaining a first-class
   deployment service managed by `deployctl` and `restart-stack`.
2. **Which NATS instance is shared?** The daemon's embedded JetStream is the
   single service of record when enabled. Backend tenants use the host-published
   port through `host.docker.internal`; the old standalone NATS path remains
   the compatibility path only when the daemon is disabled.
3. **Which database credentials are used?** The daemon receives dedicated
   `ZATCA_DB_USER`/`ZATCA_DB_PASSWORD` values. Existing `MYSQL_ROOT_*` values
   remain deployment/orchestration credentials and are not injected into the
   daemon.
4. **How is health checked?** The deployment checks the authenticated T008
   monitor's `/healthz` endpoint from inside the container. No new daemon API is
   invented in this repository.

## Remaining uncertainty

The exact registry and tag for the approved T008 image is release-specific.
It remains an explicit operator input (`ZATCA_DAEMON_IMAGE`) and is not
defaulted to a real registry or credential.
