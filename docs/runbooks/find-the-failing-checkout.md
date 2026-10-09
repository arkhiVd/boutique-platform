# Runbook: find the failing checkout

**Last verified: 2026-10-09** — verified against the *sources*, not against a
cluster. Every log format and every field name below was read from the vendored
upstream Online Boutique `v0.10.7` source and confirmed by running the formatters
(see `observability/fluent-bit/boutique-parsers.yaml` for the evidence). The
queries have NOT been executed against a live Loki instance, because no cluster
exists yet — Phase 10's exit criteria are where that proof belongs, and the exact
promtool/Loki commands to run are listed at the bottom.

---

## What this runbook is for

A user reports "checkout is broken". Finding the failing service without a
correlation ID takes an hour of dashboard-clicking; with one it takes three
queries.

**The tool that makes this work is the request ID.** The Boutique frontend emits
`GMD_...` request IDs and logs them on every handler call, and the Go services
propagate the gRPC `x-request-id` metadata. So the runbook is one grep for the
request ID, then a filter by service.

## The 30-second path

### 1. Get the request ID

If the user gave you a support ticket or a screenshot with a request ID, use it.
If not, the fastest source is the **edge**, because every request Traefik serves
carries the response status:

```promql
topk(5,
  sum by (service) (
    rate(traefik_service_requests_total{
      service=~"boutique-[a-z0-9-]+-[0-9]+@kubernetes", code=~"5.."
    }[10m])
  )
)
```

In Grafana: **Boutique golden signals** → "Error ratio per Boutique service".
Which service is elevated tells you the half of the journey that is broken:

| service | what it covers |
|---|---|
| `frontend` | the edge handler only; a failure here is not downstream |
| `checkoutservice` | checkoutService, the orchestrator — the whole journey runs through here |
| `paymentservice` | the credit-card step |
| `shippingservice` / `emailservice` | the order-confirmation step — happens *after* the charge |
| `currencyservice` | price conversion — affects every page, not just checkout |
| `productcatalogservice` | catalogue lookups |
| `cartservice` | the cart itself — a failure here breaks the journey before checkout |
| `recommendationservice` / `adservice` | side panels; NOT on the checkout critical path |

### 2. Get the trace ID from the log

The three services on the critical checkout path are `frontend`,
`checkoutservice` and `paymentservice`. Their logs are in Loki with the labels
the Fluent Bit pipeline sets (`namespace`, `app`, `container`).

```logql
{namespace="boutique", app=~"frontend|checkoutservice|paymentservice"}
  | json
  | severity="ERROR"
  | line_format "{{.message}}"
```

**Loki's `| json` stage is what makes this work without a parser.** Fluent Bit's
Loki output uses `Line_Format json`, so the whole Fluent Bit record — the parsed
fields *and* the Kubernetes metadata — arrives as a JSON object on the log line.
That means `severity` and `message` are queryable even though they were produced
by four different loggers.

The three fields that differ per service, and where they come from:

| app | log format | field holding the message |
|---|---|---|
| `frontend`, `checkoutservice`, `productcatalogservice`, `shippingservice` | Go / logrus JSON with a `FieldMap` | `message` |
| `emailservice`, `recommendationservice` | Python / python-json-logger | `message` |
| `currencyservice`, `paymentservice` | Node / pino (`messageKey: 'message'`) | `message` |
| `adservice` | Java / log4j2 `JsonLayout` | `message` |
| `cartservice` | .NET plain text, two lines | `severity` and `logger` are labels; the message is the second line |

All four Go/Python/Node/Java services use the SAME message key, `message`. That
is not a coincidence in the upstream code — logrus's `FieldMap` renames `msg` to
`message`, pino sets `messageKey: 'message'`, and log4j2's `JsonLayout` uses
`message` natively. So one LogQL query covers all of them.

### 3. Follow the request ID across the three services

```logql
{namespace="boutique", app=~"frontend|checkoutservice|paymentservice"}
  | json
  | message=~".*<REQUEST_ID>.*"
  | line_format "{{.message}}"
```

Replace `<REQUEST_ID>` with the value from step 1 (or from the user). In Grafana
Explore, `Logs` mode with the label filter set in the query builder rather than
the label selector, so the `| json` stage runs first.

To read the request ID out of the **frontend's** structured logs directly:

```logql
{namespace="boutique", app="frontend"}
  | json
  | severity="ERROR"
  | line_format "{{.timestamp}} {{.message}}"
```

and from **adservice**, which is the one service that logs the trace ID as its
own key (from the log4j2 `JsonLayout` `KeyValuePair`):

```logql
{namespace="boutique", app="adservice"}
  | json
  | line_format "{{.message}}"
```

### 4. Narrow to the replica that logged it

`pod` is **structured metadata**, not a label — that is the whole point of
`Structured_Metadata pod=$pod_name` in `observability/fluent-bit/values.yaml`,
which keeps `pod` out of the stream label set and the stream count bounded at
~90 rather than ~550. It is therefore queried with a filter and not a label
matcher:

```logql
{namespace="boutique", app=~"frontend|checkoutservice|paymentservice"}
  | json
  | pod="frontend-7d9f8c6b5-x2k4p"
  | severity="ERROR"
  | line_format "{{.timestamp}} {{.message}}"
```

Get the pod name from `kubectl get pods -n boutique -o wide`, or from the
`pod` column in Grafana Explore once the query above has returned.

### 5. Read the failure in order

The three services fail in a chain, so the logs read in order:

1. **frontend** — the request arrives, the handler calls `Checkout`. Look for
   `Bad Request` / `Internal Server Error` in `message`.
2. **checkoutservice** — it orchestrates `PlaceOrder`, which calls payment,
   shipping, email and product catalogue *in sequence*. A failure here names
   which downstream call is broken.
3. **paymentservice** — `Charge failed` / `Invalid credit card`. This is the
   only place a card is charged, so a 500 here with a 500 in checkoutservice and
   a clean frontend handler means the payment step is the failure.

The line that usually tells you the answer, and where to find it:

```logql
{namespace="boutique", app=~"frontend|checkoutservice|paymentservice"}
  | json
  | message=~"(?i)(error|failed|refused|unavailable|timeout)"
  | line_format "{{.message}}"
```

`(?i)` is the case-insensitive flag, and it catches `ERROR`, `Error` and
`error` from the four different loggers without four queries.

### 6. Confirm with the query API (optional, and it is the second half of the
    story)

```logql
sum by (route) (
  rate(loki_request_duration_seconds_count{status_code=~"5.."}[10m])
)
```

If this is non-zero while the log lines above look clean, the failure is in
Loki's write path, not in Boutique — and `LokiRequestErrors` in
`observability/loki/alerts.yaml` should already be firing.

## Correlating with the trace (Phase 11)

Once Tempo exists, the checkout trace is retrievable by the request ID, because
the frontend emits it as the OpenTelemetry span attribute. Until then, the log
queries above are the path. See `docs/adr/0004-adservice-tracing-gap.md` for what
does not produce spans at all.

## The queries to run against a live Loki

```bash
# From the Phase 5 edge host or through the grafana host route's Explore:
export LOKI=http://loki.observability.svc.cluster.local:3100

# Every ERROR line in the boutique namespace, last hour:
curl -sG "$LOKI/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="boutique"} | json | severity="ERROR"' \
  --data-urlencode 'limit=100' \
  --data-urlencode 'since=1h' | jq '.data.result[].values'

# The three critical services, by request ID:
curl -sG "$LOKI/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="boutique", app=~"frontend|checkoutservice|paymentservice"} | json | message=~".*<REQUEST_ID>.*"' \
  --data-urlencode 'limit=100' \
  --data-urlencode 'since=1h' | jq -r '.data.result[].values[]'

# How many streams the pipeline actually created (the cardinality guardrail):
curl -sG "$LOKI/loki/api/v1/series" \
  --data-urlencode 'match[]={namespace="boutique"}' \
  --data-urlencode 'since=168h' | jq '.data | length'
```

The last query is the one that proves the cardinality bound in
`observability/loki/values.yaml` is real: the result must be roughly 90, not
roughly 550.

## If a service's logs are missing entirely

| symptom | meaning | action |
|---|---|---|
| No streams for `app="cartservice"` | cartservice's logs are `.NET` plain text, parsed by `boutique-dotnet-plain` | check `kubectl logs -n boutique deploy/cartservice \| head -2` and match it against the regex in `observability/fluent-bit/boutique-parsers.yaml` |
| No streams for `app="emailservice"` | the Python parser's `Time_Format %s` failed | check that `timestamp` is a float; if the field is absent the record ships with `message` only |
| No streams at all | Fluent Bit is not running, or Loki is down | `up{job="blackbox-exporter"}` and the Loki alerts in `observability/loki/alerts.yaml` |
| `app` label is empty | the rewrite_tag rules did not match | check `$kubernetes['labels']['app']` against the seven rules in `observability/fluent-bit/values.yaml` |

## What is NOT in this runbook, and why

- **A live example.** No cluster exists yet; Phase 10's exit criteria own that
  proof.
- **Tempo.** Phase 11. `docs/adr/0004-adservice-tracing-gap.md` explains what
  does not span at all.
- **How to fix the failure.** Each service's failure mode is in its own logs;
  this runbook's job is to get you to the right one in 30 seconds, not to fix it.
