# OpenObserve parallel pilot runbook

This runbook starts the deployment-only OpenObserve pilot. It is deliberately
parallel to the existing Loki/Grafana profile and does not change that profile.
The profile includes an allow-listed Docker log collector, private OTLP intake,
bounded gateway delivery, and host/container resource signals. Tenant
application trace export is enabled separately and explicitly by the lifecycle
scripts. Versioned
operator UI provisioning artifacts are included under
`dashboard/observability/openobserve/`; they do not expose OpenObserve through
the deployment dashboard. The normative field, redaction, retention, and
failure-behavior contract is
[`docs/observability-openobserve-contract.md`](../observability-openobserve-contract.md).

## Prepare credentials and configuration

From the deployment checkout:

```sh
cd dashboard
cp observability/openobserve.env.example observability/openobserve.env
chmod 600 observability/openobserve.env
```

Edit `observability/openobserve.env` and replace
`ZO_ROOT_USER_PASSWORD` with a long, unique password. The
`ZO_ROOT_USER_EMAIL` and `ZO_ROOT_USER_PASSWORD` values are the native
OpenObserve root-user settings; do not put them in `config.env`, a shell
history, or this repository.

Set `OPENOBSERVE_TENANT_OTLP_TOKEN` to a separate random printable token.
The same value must be supplied through the protected deployment `config.env`
when tenant telemetry is enabled. It is used by Alloy's private OTLP
receiver for Basic authentication; do not print it with `dokku config:get`,
place it in a tracked file, or reuse the OpenObserve root password.

The defaults are intentionally conservative:

| Setting | Default | Boundary |
|---|---:|---|
| `OBS_OPENOBSERVE_BIND` | `127.0.0.1` | Host publication is loopback-only |
| `OBS_OPENOBSERVE_PORT` | `5080` | Only the UI/API port is host-published |
| `OBS_OPENOBSERVE_RETENTION_DAYS` | `14` | Local telemetry retention |
| `OBS_OPENOBSERVE_MEMORY_LIMIT` | `1g` | Container memory limit |
| `OBS_OPENOBSERVE_CPUS` | `1.00` | Container CPU limit |
| `OBS_OPENOBSERVE_PIDS_LIMIT` | `256` | Container process limit |
| `OBS_OPENOBSERVE_QUEUE_MAX_BYTES` | `67108864` | Gateway disk queue cap per signal |
| `OBS_OPENOBSERVE_MAX_BODY_BYTES` | `4194304` | Maximum OTLP request body |
| `OBS_OPENOBSERVE_RESOURCE_POLL_INTERVAL` | `15s` | Resource exporter poll interval |

Do not bind the UI edge to `0.0.0.0` unless an operator-approved firewall and
authenticated TLS reverse-proxy path are in place. OpenObserve and telemetry
services remain on internal-only networks; a dedicated Nginx UI edge owns the
single configurable host port. The gRPC/OTLP port is exposed only to services
on the internal network and is not published to the host.

The ignored env example sets
`OBS_OPENOBSERVE_IGNORE_STREAM_RETENTION=false`, so the stream-specific
retention values below apply. If an older protected
`observability/openobserve.env` file still has this setting enabled, change it
to `false` and recreate the service. Do not commit that file.

## Pilot safety gates

Treat this as a deployment-only, operator-only pilot until the Docker-backed
acceptance scenarios in the telemetry contract are reviewed. Before starting
the profile:

1. Record the approved host, image digest, retention decision, operator owner,
   and change/rollback owner. Do not use this profile as the authoritative
   accounting, tenant-state, migration, backup, or security-audit store.
2. Keep the existing Loki/Grafana profile available in parallel. This pilot
   must not replace it, publish a public OpenObserve endpoint, or become part
   of a production rollout without a separate reviewed change.
3. Keep `OPENOBSERVE_TENANT_TELEMETRY_ENABLED=false` until the private profile
   is healthy. Tenant trace wiring is a second, explicit opt-in and must use
   only the fixed internal network.
4. Confirm the loopback UI edge bind, `Internal=true` core/ingest networks, and
   absence of host-published OTLP/collector ports before connecting any tenant. Never
   paste rendered Compose configuration into a ticket because it can contain
   environment-file values.
   The required absence of host-published OTLP/collector ports is a release
   gate.
5. Keep alert templates disabled and do not create an external notification
   destination until the first no-data/health checks pass. Enable at most one
   reviewed alert during the initial pilot window.

The static OpenObserve contract tests inspect these files and commands only;
they do not start Docker services, make API calls, or deploy production.

## Validate and start

The image is pinned to the OpenObserve `v1.0.3` release and its immutable
multi-architecture manifest digest in
`dashboard/docker-compose.openobserve.yml`. Review any image or retention
change before applying it.

```sh
docker compose --env-file observability/openobserve.env \
  -f docker-compose.openobserve.yml --profile openobserve config >/dev/null
docker compose --env-file observability/openobserve.env \
  -f docker-compose.openobserve.yml --profile openobserve up -d
docker compose --env-file observability/openobserve.env \
  -f docker-compose.openobserve.yml --profile openobserve ps
```

If startup reports `dependency failed to start`, inspect the root
`openobserve` service rather than the dependent gateway or Alloy services:

```sh
bash scripts/diagnose-openobserve.sh
```

This read-only diagnostic prints Compose status, the OpenObserve startup log,
and the container healthcheck history. It does not print the env file or
change any service.

Do not paste `docker compose config` output into an issue: it can render
environment-file values.

The service healthcheck uses OpenObserve's native `node status` command because
the pinned image is distroless and does not include a shell, `curl`, or `wget`.
The public liveness endpoint is also useful for an operator-side check:

```sh
curl --fail --silent --show-error \
  "http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}/healthz"
```

Open the UI at `http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}` and sign in with
the native root credentials. For remote administration, use an SSH tunnel
instead of changing the default bind:

```sh
ssh -N -L 5080:127.0.0.1:5080 operator@server
```

The profile builds the two small deployment-only Go images locally from pinned
builder bases. No image registry or production rollout is part of this
workstream. The collector exposes no host ports. OpenObserve, gateway, Docker
API, exporters, and health endpoints stay on the internal
`ifritah-observability-openobserve-core` network. The dedicated Nginx UI edge is
the only host-published service and is attached to core plus its isolated
publish network. Tenant applications join only
`ifritah-observability-openobserve-ingest`; Alloy is the sole bridge between
core and ingest.

## Opt in tenant applications

Application wiring is disabled by default. Start and health-check the profile
first, then edit the deployment checkout's protected `config.env`:

```sh
OPENOBSERVE_TENANT_TELEMETRY_ENABLED=true
OPENOBSERVE_NETWORK_NAME=ifritah-observability-openobserve-ingest
```

The lifecycle scripts accept only that exact, approved Docker network name.
They verify `Internal=true` before using an existing network and create a
matching `--internal` bridge network if the profile has not created it yet.
They never configure OpenObserve credentials or a public OTLP endpoint.
Existing Dokku `attach-post-deploy` networks are preserved when telemetry is
enabled and restored when telemetry is disabled; the reconciler does not
clear unrelated cross-application network attachments.

For a new tenant, the normal create path applies the wiring automatically:

```sh
sudo bash scripts/create-tenant.sh acme --config /opt/deployment/config.env
```

For an existing tenant, use a routing-only update to apply the network hook,
trace environment, and live-container connection without changing images:

```sh
sudo bash scripts/update-tenant.sh acme --routing-only \
  --config /opt/deployment/config.env
```

Run that command once per existing tenant, or use the fleet repair script
when a controlled rebuild of both apps is acceptable:

```sh
sudo bash scripts/post-merge-cleanup.sh acme
```

The backend receives only private, authenticated OTLP HTTP trace settings:
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://alloy-openobserve:4318/v1/traces`,
`OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic ...`,
`OTEL_TRACES_EXPORTER=otlp`,
`OTEL_EXPORTER_OTLP_TRACES_INSECURE=true`, service/resource identity, and
bounded batch/sampling defaults. The frontend receives the same future-ready
container environment and network attachment, but this does **not** claim that
browser instrumentation exists. Docker logs continue to arrive through the
collector's Docker API path; no OTLP log exporter is added to tenant apps.
The shared OTLP receiver authenticates the deployment token, overwrites
caller-provided `service.name` with the bounded `ifritah-tenant` identity, and
does not export caller-provided `tenant.id`. Tenant identity in Docker logs
comes from the collector's allow-listed container metadata instead of an OTLP
payload.

Verify the private boundary and backend values:

```sh
docker network inspect ifritah-observability-openobserve-ingest \
  --format '{{.Internal}}'                  # must print true
docker network inspect ifritah-observability-openobserve-core \
  --format '{{.Internal}}'                  # must print true
dokku config:get acme-backend OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
dokku config:get acme-backend OTEL_TRACES_EXPORTER
dokku config:get acme-backend OTEL_EXPORTER_OTLP_TRACES_INSECURE
# Verify the auth key exists without printing its value:
dokku config:report acme-backend | grep -Fq 'OTEL_EXPORTER_OTLP_HEADERS=' \
  && echo "OTLP auth header configured"
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '4317|4318' || true
```

The last command must not show a host-published OTLP port. If the collector
profile is stopped, the scripts emit a warning and preserve the tenant deploy;
the application exporter fails asynchronously and does not call OpenObserve
on the request path.

## Disable, rollback, and remove wiring

To disable the pilot for future lifecycle operations, set
`OPENOBSERVE_TENANT_TELEMETRY_ENABLED=false` in `config.env`. Run the
routing-only update for each wired tenant so the marker environment, OTLP
values, persistent Dokku hook, and live-container network attachment are
removed:

```sh
sudo bash scripts/update-tenant.sh acme --routing-only \
  --config /opt/deployment/config.env
```

If a telemetry change causes an application issue, disable the flag and run
the same command before using the existing image rollback procedure:

```sh
sudo bash scripts/rollback-tenant.sh acme --type backend \
  --to myuser/ifritah-api:known-good --config /opt/deployment/config.env
```

Do not remove the named OpenObserve network while any tenant or collector is
attached. Stop the profile without `--volumes`, detach wired tenants, and
remove the network only after `docker network inspect` shows no containers.
If Dokku rejects the network setter during disablement, the scripts retain the
telemetry marker and OTLP configuration and return a failure so the same
disable operation can be retried safely. The named OpenObserve data and
gateway volumes are independent of tenant app rollback.

## Verify collector, queues, and resource signals

The pipeline topology is:

```text
allow-listed Docker logs ─┐
private application OTLP ─┼─> Alloy ─> gateway queues ─> OpenObserve
node-exporter/resources ──┘       └─> private health metrics
```

Only the OpenObserve Alloy instance reads the filtered Docker API. It accepts
dashboard containers carrying `com.ifritah.observability=dashboard` and tenant
containers named `<tenant>-backend` or `<tenant>-frontend`; arbitrary
containers are rejected. The Docker socket is mounted only into the
read-only socket proxy, followed by an Nginx method/path filter. The resource
exporter aggregates by `container_role` and never emits container, tenant,
request, trace, or resource IDs as metric labels.

Check the private services and bounded health metrics from inside the profile
network (do not publish these ports for convenience):

```sh
docker compose --env-file observability/openobserve.env \
  -f docker-compose.openobserve.yml --profile openobserve ps
docker compose --env-file observability/openobserve.env \
  -f docker-compose.openobserve.yml --profile openobserve logs --tail=100 \
  openobserve-gateway alloy-openobserve resource-exporter-openobserve
```

The gateway exposes `/healthz`, `/readyz`, and `/metrics` only to the private
network. Its `ifritah_gateway_queue_bytes{signal=...}` and
`ifritah_gateway_queue_files{signal=...}` metrics show durable queue pressure;
`ifritah_gateway_forward_failures_total`,
`ifritah_gateway_auth_blocked`, and drop counters show delivery failures
without exposing payloads. Logs, metrics, and traces have separate queue
directories and each is capped at `OBS_OPENOBSERVE_QUEUE_MAX_BYTES` (64 MiB by
default). Retry backoff is capped at 30 seconds. Health metrics are accepted
on the gateway's private `/v1/health` intake and forwarded to native
per-metric OpenObserve streams. The collector health scrape has its own
receiver, sanitization, batch, exporter, and gateway queue; it is not also
sent through the ordinary metrics exporter.

If OpenObserve is unavailable, Alloy and the gateway retry within their
bounds, then drop records after the configured caps. A `401`/`403` pauses
normal retry amplification and sets the auth-blocked health metric. No
application request calls OpenObserve synchronously; stdout/stderr logging
continues while telemetry is down. Repair credentials or storage/network
health, then verify queue depth and last-success metrics before closing the
incident.

## Provision the operator UI

The provisioning bundle is deterministic and versioned in
`dashboard/observability/openobserve/`:

| Artifact | Purpose |
|---|---|
| `streams.json` | Two contract streams plus the dedicated native health-metric policy |
| `dashboards/ifritah-operator.json` | Operator dashboard import |
| `saved-views.json` | Request/trace, error, deployment, resource, and pipeline searches |
| `alerts.json` | Disabled SQL and PromQL alert templates with an external destination placeholder |
| `notifications.example.json` | Placeholder-only notification wiring example |
| `apply-openobserve.sh` | Authenticated stream/dashboard/saved-view/alert apply |

The alert bundle preserves the existing request, exception, authentication,
deployment, latency, collector, and OpenObserve-health templates and adds
disabled-by-default coverage for container memory, filesystem/free-space,
container restart loops, host memory and host-metric health,
resource-exporter heartbeat/scrape health, and telemetry-gateway
heartbeat/failure/authentication health. Cumulative counters use bounded
ten-minute deltas; heartbeat alerts also fire when no healthy sample exists.
Resource thresholds are conservative pilot defaults (absolute bytes or bounded
counter changes); operators must tune and review them against the host and
container budgets before enabling a destination. No alert is enabled by
importing the JSON. Resource-exporter scrape errors include Docker list,
inspect, and stats collection failures; investigate those before treating
missing container metrics as application health.

The script requires `curl`, `python3`, an explicit endpoint, organization, and
operator credentials. It does not assume dashboard proxying and it never
creates a notification destination:

```sh
cd dashboard
set -a
. observability/openobserve.env
set +a
OPENOBSERVE_ENDPOINT="http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}" \
OPENOBSERVE_ORG="default" \
OPENOBSERVE_USER="$ZO_ROOT_USER_EMAIL" \
OPENOBSERVE_PASSWORD="$ZO_ROOT_USER_PASSWORD" \
  observability/openobserve/apply-openobserve.sh
```

When credentials come from a file-mounted secret, set
`OPENOBSERVE_PASSWORD_FILE` instead of placing the password in a shell
environment variable. The file must contain only the OpenObserve password and
must be readable by the operator process.

Use OpenObserve organization roles or the operator's reverse-proxy policy to
keep the UI, saved views, dashboards, streams, and alerts operator-only. The
deployment dashboard must not proxy these resources to tenant users.

The default apply creates or updates the two contract streams, applies
retention to discovered native metric streams, and updates the
`Ifritah OpenObserve Operations` dashboard and saved views. Alert templates
are skipped until an operator configures a destination outside this repository.
When alert application is explicitly enabled, existing saved views and alerts
are updated by their API IDs rather than silently skipped. Existing alert
enablement is preserved unless `OPENOBSERVE_ENABLE_ALERTS=true` and the alert
name is explicitly selected; the configured destination is always required and
never created by this script. Listing failures fail closed instead of creating
duplicates. Malformed JSON or schema-invalid successful dashboard, saved-view,
or alert list responses also fail closed instead of being treated as empty.
The apply is idempotent by default: it updates the dashboard found
by title and does not delete an existing dashboard. Leave
`OPENOBSERVE_REPLACE_DASHBOARD=false` for normal applies; set it to `true` only
for an approved replacement that records the old dashboard ID and hash.
If a change record requires a manual dashboard import, use the OpenObserve
operator UI's dashboard import action with
`dashboards/ifritah-operator.json`; still apply streams and saved views with
the script so their retention and bounded search state remain versioned.
If the UI import is used, verify the imported title and panels before running
the script. Do not use a manual import as a substitute for stream or saved-view
provisioning.

### External notification wiring

Create the external notification destination in OpenObserve's operator-managed
destination UI/API or in the approved external notification relay. The
destination's webhook, SMTP, PagerDuty, or relay secret must remain in that
system's secret store; `notifications.example.json` contains only a
destination-name and secret-reference placeholder. The apply script never
creates destinations or copies their credentials.
Use an operator-managed destination only; do not add a delivery credential to
this repository or to tenant application configuration.

After the destination exists, record its exact name and secret reference in the
change record, send a controlled test notification to the operator route, and
apply the disabled alert definitions:

```sh
OPENOBSERVE_APPLY_ALERTS=true \
OPENOBSERVE_ALERT_DESTINATION_NAME="operator-configured-destination" \
OPENOBSERVE_ENDPOINT="http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}" \
OPENOBSERVE_ORG="default" \
OPENOBSERVE_USER="$ZO_ROOT_USER_EMAIL" \
OPENOBSERVE_PASSWORD="$ZO_ROOT_USER_PASSWORD" \
  observability/openobserve/apply-openobserve.sh
```

Keep `OPENOBSERVE_ENABLE_ALERTS=false` for the first apply and confirm that
every imported alert is disabled. Enable a specific alert only after its
threshold, owner, runbook, notification route, and test notification have been
reviewed:

```sh
OPENOBSERVE_ENABLE_ALERTS=true \
OPENOBSERVE_ALERT_NAMES="Ifritah - Elevated 5xx responses" \
OPENOBSERVE_APPLY_ALERTS=true \
OPENOBSERVE_ALERT_DESTINATION_NAME="operator-configured-destination" \
OPENOBSERVE_ENDPOINT="http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}" \
OPENOBSERVE_ORG="default" \
OPENOBSERVE_USER="$ZO_ROOT_USER_EMAIL" \
OPENOBSERVE_PASSWORD="$ZO_ROOT_USER_PASSWORD" \
  observability/openobserve/apply-openobserve.sh
```

The request, trace, and tenant-latency saved views intentionally contain
bounded replacement values (`REQUEST_ID_VALUE`, `TRACE_ID_VALUE`, and
`TENANT_ID_VALUE`). Replace those values in the OpenObserve query editor with
validated incident identifiers; do not add request bodies, raw URLs, raw
application SQL text, credentials, or arbitrary error strings.
The dashboard and searches use record fields, not metric labels or stream
partitions.

The artifact retention defaults are 14 days for logs, 7 days for traces,
15 days for native metric streams, and 14 days for telemetry health. Native
metrics create one OpenObserve stream per metric family, so dashboards and
alerts use PromQL instead of querying a synthetic aggregate stream. The
provisioning script applies 15-day retention to existing streams whose names
are exact members of the `approved_metric_families` groups (`backend`,
`resource`, and `health`) in `streams.json`; rerun it after a new approved
metric family first appears. Verify effective values in stream settings after
applying them. The Compose profile's global retention value
remains unchanged by this workstream; the protected env setting above is what
allows per-stream values to apply.
If the pinned OpenObserve build still treats the global value as a shorter cap,
record the approved retention decision and update the deployment profile in a
separate reviewed change rather than silently claiming the per-stream value is
effective.

## Verify provisioning

With the same operator credentials, verify the health endpoint and inspect the
stream, dashboard, saved-view, and alert lists:

```sh
curl --fail --silent --show-error \
  "http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}/healthz"
curl --fail --silent --show-error -u "$ZO_ROOT_USER_EMAIL:$ZO_ROOT_USER_PASSWORD" \
  "http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}/api/default/streams"
curl --fail --silent --show-error -u "$ZO_ROOT_USER_EMAIL:$ZO_ROOT_USER_PASSWORD" \
  "http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}/api/default/dashboards?folder=default"
curl --fail --silent --show-error -u "$ZO_ROOT_USER_EMAIL:$ZO_ROOT_USER_PASSWORD" \
  "http://127.0.0.1:${OBS_OPENOBSERVE_PORT:-5080}/api/default/savedviews"
```

Open the dashboard and confirm that the request/trace, 5xx, panic/exception,
deployment/auth, resource, collector, and OpenObserve panels show either
bounded data or an explicit no-data state. A clean profile without the
collector will legitimately have no telemetry records. This repository does
not claim live API or Docker validation unless an operator runs these checks
against the pinned service.

## Storage, retention, and backups

OpenObserve writes local-mode metadata, WAL, and stream data under `/data` in
the named volume `ifritah-observability-openobserve-data`. Do not remove that
volume during a routine restart. Check disk pressure before changing retention:

```sh
docker system df -v
docker volume inspect ifritah-observability-openobserve-data
docker compose --env-file observability/openobserve.env \
  -f docker-compose.openobserve.yml --profile openobserve logs --tail=100 openobserve
```

The pilot applies the configured global retention to compaction and ignores
per-stream retention overrides. Keep the value within the approved operational
telemetry range (14–30 days unless a reviewed change record says otherwise).
Retention deletion is delayed by `OBS_OPENOBSERVE_DELETE_DELAY_HOURS`; it is not
a backup policy.

Before an upgrade or destructive maintenance, stop ingestion (once a collector
exists), take the approved volume/filesystem backup, and record the image
digest, retention value, and volume snapshot. Never treat OpenObserve as the
authoritative accounting, tenant-state, migration, backup, or security-audit
store.

## Restart, upgrade, and stop

For a routine configuration restart:

```sh
docker compose --env-file observability/openobserve.env \
  -f docker-compose.openobserve.yml --profile openobserve up -d \
  --force-recreate openobserve
```

For an approved image upgrade, update both the release tag and immutable digest
in the Compose file, run the focused profile test and `docker compose config`,
then recreate the service. Keep the named volume and verify `/healthz` and the
native healthcheck before closing the change.

To stop the pilot without deleting data:

```sh
docker compose --env-file observability/openobserve.env \
  -f docker-compose.openobserve.yml --profile openobserve down
```

Do not add `--volumes` unless data loss and the retention impact are explicitly
approved.

## Rollback and removal

To roll back a UI-only apply, first disable any alerts that were deliberately
enabled, remove the external notification binding from the operator-managed
destination, and disable tenant trace wiring before removing shared network
attachments. Then remove only the resources created by this bundle from the
operator UI or API:

1. Delete `Ifritah OpenObserve Operations`.
2. Delete the saved views whose names start with `Ifritah -`.
3. Stop or reroute the collector before deleting any contract stream.
4. Delete `ifritah_logs_v1`, `ifritah_traces_v1`, and
   `ifritah_telemetry_health_v1` only when the resulting telemetry loss is
   approved. Remove native metric streams whose names exactly match the
   `approved_metric_families` policy only when metric history loss is approved.

Do not delete the named `/data` volume for a UI rollback. Preserve the image
digest, artifact version, and resource IDs in the change record. A service
restart or `docker compose ... down` without `--volumes` leaves the data
available for a later re-apply. For full profile removal, first stop the
collector, inspect both `ifritah-observability-openobserve-ingest` and
`ifritah-observability-openobserve-core`, and remove them only when their
container lists are empty:

```sh
docker network rm ifritah-observability-openobserve-ingest
docker network rm ifritah-observability-openobserve-core
```

Never remove the named data, gateway, or Alloy volumes as part of a routine
rollback. Volume deletion is a separate, explicitly approved destructive
operation after an export/backup decision.

## Scope boundary

This profile provides the private, persistent OpenObserve service plus
operator-applied UI provisioning artifacts, the deployment Alloy collector,
bounded gateway queues, and least-privilege host/container resource signals.
The deployment worktree also provides opt-in tenant network and trace-export
environment wiring; the backend instrumentation remains owned by the backend
worktree, and browser instrumentation is not claimed here. There is still no
dashboard proxy. Keep the existing Loki/Grafana profile unchanged and
available in parallel. Runtime production ingestion remains out of scope until
the pilot and Docker-dependent acceptance scenarios are reviewed.
