# Deployment observability slice

This repository's first observability slice is intentionally bounded:

- The dashboard writes structured `log/slog` events to stdout/stderr.
- Error events record only stable `error_type` values (or bounded context
  cancellation/deadline categories); startup/configuration failures also carry
  stable `error_code` values. Raw error messages are not emitted.
- Recovered handler panics return a generic 500 and log only the panic type
  and correlated request ID; panic values and stack traces are not emitted.
- Production access events contain only request ID, method, route pattern,
  status, duration, and a normalized client IP. Headers, cookies, query
  values, and bodies are not logged.
- Shell entrypoints emit UTC logfmt-style events with severity, script,
  operation ID, and tenant context. Their `ERR` trap does not include the
  failed command text because commands can contain credentials.
- The optional `DEPLOY_LOG_FILE` sink is bounded by `DEPLOY_LOG_MAX_BYTES`,
  retains one rotated `.1` file, truncates oversized messages, and disables
  itself with a console warning if rotation or writing fails.
- Dashboard startup failures report bounded container state and at most
  `DASHBOARD_LOG_TAIL_LINES` recent dashboard-container lines. They do not
  roll back automatically.

## Optional self-hosted profile

The optional `dashboard/docker-compose.observability.yml` profile uses pinned
images:

- Docker socket proxy `tecnativa/docker-socket-proxy:0.1.2` (digest pinned)
- Docker API path filter `nginx:1.27.1-alpine` (digest pinned)
- Grafana Alloy `v1.5.1`
- Loki `3.3.2`
- Prometheus `v3.1.0`
- Grafana `11.5.2`

Start it from `dashboard/` only after creating a protected credentials file:

```bash
cp observability/.env.example observability/.env
# Set OBS_GRAFANA_ADMIN_PASSWORD to a long random value.
docker compose --env-file observability/.env \
  -f docker-compose.observability.yml --profile observability up -d
```

Grafana is bound to `127.0.0.1:${OBS_GRAFANA_PORT:-3000}` and anonymous access
is disabled. Put an operator-managed HTTPS reverse proxy and authentication
policy in front of it if remote access is required. Loki, Prometheus, and
Alloy have no host-published ports and share an internal-only Docker network.
The socket proxy is isolated on a separate private `docker-api` network and
does not join the observability network. Alloy reaches only the pinned,
read-only Nginx path filter, which joins both private networks. The filter allows only ping/version, daemon events, container listing, and
container log paths; container JSON/inspect, archive, attach, exec, all
mutating methods, and all other paths return 403. Alloy does not mount the
host Docker socket.
Alloy is filtered to explicitly labelled dashboard containers; raw tenant
application logs are not sent to Loki by this profile.

Alloy positions are stored under `/var/lib/alloy` on the named
`ifritah-observability-alloy` volume, so collector recreation resumes from
existing Docker log offsets instead of replaying the full stream.

Retention and resource defaults are deliberately modest:

| Component | Retention / limit | Starting resource budget |
|---|---|---|
| Docker socket proxy | Docker log driver: 10 MiB × 3 files | 0.25 CPU / 128 MiB |
| Docker API path filter | Docker log driver: 10 MiB × 3 files | 0.25 CPU / 128 MiB |
| Alloy | Persistent positions; Docker log driver: 10 MiB × 3 files | 0.5 CPU / 256 MiB |
| Loki | 7 days, query cap 5,000 entries | 1 CPU / 1 GiB |
| Prometheus | 7 days or 5 GiB (whichever comes first) | 1 CPU / 512 MiB |
| Grafana | Docker log driver: 10 MiB × 3 files | 1 CPU / 512 MiB |

The named Loki, Prometheus, and Grafana volumes need approximately 20 GiB of
free disk for this starting profile. Monitor host disk usage and lower
`OBS_PROMETHEUS_RETENTION_*` or the Loki `retention_period` when the dashboard
is busy. Docker volume quotas are host/storage-driver concerns and should be
enforced by the operator where supported.

## Parallel OpenObserve deployment-only pilot

OpenObserve is available as a separate, operator-only pilot in
[`dashboard/docker-compose.openobserve.yml`](../dashboard/docker-compose.openobserve.yml)
with the `openobserve` profile. Its runbook is
[`docs/runbooks/openobserve-pilot.md`](runbooks/openobserve-pilot.md).
The pilot uses the pinned OpenObserve `v1.0.3` image, a persistent `/data`
volume, a private internal network, loopback-only host publication by default,
native root credentials from the ignored `dashboard/observability/openobserve.env`,
and bounded retention/resource settings.

This is intentionally parallel to the Loki/Grafana profile above. It does not
change the existing Loki/Grafana Compose file. Tenant application wiring is
explicitly opt-in through `OPENOBSERVE_TENANT_TELEMETRY_ENABLED=false` in
`config.env`; when enabled, lifecycle scripts attach both tenant apps to the
fixed internal `ifritah-observability-openobserve` network and configure only
private, authenticated OTLP trace export to
`http://alloy-openobserve:4318/v1/traces`. The protected
`OPENOBSERVE_TENANT_OTLP_TOKEN` is required by both the Alloy receiver and
tenant app wiring; caller-provided OTLP service/tenant identity is overwritten
or rejected at the shared receiver. Docker logs remain collector-side Docker
API ingestion, not an application OTLP log exporter. The
versioned operator UI bundle in
`dashboard/observability/openobserve/` can be applied after the service starts;
it provisions the contract streams, an operator dashboard, saved views, and
disabled alert templates without storing notification credentials. Keep
Loki/Grafana as the supported operator observability path until the pilot is
reviewed.

## Metrics and tracing extension points

This slice does not add a Prometheus client or OpenTelemetry SDK. The
deployment repository only supplies bounded standard OTEL environment values;
the backend instrumentation owns SDK behavior, and the frontend values are
reserved for a future restored frontend worktree. Prometheus currently scrapes
Alloy and the observability services only; it does not scrape tenant
applications.
The dashboard access middleware exposes a tested
`web.RequestObserver` callback so a future metrics/tracing adapter can add
bounded counters and spans without changing request redaction or route
correlation. Any future `/metrics` endpoint must keep tenant IDs, request IDs,
trace IDs, user IDs, resource IDs, and arbitrary error strings out of labels.

## Operator dashboards and alerts

The profile provisions two read-only dashboards into the `Ifritah Operations`
folder:

- **Ifritah Operations Overview** — health of Alloy, Loki, Prometheus, and
  Grafana; recent dashboard error count; and the structured event stream.
- **Ifritah Log Operations** — dashboard log volume, error volume, and the
  searchable JSON log stream.

The Prometheus scrape configuration is private-network-only and covers the
four observability services. Grafana also provisions three managed alert rules:

| Alert | Default severity | Trigger | First action |
|---|---|---|---|
| Observability component is down | critical | Any private component is not scraped for 5 minutes | Check the component container state and recent logs |
| Dashboard error logs detected | warning | Error-level dashboard events continue for 10 minutes | Open the structured log stream and correlate `error_type`, `error_code`, and `request_id` |
| Dashboard panic recovery detected | critical | A recovered HTTP panic persists for 5 minutes | Preserve the request ID, inspect the matching request, and verify dashboard health |

Rules are deliberately provisioned without a default notification destination.
This keeps a fresh installation from silently sending data to an unknown
address and preserves the internal-only network boundary. To enable an
approved destination, set the optional SMTP or Slack variables in
`observability/.env`, copy the templates from
`dashboard/observability/grafana/alerting-templates/` into the ignored
`dashboard/observability/grafana/provisioning/alerting/` directory, remove
unused receivers, and recreate Grafana. The SMTP values are only used by
Grafana when an operator explicitly installs a contact point. Do not reuse
`ACME_EMAIL`: that value is for certificate registration, not alert delivery.
The backend's `email_enabled` setting is a per-user application preference,
not an operator SMTP destination; no Slack webhook or operator SMTP
credential was present in the allowed worktrees, so it is not repurposed.

The observability network is intentionally declared `internal: true`, so the
profile does not gain unrestricted internet egress. If Slack or SMTP delivery
is required, the operator must provide a reviewed, firewall-allow-listed
egress path (for example a notification relay) and document that change before
attaching Grafana to it.

## External uptime monitoring

No uptime provider account or API credential is present in the allowed
worktrees, so no live monitor was created. The provider-neutral
`dashboard/observability/uptime/monitor.example.json` file and
[`docs/runbooks/external-uptime-monitoring.md`](runbooks/external-uptime-monitoring.md)
describe the safe integration boundary:

- probe a public tenant `/healthz` endpoint over HTTPS;
- require status `200`, body `ok`, and certificate validation;
- never probe Grafana, Loki, Prometheus, `/metrics`, or the Docker API;
- keep provider tokens in the provider secret store or an operator environment,
  never in this repository.

## Operational runbooks

- [`docs/runbooks/observability-operations.md`](runbooks/observability-operations.md)
  — start, verify, access, retain, back up, and safely recreate the stack.
- [`docs/runbooks/alert-triage.md`](runbooks/alert-triage.md) — triage each
  provisioned alert and validate notification delivery.
- [`docs/runbooks/external-uptime-monitoring.md`](runbooks/external-uptime-monitoring.md)
  — configure a provider when credentials and an approved provider are
  available.
