# Afrita OpenObserve telemetry contract

**Status:** deployment profile and deployment collector/resource pipeline
implemented; application instrumentation remains separate
**Schema version:** `1`
**Audience:** deployment and application operators, backend/frontend owners, and
the telemetry pipeline owner

This document defines the telemetry contract for the Afrita OpenObserve
streams. The separate deployment-only OpenObserve profile at
`dashboard/docker-compose.openobserve.yml` provides private persistent
storage, native operator credentials, an allow-listed Docker log collector,
private OTLP intake, bounded gateway delivery, and least-privilege host and
container resource signals. Application instrumentation and application OTLP
export configuration remain separate workstreams. The current operator-only
Loki/Grafana profile remains in place and keeps its existing retention and
network decisions.

The contract covers:

- tenant-safe structured logs;
- request and distributed-trace correlation;
- deployment/control-plane events;
- OpenTelemetry traces and metrics;
- host and container resource signals;
- collector failure and backpressure behavior; and
- reviewable acceptance scenarios.

The words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative.

## 1. Invariants and boundaries

1. **Telemetry is diagnostic, not authoritative.** OpenObserve is not the
   source of truth for accounting, tenant state, migrations, backups, or
   security audit records. A telemetry drop MUST NOT change an application
   response or a deployment/database decision.
2. **Access is operator-only.** OpenObserve, its collector, and telemetry
   storage MUST be private by default. If an operator publishes a UI through a
   reverse proxy, the proxy MUST enforce operator authentication, TLS, and
   network policy. The deployment dashboard MUST NOT proxy OpenObserve or
   expose raw telemetry to tenant users.
3. **One egress path.** The collector is the only telemetry egress component.
   Applications MUST write JSON logs to stdout/stderr and use a bounded OTLP
   exporter for traces and metrics. Applications MUST NOT send telemetry
   directly to a public OpenObserve endpoint.
4. **Tenant identity is trusted context only.** A tenant field is added only
   after server-side authentication, tenant-directory lookup, or a deployment
   script has validated and normalized the tenant. A request body, query
   parameter, arbitrary header, or unverified host value MUST NOT set
   `tenant_id`.
5. **Redaction happens twice.** Producers MUST omit or redact sensitive data at
   source. The collector MUST apply the same deny-list and size limits before
   export. A collector redaction failure is a telemetry pipeline failure, not a
   reason to forward the unredacted record.
6. **High-cardinality investigation belongs in fields, not labels.**
   `tenant_id`, request IDs, trace IDs, actor IDs, resource IDs, operation IDs,
   image digests, and error details MAY be searchable record fields when
   approved below. They MUST NOT be stream labels, resource labels, or metric
   labels.
7. **The telemetry path fails open.** Collector or OpenObserve unavailability
   MUST NOT block, crash, restart, or make a tenant application unavailable.
   Bounded loss is preferable to unbounded memory, disk growth, or request
   latency.
8. **Audit/security records remain separate.** The existing decision to define
   a separate audit/security policy is preserved. A security event MAY be
   correlated with telemetry, but OpenObserve retention and operator logs MUST
   NOT be treated as an immutable audit archive.
9. **Network roles are separated.** Tenant applications MUST join only
   `ifritah-observability-openobserve-ingest`. OpenObserve, the gateway, the
   filtered Docker API, exporters, and collector storage MUST join only
   `ifritah-observability-openobserve-core`. Alloy MAY join both networks and
   is the only bridge. Its admin listener MUST bind loopback inside the
   container; tenant applications MUST NOT reach gateway, Docker API,
   exporter, health, or OpenObserve ports.

## 2. Signals and stream names

The implementation SHOULD use these OpenObserve streams. The suffix is the
contract version and is not a tenant name:

| Stream | Signal | Contents | Default pilot retention |
|---|---|---|---:|
| `ifritah_logs_v1` | Logs | JSON application, dashboard, and deployment events | 14 days |
| `ifritah_traces_v1` | Traces | OTLP spans and span events | 7 days |

Native OpenObserve OTLP metrics are stored in one metrics stream per metric
family, not in one arbitrary aggregate stream. Metric names are therefore
queried through PromQL. The deployment defines one exact, finite
`approved_metric_families` policy in `streams.json`, grouped by `backend`,
`resource`, and `health`. The direct Prometheus-to-OTel routes reject every
other family, and provisioning applies 15-day retention only to existing
native streams whose names are exact members of that policy. Rerun
provisioning after an approved metric family first appears.

Pipeline health is a native metric signal, not a third log stream. Alloy
scrapes only the allow-listed collector and gateway health endpoints through
the dedicated `collector_health` receiver, health processor/batch/exporter,
and private gateway `/v1/health` queue. The gateway maps that ingress to
OpenObserve's native `/v1/metrics` endpoint without a `stream-name` override.
The ordinary application/resource metrics pipeline never receives these
samples, so each health sample has one path and one durable queue.

The pilot defaults are inside the already-approved operating ranges:

- operational logs: **14–30 days**;
- traces: **3–14 days**; and
- metrics: **15–30 days**.

The operator MUST choose the actual production values before enabling
production ingestion. The chosen values MUST be recorded in the deployment
change record and MUST NOT be silently shortened or extended by a collector
upgrade. The current Loki/Grafana profile remains unchanged; its documented
7-day pilot limits are not replaced by this contract.

The streams MUST be physically and logically separate from any future
immutable audit/security stream. Retention deletion MUST be verified after
each OpenObserve upgrade and during routine operations. Backups MUST NOT be
used to extend the approved online telemetry retention without an explicit
retention decision.

## 3. Canonical event envelope

Every log record MUST be a single JSON object. New fields
are additive; a breaking change requires a new stream suffix. Unknown input
fields MUST NOT be copied into the exported record by default.

Pipeline health metrics retain native OTLP metric encoding and are queried by
metric family through PromQL. They MUST use the metric label and retention
rules in sections 7.2 and 8.3; they are not serialized as synthetic JSON log
records.

OpenObserve's `_timestamp` MUST be populated from `event_time`, not from
collector arrival time. Collector arrival time MAY be retained as
`observed_time` for lag diagnosis.

### 3.1 Common fields

| Field | Type and bound | Required | Contract |
|---|---|---:|---|
| `schema_version` | integer, `1` | yes | Envelope version. |
| `event_time` | RFC 3339 UTC string, nanoseconds allowed | yes | Source event time. |
| `observed_time` | RFC 3339 UTC string | no | Collector receipt time. |
| `signal` | enum: `log`, `pipeline` | yes for JSON records | OTLP traces/metrics retain their native signal. |
| `event_type` | lower-case dotted string, max 96 chars | yes | Stable event name, not a free-form sentence. |
| `severity` | `debug`, `info`, `warn`, `error`, `fatal` | yes | Expected validation/rejection is not `error`. |
| `service_name` | approved identifier, max 64 chars | yes | See the service registry below. |
| `service_version` | approved build/version, max 128 chars | yes | `unknown` is allowed only when unavailable. |
| `deployment_environment` | `dev`, `qa`, `prod`, or `unknown` | yes | No arbitrary environment strings. |
| `component` | approved identifier, max 64 chars | yes | For example `http`, `db`, `nats`, `worker`, `deployment`, `collector`. |
| `operation` | stable identifier, max 96 chars | no | Use-case or deployment operation. |
| `outcome` | `success`, `rejected`, `conflict`, `timeout`, `failure`, `degraded`, `dropped` | yes for completed operations | The result of the event or operation. |
| `error_code` | allow-listed identifier, max 96 chars | conditional | Required for an investigated failure, rejection, timeout, or drop. |
| `error_type` | stable type/category, max 128 chars | no | Concrete type or bounded category such as `context_deadline_exceeded`; never an error message. |
| `message` | controlled text, max 256 chars | no | Only a fixed, reviewed summary. It MUST NOT contain user/dependency output. |
| `redaction_applied` | boolean | no | `true` when a producer or collector removed a value. |
| `redaction_rules` | array of max 8 rule IDs | no | Rule names only, never the removed value. |

`event_type`, `operation`, and `error_code` are part of the searchable
contract. They MUST be stable across releases. A free-form input `msg`,
shell message, or error string MUST NOT be forwarded verbatim. It MAY
contribute to a bounded `message` only after a reviewed fixed template has
been selected and the producer and collector deny-lists have passed.

### 3.2 Correlation and tenant fields

| Field | Type and bound | Required | Contract |
|---|---|---:|---|
| `request_id` | validated `[A-Za-z0-9._-]{1,64}` | request-scoped events | Preserve a valid incoming `X-Request-ID`; otherwise generate one and return it in the response. |
| `trace_id` | 32 lower-case hex characters | when a trace exists | W3C trace ID; never substitute `request_id`. |
| `span_id` | 16 lower-case hex characters | span/log-within-span | Current span ID. |
| `parent_span_id` | 16 lower-case hex characters | spans when present | Parent span, if known. |
| `origin_request_id` | validated request ID | async work only | Request that enqueued the work; not the worker's current request ID. |
| `origin_trace_id` | trace ID | async work only | Trace that created the job/link. |
| `operation_id` | deployment operation ID, max 96 chars | deployment/script events | Separate from both request and trace IDs. |
| `job_id` | opaque ID, max 128 chars | async work when available | Search field only; never a label or resource attribute. |
| `tenant_scope` | `tenant`, `control_plane`, `unknown` | all logs | Declares the identity boundary. |
| `tenant_id` | normalized name, max 63 chars | tenant-scoped events | Lower-case `[a-z0-9-]`; derived only from trusted context. |
| `company_id` | opaque approved identifier, max 128 chars | when available | Trusted backend context; not a metric or label. |
| `actor_id` | opaque ID, max 128 chars | when available | Authenticated principal only; no email, username, or token. |

For a pre-authentication request, `tenant_scope` MUST be `unknown` and
`tenant_id` MUST be absent. For a control-plane event that operates on a
tenant, `tenant_scope` is `tenant` and `tenant_id` is the sanitized deployment
tenant name. A missing tenant MUST NOT be replaced with a default tenant.

The backend currently obtains trusted server context from authenticated
application state and its server environment (`TENANT_ID`, with legacy
`DBNAME` fallback). The contract permits that source only after validation;
database names, connection strings, and credentials MUST NOT be emitted.
Deployment scripts use their existing sanitized tenant name and
`operation_id`.

### 3.3 HTTP and dependency fields

These fields are required for `http.request.completed` and recommended for
dependency events:

| Field | Type and bound | Contract |
|---|---|---|
| `route` | route template, max 128 chars | `/bill/:id`, `/tenants/{name}/activity`; never the raw URL. |
| `method` | bounded HTTP/RPC verb | `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, and other approved verbs. |
| `status_code` | integer | HTTP/RPC result when applicable. |
| `status_class` | `1xx`–`5xx` or `other` | Bounded aggregation value. |
| `duration_ms` | non-negative integer | Elapsed operation time, rounded to milliseconds. |
| `dependency` | approved identifier, max 64 chars | `mysql`, `nats`, `http.vin-provider`, `docker`, `dokku`, or another reviewed name. |
| `attempt` | integer `1`–`10` | Retry attempt when applicable. |
| `retryable` | boolean | Whether the failure may be retried by policy. |
| `client_ip` | normalized IP or `unknown` | Dashboard-only optional field; never a label and never taken from an untrusted forwarded header. |

An HTTP completion event MUST be emitted once per request, after the final
status is known. A route template is required even for an unmatched route
(`unmatched`). Query strings, fragments, headers, cookies, and bodies MUST NOT
be copied into the event.

### 3.4 Error and exception fields

An error event MAY contain:

| Field | Type and bound | Contract |
|---|---|---|
| `panic_type` | stable type, max 128 chars | Type only; the panic value is forbidden. |
| `exception_type` | stable type, max 128 chars | Type/category only. |
| `stack_fingerprint` | lower-case hex, 16–64 chars | Hash of the sanitized stack for grouping. |
| `exception_frames` | max 20 strings, max 160 chars each | Code locations only (`package/function file:line`); no arguments, locals, source snippets, or values. |
| `stack_omitted_reason` | allow-listed identifier | For example `not_captured`, `unsafe_content`, or `over_limit`. |

Current recovery paths intentionally emit only a panic/error type and
correlation fields. A future stack export is optional, MUST follow the bounds
above, and MUST be omitted if the scrubber cannot prove that it is safe.
`error.message`, raw `error`, SQL, provider responses, request payloads, and
panic values are never part of this contract.

### 3.5 Build and deployment identity

Deployment and application events SHOULD carry these searchable fields when
known:

| Field | Type and bound | Contract |
|---|---|---|
| `build_version` | max 128 chars | Human-facing release/version. |
| `build_commit` | lower-case hex, max 64 chars | Source commit. |
| `image_digest` | `sha256:` plus 64 hex characters | Immutable image identity. |
| `image_channel` | bounded identifier | `dev`, `qa`, `stable`, or reviewed channel. |
| `scripts_revision` | lower-case hex, max 64 chars | Deployment script revision. |
| `deployment_stage` | bounded identifier | `backup`, `migration`, `image_swap`, `verify`, `rollback`, or reviewed stage. |
| `script` | approved script name, max 96 chars | Deployment script that emitted the event. |
| `resource_type` | approved identifier, max 64 chars | Optional type when an incident needs a resource reference. |
| `resource_id` | opaque or tenant-scoped keyed hash, max 128 chars | Optional incident reference; never a raw customer identifier. |
| `resource_id_hashed` | boolean | Whether `resource_id` is a keyed hash. |

These fields are record fields, not labels. They allow an operator to connect
a failure to the exact image, script, and migration boundary without logging
commands or environment files.

### 3.6 OTLP attribute mapping

OTLP traces and metrics retain their native signal encoding, but the collector
MUST map these semantic/resource attributes to the canonical searchable names
when it creates a cross-signal record:

| OTLP attribute | Canonical field | Rule |
|---|---|---|
| `service.name` | `service_name` | Must pass the service registry. |
| `service.version` | `service_version` | Bounded approved build value. |
| `deployment.environment.name` | `deployment_environment` | Must pass the environment enum. |
| `http.request.method` | `method` | Bounded verb. |
| `http.route` | `route` | Route template only. |
| `http.response.status_code` | `status_code` | Numeric result. |
| `db.system`, messaging system, or approved client name | `dependency` | Reviewed bounded dependency value. |
| `error.type` | `error_type` | Type/category only. |
| `exception.stacktrace` | `exception_frames` / `stack_fingerprint` | Scrub, bound, or omit; never forward raw stack text. |
| custom `tenant.id` | `tenant_id` | Event/span attribute after trusted resolution; never a resource or metric label. |
| custom `request.id` | `request_id` | Validated request ID; never a metric label. |

The implementation MAY retain the original OTel semantic key in an internal
mapping layer, but exported labels and searchable fields MUST obey this
contract. Trace/span IDs remain native OTLP IDs and are also queryable through
the canonical `trace_id` and `span_id` fields.

### 3.7 Shared tenant OTLP identity

Tenant applications use the explicit signal endpoint
`http://alloy-openobserve:4318/v1/traces` on the private Docker network. The
deployment injects a bounded Basic-auth header from the protected
`OPENOBSERVE_TENANT_OTLP_TOKEN` value. The token is supplied to Alloy through
the ignored operator environment file and to tenant apps through protected
Dokku configuration; it MUST NOT appear in tracked files, logs, or runbooks.
Missing or malformed tokens MUST fail closed for OTLP intake without blocking
the tenant request path.

The shared OTLP receiver MUST authenticate the deployment header before
accepting tenant telemetry. It MUST overwrite resource `service.name` with
the bounded `ifritah-tenant` identity and MUST remove caller-provided
`tenant.id`/`tenant_id` from OTLP traces and metrics. A caller-supplied
`service.name`, `tenant.id`, or equivalent span/resource attribute MUST NOT
select another tenant or service. Tenant identity in Docker logs is derived
from the collector's allow-listed Dokku container metadata; it is not taken
from an arbitrary OTLP payload. Tenant OTLP is routed through a dedicated
identity processor before the common sanitizer; Docker logs and Prometheus
resource/health scrapes use the internal pipeline and retain their
allow-listed service attribution. The receiver's overwrite is intentional:
OTLP application identity is authenticated but not used as a tenant-directory
lookup.

## 4. Event taxonomy and examples

The first implementation MUST support these event types:

| Event type | Producer | Required additions |
|---|---|---|
| `http.request.completed` | backend, frontend, dashboard | `request_id`, `route`, `method`, `status_code`, `status_class`, `duration_ms`, `outcome` |
| `http.panic_recovered` | backend, dashboard | `request_id`, `route`, `status_code=500`, `panic_type`, `outcome=failure` |
| `auth.decision` | backend/frontend/dashboard | `operation`, `outcome`, `error_code` for rejection; no credential data |
| `dependency.call.completed` | backend/workers | `dependency`, `operation`, `duration_ms`, `outcome`, `attempt` |
| `worker.job.completed` | workers | `operation`, `outcome`, `origin_trace_id` when linked, `tenant_id` when tenant-owned |
| `deployment.operation` | dashboard/scripts | `operation_id`, `script`, `deployment_stage`, `tenant_id` when scoped, build identity, `outcome` |
| `runtime.lifecycle` | every service | `operation` such as `startup`, `shutdown`, `readiness_changed` and `outcome` |
| `telemetry.pipeline` | collector | bounded metric families for drops, queue state, export failures, and auth/schema health |

The following is a successful tenant request. It is illustrative; it is not
permission to add arbitrary fields:

```json
{
  "schema_version": 1,
  "event_time": "2026-09-19T08:00:00.123456Z",
  "signal": "log",
  "event_type": "http.request.completed",
  "severity": "info",
  "service_name": "ifritah-backend",
  "service_version": "v0.0.1",
  "deployment_environment": "prod",
  "component": "http",
  "tenant_scope": "tenant",
  "tenant_id": "acme",
  "company_id": "company-7",
  "actor_id": "42",
  "request_id": "req-4f5d9a",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "operation": "http.request.completed",
  "route": "/purchase_bill/:id",
  "method": "POST",
  "status_code": 201,
  "status_class": "2xx",
  "duration_ms": 42,
  "outcome": "success",
  "build_version": "v0.0.1",
  "build_commit": "0123456789abcdef0123456789abcdef01234567"
}
```

A deployment failure is correlated without exposing the failed command:

```json
{
  "schema_version": 1,
  "event_time": "2026-09-19T08:01:00Z",
  "signal": "log",
  "event_type": "deployment.operation",
  "severity": "error",
  "service_name": "ifritah-deploy-script",
  "service_version": "scripts-2026-09-19",
  "deployment_environment": "prod",
  "component": "deployment",
  "tenant_scope": "tenant",
  "tenant_id": "acme",
  "operation_id": "op-20260919T080000Z-42",
  "operation": "tenant_update",
  "script": "update-tenant.sh",
  "deployment_stage": "migration",
  "outcome": "failure",
  "error_code": "migration_replay_failed",
  "error_type": "exit_status",
  "build_version": "v0.0.1",
  "image_digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "scripts_revision": "fedcba9876543210fedcba9876543210fedcba98"
}
```

The deployment log's current `message` may be used to produce a stable
`event_type`, `operation`, or `error_code`, but command text, environment
values, credentials, and arbitrary runner output MUST be discarded.

## 5. Trace and request correlation

### 5.1 Inbound and outbound HTTP

At the inbound boundary, services MUST:

1. validate `X-Request-ID`; preserve it only when it matches the contract,
   otherwise generate a cryptographically safe ID;
2. extract a valid W3C `traceparent` before handling the request, or create a
   new trace;
3. authenticate and authorize before attaching `tenant_id`, `company_id`, or
   `actor_id`;
4. return the validated/generated `X-Request-ID` response header;
5. propagate both `X-Request-ID` and W3C trace context across frontend-to-
   backend and approved outbound dependency calls; and
6. emit one completion event with the final route, status, duration, and
   outcome.

`request_id` answers “which request log entries belong together?”.
`trace_id` answers “which distributed operation and spans belong together?”.
They MUST remain separate even when a deployment or test happens to use
similar values.

### 5.2 Database, NATS, and workers

Database and NATS spans inherit the current trace and use stable operation and
dependency names. SQL text, bind values, NATS payloads, subjects containing
secrets, and acknowledgements MUST NOT be logged or added as span attributes.

An asynchronous job MUST carry an explicit tenant and correlation envelope:

```text
tenant_id
origin_request_id       (optional)
origin_trace_id         (optional)
operation
job_id                  (opaque field only, not a label)
```

The worker creates a new span for execution and records the origin IDs as
links/fields. It MUST NOT retain or reuse the HTTP request context after the
request ends. A job without required tenant context fails visibly with a
bounded `missing_tenant_context` event; it MUST NOT guess a tenant.

### 5.3 Search contract

An operator MUST be able to:

- search `ifritah_logs_v1` by exact `request_id` and order by
  `event_time`;
- search `ifritah_traces_v1` by exact `trace_id`;
- join a request's logs and spans by `trace_id`, then narrow by
  `tenant_id`, `service_name`, or `operation`;
- find a deployment operation by `operation_id` and `tenant_id`; and
- find all records for an image/script identity without using raw command
  output.

The implementation SHOULD provision saved searches for:
`5xx`, panic recovery, authentication failures, migration/deployment failures,
dependency timeouts, collector drops, disk pressure, and restart loops.

## 6. Redaction and data classification

### 6.1 Always forbidden

The following values MUST NOT appear in logs, traces, metrics, exception
attributes, labels, resource attributes, or collector diagnostics:

- `Authorization`, cookies, session IDs, CSRF values, JWTs, API keys,
  refresh/access/reset tokens, OTPs, passwords, password hashes, private
  keys, webhook URLs, or database credentials;
- DSNs, connection strings, host environment dumps, `.env` contents, or
  secret-bearing image/config values;
- request/response bodies, form data, raw query strings, arbitrary headers,
  SQL text, bind values, NATS messages/ACKs, provider payloads, or shell
  commands;
- raw error messages, panic values, stack locals/arguments, source snippets,
  or unbounded dependency responses;
- payment/card/bank data, tax or identity documents, phone numbers, email
  addresses, names, addresses, license plates, VINs, uploaded file contents,
  or customer-entered free text;
- full resource URLs or identifiers when the route template and a stable
  `resource_type` are sufficient.

Sensitive-looking keys MUST be denied even when a caller uses a new spelling,
separator, or case. This includes key fragments such as `authorization`,
`cookie`, `credential`, `password`, `secret`, `session`, `token`, `otp`,
`payload`, `body`, `query`, `sql`, `statement`, `message`, and `raw`.

### 6.2 Allowed but bounded

The following may be recorded only in the documented fields and bounds:

- normalized tenant IDs, approved company IDs, and opaque actor IDs;
- route templates, stable operation names, status classes, error codes, and
  dependency names;
- build/version/commit/digest identity;
- a normalized dashboard client IP when the operator policy requires it;
- a resource identifier only when it is an approved opaque identifier and is
  needed for an incident. If it may contain customer data, use a
  tenant-scoped keyed hash and record `resource_id_hashed=true`;
- sanitized exception frame locations and a stack fingerprint as described in
  section 3.4.

Every string MUST have a length limit and control characters (`CR`, `LF`,
`TAB`, and other non-printing characters) MUST be normalized or rejected.
Arrays and maps MUST have explicit item and byte limits. The collector MUST
drop a field that fails validation rather than serialize its original value.

### 6.3 Redaction observability

The collector MUST increment bounded counters for redaction and parse failures
and emit at most one aggregate `telemetry.pipeline` event per rule and service
per minute. The event contains rule IDs and counts, not samples of removed
data. A suspected secret leak is an incident: stop export of the affected
source, preserve only approved metadata, and rotate the secret through the
normal operator process.

## 7. Resource attributes, labels, and cardinality

### 7.1 Resource attribute allow-list

OTLP resources MAY carry only these dimensions:

| Attribute | Allowed values |
|---|---|
| `service.name` | `ifritah-backend`, `ifritah-frontend`, `ifritah-dashboard`, `ifritah-deploy-script`, `ifritah-tenant`, `ifritah-alloy`, `ifritah-openobserve-gateway`, `ifritah-resource-exporter`, `ifritah-node-exporter`, `otel-collector`, `openobserve` |
| `service.version` | current approved release/build |
| `deployment.environment.name` | `dev`, `qa`, `prod`, `unknown` |
| `component` | reviewed bounded component name |
| `cluster` | configured cluster identifier, max 32 chars |
| `host.role` | `deployment`, `application`, `observability` |
| `container.role` | `backend`, `frontend`, `dashboard`, `collector`, `storage`, `other` |
| `image.channel` | `dev`, `qa`, `stable`, or reviewed channel |

`tenant_id`, `request_id`, `trace_id`, `span_id`, `actor_id`, `operation_id`,
`job_id`, `resource_id`, `container_id`, and `image_digest` MUST remain event,
span, or exemplar fields. They MUST NOT be OTLP resource attributes or
OpenObserve stream labels.

### 7.2 Metric label allow-list

The existing backend metric contract remains:

```text
ifritah_http_requests_total{method,route,status_class}
ifritah_http_request_duration_seconds{method,route,status_class}
```

Future metrics MAY add only reviewed bounded labels such as
`service_name`, `deployment_environment`, `dependency`, `operation`,
`outcome`, `container_role`, and `device_class`. Metrics MUST NOT be labelled
by tenant/user/request/trace/span/resource IDs, SKU, VIN, invoice number,
raw URL, error text, image digest, or arbitrary exception type.

OpenObserve `v1.0.3` native OTLP metric ingestion may expose constant transport
metadata labels such as `flag`, `start_time`, and
`instrumentation_library_name`/`instrumentation_library_version` in PromQL
results. These labels are bounded implementation metadata, not application
dimensions; dashboards and alerts MUST NOT group by them. The collector still
MUST remove unapproved application/resource attributes before export.

Recommended resource metric names are:

```text
ifritah_host_cpu_usage_ratio
ifritah_host_memory_used_bytes
ifritah_filesystem_free_bytes
ifritah_container_cpu_usage_ratio
ifritah_container_memory_working_set_bytes
ifritah_container_restarts_total
ifritah_http_requests_total
ifritah_http_request_duration_seconds
ifritah_telemetry_export_failures_total
ifritah_telemetry_dropped_records_total
```

### 7.3 Resource alert templates

The pinned OpenObserve pilot currently receives host resource metrics under
the node-exporter names `node_cpu_seconds_total`,
`node_memory_MemTotal_bytes`, `node_memory_MemAvailable_bytes`,
`node_filesystem_avail_bytes`, `node_filesystem_free_bytes`, and
`node_filesystem_size_bytes`. Container and pipeline health metrics use the
existing bounded names `ifritah_container_memory_working_set_bytes`,
`ifritah_container_restarts_total`, `ifritah_resource_exporter_up`,
`ifritah_resource_exporter_scrape_errors_total`,
`ifritah_gateway_forward_failures_total`,
`ifritah_gateway_dropped_records_total`,
`ifritah_gateway_auth_blocked`,
`ifritah_gateway_oversized_payloads_total`, and
`ifritah_gateway_queue_write_errors_total`. Alert templates MUST query these
emitted names rather than inventing a second resource-metric namespace.

The provisioning bundle keeps the following resource and pipeline alert
templates disabled by default: container memory pressure, filesystem/disk
pressure, container restart loops, host memory pressure, host resource-metric
health, resource-exporter health, and telemetry-gateway health. The absolute
pilot thresholds are reviewable defaults, not accounting or capacity
guarantees; enabling a template requires an operator-managed destination and a
host-specific threshold review.

Per-tenant resource graphs MUST be implemented as filtered event/detail
queries or a reviewed pre-aggregation, not as one metric series per tenant.

### 7.4 Cardinality budgets

The collector and OpenObserve configuration MUST enforce these starting
budgets:

| Dimension | Maximum distinct values per service/environment |
|---|---:|
| `service_name` | 8 |
| `deployment_environment` | 4 |
| `method` | 10 |
| `status_class` | 5 |
| `route` | 256 |
| `dependency` | 32 |
| `operation` | 256 |
| `error_code` | 128 |
| `outcome` | 8 |
| active metric series per metric | 2,048 |

Values outside an allow-list or budget MUST be normalized to `other` or
discarded from labels while retaining a bounded pipeline-health count. The
original high-cardinality value MUST NOT be promoted to a label to “make the
query work”. These budgets are review thresholds, not permission to add more
dimensions without measurement.

## 8. Collector pipeline and failure behavior

### 8.1 Inputs and normalization

The collector MUST:

1. read only explicitly allow-listed application/dashboard containers and
   approved OTLP endpoints on a private network;
2. parse Docker JSON stdout/stderr without exposing the Docker socket to
   applications or OpenObserve;
3. parse the dashboard/deployment logfmt shape (`timestamp`, `severity`,
   `script`, `operation_id`, `tenant`, `message`) into the canonical envelope;
4. parse application JSON and map current fields (`msg`, `level`, `service`,
   `environment`, `build_version`, `build_commit`, `scripts_revision`,
   `tenant`, `company_id`, `user_id`) to their canonical names;
5. validate IDs, enum values, lengths, timestamps, and redaction rules before
   export;
6. attach bounded source metadata (`container.role`, `image.channel`, and
   approved build identity); and
7. reject or count malformed records without forwarding the original payload.

Valid structured records MUST remain searchable by `tenant_id`, `request_id`,
`trace_id`, `operation_id`, and build identity after normalization. Docker
position/state MUST be persisted so collector recreation resumes from the
stored offset instead of replaying the complete log stream.

### 8.2 Queues, retries, and drops

The implementation MUST use bounded queues:

- OTLP application exporters: non-blocking export, a 5-second export timeout,
  and a queue capped at 10,000 records or 64 MiB per process, whichever comes
  first;
- collector batching: a bounded 10-second batch window and no unbounded
  in-memory retry queue;
- collector-to-OpenObserve delivery: exponential backoff capped at 30 seconds,
  with a disk queue capped at 64 MiB per signal; and
- graceful shutdown: flush for at most 5 seconds, then report the bounded drop
  count and exit.

Retry policy:

- network errors, `429`, and `5xx` are retried with bounded backoff;
- `400` parse/schema failures are not retried until the configuration or
  producer changes;
- `401`/`403` stop normal retry amplification, raise a pipeline-health event,
  and require operator credential/configuration repair; and
- after a queue is full, successful low-severity spans and metrics are dropped
  before error records and pipeline-health events. No source payload is copied
  into a drop event.

Logs written to stdout/stderr MUST continue when the collector is down. The
application MUST NOT synchronously call OpenObserve for a request. Existing
Docker log rotation and the current Loki/Grafana position persistence remain
independent safeguards; this contract does not increase those limits.

### 8.3 Failure visibility and recovery

The collector MUST expose private, operator-readable health signals for:

- input parse failures;
- redactions;
- export failures by status class;
- queue depth/age;
- dropped records by signal and severity;
- last successful export time; and
- OpenObserve authentication or schema errors.

When OpenObserve is unavailable, the collector exports bounded health metrics
through the dedicated health path, keeps retrying within the limits above, and
drops only after the health queue limit is reached. When the backend recovers,
ingestion resumes without restarting tenant applications. The collector MUST
NOT bypass redaction, publish a public fallback endpoint, or attach directly
to a host Docker socket to recover.

### 8.4 Dedicated health signal path

The health path MUST remain distinct from ordinary application, resource, and
trace delivery:

1. `prometheus.scrape "collector_health"` reads only the Alloy admin metrics
   endpoint and the private gateway `/metrics` endpoint.
2. `otelcol.receiver.prometheus "health"` applies its own memory limit,
   attribute sanitization, and bounded batch.
3. `otelcol.exporter.otlphttp "health"` sends OTLP metrics to the gateway's
   private `/v1/health` ingress.
4. The gateway stores health payloads in the `health` durable queue and maps
   them to OpenObserve `/v1/metrics`; it MUST NOT set a synthetic stream name.
5. OpenObserve stores the resulting native metric families. Dashboards,
   saved views, alerts, and retention provisioning MUST use PromQL and the
   allow-listed metric prefixes.

Health samples MUST NOT also enter the ordinary metrics exporter or queue.
This prevents duplicate health records and preserves health visibility when
ordinary telemetry is backlogged or dropped.

## 9. Operator access and retention operations

The OpenObserve UI and API MUST be reachable only through the operator-managed
private bind/reverse-proxy path. OTLP, collector health, Docker API, and
OpenObserve storage ports MUST NOT be host-published by default. Credentials
MUST come from an ignored operator secret file or secret manager; the
provisioning script accepts `OPENOBSERVE_PASSWORD_FILE` for file-mounted
secrets. No credential belongs in this repository or in telemetry.

Operators investigating an incident should preserve:

- UTC time range;
- tenant (if known);
- `request_id`, `trace_id`, or `operation_id`;
- service/version/image digest/scripts revision;
- stable `error_code`/`error_type`;
- collector queue/drop state; and
- the applicable retention/configuration revision.

They MUST NOT copy raw request bodies, cookies, authorization values, tenant
credentials, SQL, or unbounded error output into tickets or annotations.

## 10. Acceptance scenarios

Focused Compose and static pipeline contract tests cover the deployment-only
profile, collector wiring, resource allow-list, queue bounds, redaction
configuration, and private egress boundaries. Runtime fixtures for application
instrumentation and the Docker-dependent scenarios below still require a
controlled operator pilot before production ingestion.

| ID | Scenario and fixture | Expected result |
|---|---|---|
| `OOBS-01` | Send a successful backend request with a valid request ID and W3C `traceparent`. | One `http.request.completed` event has the same `request_id`, valid `trace_id`/`span_id`, trusted `tenant_id`, route template, status, duration, and `outcome=success`; raw URL/query/body are absent. |
| `OOBS-02` | Send a request with an invalid/oversized `X-Request-ID` and invalid trace header. | A safe generated request/trace identity is used; the invalid values never appear in OpenObserve or response headers. |
| `OOBS-03` | Make a frontend-to-backend request for tenant `acme`. | Frontend and backend records share `request_id` and `trace_id`; child spans have distinct `span_id` values and correct parent links. This remains blocked until the separate frontend worktree is restored. |
| `OOBS-04` | Authenticate as tenant `acme` while sending `X-Tenant-ID: victim` and a body/query tenant value. | Every tenant-scoped record says `acme`; the untrusted values are absent. An unauthenticated request has `tenant_scope=unknown` and no `tenant_id`. |
| `OOBS-05` | Trigger a MySQL/NATS/HTTP dependency timeout containing a secret-bearing error string. | A dependency event has bounded `dependency`, `duration_ms`, `attempt`, `error_code`, `error_type`, and `outcome=timeout`; the raw error, SQL, payload, token, and secret are absent. |
| `OOBS-06` | Trigger a recovered panic with a panic value containing a marker secret. | The request returns the existing generic 500; OpenObserve contains only `http.panic_recovered`, `panic_type`, correlation, route, and status. The marker secret and stack value are absent. |
| `OOBS-07` | Run a deployment migration failure for tenant `acme`. | A `deployment.operation` event is searchable by `operation_id`, `tenant_id`, script, deployment stage, build identity, and stable error code. Failed command text, environment values, credentials, and runner payload are absent. |
| `OOBS-08` | Enqueue and process a tenant job after the originating HTTP request ends. | The worker has a new span, explicit tenant context, and origin request/trace link; it does not reuse a canceled HTTP context or guess a tenant. Missing tenant context produces `missing_tenant_context` and no tenant data access. |
| `OOBS-09` | Scrape HTTP, host, and container metrics while creating many tenant/request/resource IDs. | Metric names and labels remain within the allow-list and budgets; no tenant, request, trace, span, user, resource, digest, raw URL, or error-text label is created. |
| `OOBS-10` | Send secrets and control characters in headers, cookies, query, body, path values, errors, NATS payloads, and shell output. | No forbidden value or line injection appears in any OpenObserve signal. Redaction/parse counters increment with rule IDs only. |
| `OOBS-11` | Stop the collector and then make normal tenant requests; separately make OpenObserve return `429`/`500`. | Requests retain normal application behavior and are not synchronously delayed by telemetry. Collector retries are bounded, queue/drop health is visible, and applications do not crash or restart. |
| `OOBS-12` | Fill each bounded queue and restart the collector. | Queue size and disk usage stop at the configured cap; low-priority success data is dropped before error/health data; restart resumes from stored positions without a full log replay. |
| `OOBS-13` | Emit malformed JSON, invalid IDs, oversized fields, and unknown sensitive keys. | Invalid records are rejected or normalized without forwarding the original payload. The pipeline reports a bounded parse/schema count. |
| `OOBS-14` | Query by request ID, trace ID, tenant, operation ID, and build/script identity. | An operator can reconstruct request → dependency → worker/deployment activity across services without a raw URL or high-cardinality label. |
| `OOBS-15` | Set log/trace/metric timestamps around the selected TTL and verify the storage policy. | Records expire at the approved per-signal retention; audit/security records are unaffected; current Loki/Grafana retention and operator-only access remain unchanged. |
| `OOBS-16` | Attempt to reach OpenObserve, OTLP, collector health, and Docker API endpoints as a tenant user or from an unapproved network. | Connections are denied. Only the operator-authenticated UI/reverse-proxy path is available, and the deployment dashboard has no telemetry proxy route. |

## 11. Current implementation mapping and gaps

The existing observability work already supplies a safe subset of this
contract:

| Current source | Existing fields/behavior | OpenObserve mapping |
|---|---|---|
| Backend `pkg/logging` and middleware | `request_id`, trusted `tenant`, `company_id`, `user_id`, `route`, `method`, `status`, `duration_ms`, typed errors, redaction | `tenant_id`, `company_id`, `actor_id`, HTTP fields, `error_type`; add W3C trace fields when OTel is introduced |
| Backend `pkg/metrics` | `ifritah_http_requests_total` and duration with `method`, `route`, `status_class`; protected endpoint | Preserve metric names and bounded labels; export through the collector without adding tenant/request/trace labels |
| Dashboard `internal/logging` | JSON `service`, `environment`, `build_version`, `build_commit`, `scripts_revision`, stable error codes/types | Map build/service fields directly; map `msg` to a reviewed `event_type` |
| Dashboard access middleware | request ID, route, method, status, duration, normalized client IP; no headers/cookies/query/body | `http.request.completed` with optional `client_ip` |
| Shell `lib.sh` | UTC timestamp, severity, script, `operation_id`, sanitized tenant, bounded message, command-free `ERR` trap | `deployment.operation`; parse only reviewed operation/stage/error fields |
| Current Alloy/Loki profile | Dashboard-only labelled collection, private network, persistent positions, bounded local retention | Keep unchanged and separate from the OpenObserve collector profile |
| OpenObserve Alloy profile | Allow-listed Docker JSON/logfmt parsing, canonical field validation, OTLP intake, attribute allow-lists, bounded batches, private gateway export, and a separate health pipeline | `ifritah_logs_v1`, `ifritah_traces_v1`, and native per-metric streams; no direct OpenObserve egress |
| OpenObserve gateway | Separate 64 MiB-per-signal durable queues, bounded retries, status-aware drops, auth/schema health, private forwarding | `ifritah_logs_v1`, `ifritah_traces_v1`, and native metrics through the dedicated health queue |
| OpenObserve resource path | Filtered read-only Docker API, dashboard/tenant role allow-list, node-exporter host mounts, role-only aggregation | Host/container CPU, memory, disk, network, running, restart, and collector health metrics |

The following remain separate implementation work, not assumptions hidden by
this document:

- restore the separate frontend worktree and add W3C/request propagation;
- add OpenTelemetry SDK/export configuration to applications;
- choose and record production TTLs within the approved ranges; and
- run the runtime acceptance scenarios with Docker and an approved operator
  credential.

The deployment collector/resource path is statically validated and remains
operator-only. Runtime acceptance still requires Docker and an approved
operator credential. The existing operator-only dashboard/Loki profile is
unchanged and remains supported in parallel.
