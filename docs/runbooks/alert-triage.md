# Alert triage runbook

The provisioned alert rules are intentionally small and bounded. They report
the observability plane and dashboard control-plane signals only; they do not
infer tenant business health.

## Observability component is down (`critical`)

**Meaning:** Prometheus has not scraped one or more of Alloy, Loki,
Prometheus, or Grafana for five minutes.

1. Check the component availability panel.
2. Run `docker compose ... ps` and inspect the affected container.
3. Read the last 80 lines for the affected service and its dependency.
4. For Alloy, verify the Docker API filter is up and that only the allowed
   read-only paths are configured.
5. For Loki or Prometheus, check volume/disk pressure before recreating.
6. Recheck the alert after the service is healthy.

Do not bypass the path filter or attach Alloy to `/var/run/docker.sock` to
recover service quickly.

## Dashboard error logs detected (`warning`)

**Meaning:** one or more error-level structured dashboard events continued for
ten minutes.

1. Open the structured log stream and filter by the firing time.
2. Correlate `request_id`, `operation`, `error_type`, and `error_code`.
3. If the event is deployment-related, inspect the corresponding operation
   boundary and the bounded runner output.
4. If the event is a repeated request failure, check dashboard health and the
   dependent Dokku/Docker state.
5. Escalate repeated errors with the build and mounted script revisions.

Raw error messages, SQL, tokens, request bodies, and tenant credentials must
not be copied into tickets.

## Dashboard panic recovery detected (`critical`)

**Meaning:** an HTTP handler panic was recovered and returned a generic 500.

1. Preserve the sanitized `request_id` and UTC timestamp.
2. Confirm the dashboard still answers `/healthz`.
3. Check whether the same route repeats in the access log stream.
4. Compare the running dashboard image revision and mounted deployment-script
   revision before any restart or rollback.
5. Escalate as a software defect if the panic repeats.

The recovery middleware intentionally omits panic values and stack traces.
Use the request ID and deployment revision to reproduce in a controlled
environment instead of weakening redaction.

## Notification delivery checks

Notification destinations are not enabled by default. When an operator has an
approved Slack webhook or SMTP relay:

1. Set the corresponding values in `dashboard/observability/.env`.
   Set `OBS_SMTP_HOST` as `host:port` (for example, `smtp.example.com:587`).
2. Copy the contact-point and policy templates into the ignored provisioning
   directory.
3. Remove unused receivers from the contact-point file.
4. Recreate Grafana and run the contact-point test.
5. Trigger a controlled test alert, then restore the normal state.

If delivery fails, first check the approved egress relay/firewall path. Do not
make the observability network public or paste a webhook URL into a dashboard,
alert annotation, or repository file.
