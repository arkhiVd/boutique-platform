# boutique-platform — tasks

## Current phase: 9 / 10 / 12 — observability metrics, logs, SLOs

Built on `feat/observability-metrics-logs`. Everything below is **validated by
render and by the tool that would catch the failure** (`promtool`, `helm
template`, `kubeconform`, and the Fluent Bit binary). Nothing here has been
deployed — there is no cluster. Where a claim is not proven, it is listed under
"Not proven".

### Phase 9 — metrics

- [x] `observability/kube-prometheus-stack/` — wrapper chart on upstream
  `92.1.1` (app `v0.94.1`), values nested under the dependency's name, every
  override justified
  - Automated: `helm lint --strict` (0 failed), `helm template` (128 objects)
  - Prometheus `retention: 7d`, `retentionSize: 7GB`, `replicas: 1`, 30s
    scrape/evaluation, `sampleLimit: 10000` / `targetLimit: 100`
  - Grafana with `adminPassword.existingSecret: grafana-admin`, sidecar
    dashboards on `grafana_dashboard: "1"`, Loki datasource with a fixed `uid`
  - Alertmanager route tree: `default` → `severity=page` (sns-page, continue) →
    `severity=ticket` (sns-ticket)
  - kube-state-metrics and node-exporter enabled, both at their request floors
- [x] `observability/rules/boutique-golden-signals.yaml` — `job:request_rate`,
  `job:error_ratio`, `job:latency_p95`, `job:latency_p99` from Traefik, plus the
  spanmetric-derived `span:*` rules for Phase 11
  - Automated: `promtool check rules` → 9 rules
- [x] `observability/rules/boutique-slo-recording.yaml` — SLI
  numerator/denominator pairs and six burn-rate windows each
  - Automated: `promtool check rules` → 19 rules
- [x] `observability/rules/boutique-alerts.yaml` — KubePodCrashLooping on
  `changes(...[15m]) >= 2` (a single restart does not fire), TargetDown with an
  `absent()` arm, Watchdog, plus Jenkins and Fluent Bit guards
  - Automated: `promtool check rules` → 9 rules
- [x] `observability/dashboards/` — 4 ConfigMaps on `grafana_dashboard: "1"`:
  platform overview, Boutique golden signals, CI pipeline health, cost + capacity
  - Automated: `scripts/check-dashboards.py` → all four parse
- [x] `observability/servicemonitors/` — Traefik, Jenkins exporter,
  blackbox_exporter, **Loki** and **Fluent Bit** (the last two were missing while
  alerts read their metrics)
- [x] `observability/blackbox/` — blackbox_exporter values + ConfigMap probing
  the frontend host from OUTSIDE the cluster, `http_2xx`/`http_2xx_external` with
  a 5s timeout

### Phase 10 — logs

- [x] `observability/loki/` — `SingleBinary`, `replicas: 1`, filesystem on a 10Gi
  gp3 PVC, `retention_period: 168h` **enforced** (the compactor runs in the single
  binary), `ingestion_rate_mb: 4`, `ingestion_burst_size_mb: 8`,
  `max_query_series: 500`, `allow_structured_metadata: true`
- [x] `observability/fluent-bit/` — parsers for all six real formats (Go logrus
  JSON, Node pino, Python python-json-logger float seconds, Java log4j2
  JsonLayout, .NET two-line plain, locust) and a Loki output with exactly three
  labels
- [x] `observability/loki/alerts.yaml` — LokiRequestErrors, LokiRequestLatency,
  LokiLogLinesDropped, LokiIngesterStreamsHigh
  - Automated: `promtool check rules` → 4 rules
- [x] `docs/runbooks/find-the-failing-checkout.md` — the LogQL path to a failed
  checkout across frontend / checkoutservice / paymentservice by request ID

### Phase 12 — SLOs

- [x] `observability/slos/boutique-availability-slo.yaml` (99.9%) and
  `boutique-latency-slo.yaml` (99%) — multiwindow multi-burn-rate, SRE Workbook
  Table 5.2: 2%-in-1h at 14.4x, 5%-in-6h at 6x, 10%-in-3d at 1x, short/long
  windows `and`-ed so a blip cannot page
  - Automated: `promtool check rules` → 3 + 3 rules
- [x] `docs/slo.md` — each SLI's exact numerator, denominator, window, target,
  PromQL, plus an error-budget policy in the Appendix-B style
- [x] `observability/synthetic-tests/burn-rate-multiwindow.yml` — three cases
  - Automated: `promtool test rules` → **SUCCESS** (the 14.4x page fires, the 6x
    and 1x do not, and a 1-in-20-for-10-minutes blip does not page)

### Gate

- [x] `scripts/check.sh` ends `PASS: 49 FAIL: 0 MISSING: 0`
- [x] `scripts/check-fluentbit-config.py` — new: runs the rendered config through
  `fluent-bit --dry-run` in the pinned image, and asserts the three-label
  cardinality bound structurally

## New gaps found and recorded (not fixed here)

| # | Gap | Where | Why it is not fixed in this branch |
|---|---|---|---|
| U1 | **Node budget does not fit.** 3600m / 4048Mi of requests against 1830m / 3741Mi schedulable = **196.7% CPU, 108.2% RAM**. 2820m of it is `boutique`. | `docs/resource-budget.md` | The cause is `apps/boutique`'s HPA minReplicas 2 and the workload-node taint — both Phase 4/6 and SPEC unresolved Q1. Nothing in `observability/` can close a 1770m gap. |
| U2 | A t3.medium is **burstable at a 20% baseline ≈ 400m sustained**, not 2000m. The requests sum is not the binding limit — the sustained CPU is. | `docs/resource-budget.md`, SPEC Q1 | Node-shape decision, same blocker as U1. |
| U3 | The app-scoped `LokiRequestErrors` alert used two series that do not exist. Fixed to real Fluent Bit counters; the namespace-scoped half is now `LokiLogLinesDropped` (server-side). | `observability/rules/boutique-alerts.yaml` | needs a per-namespace Fluent Bit output to scope by namespace, which is a Phase 10 follow-up. |
| U4 | Traefik's default histogram buckets (`0.1, 0.3, 1.2, 5.0`) make the latency SLI coarse — p95 can only resolve to one of four values. | `docs/slo.md` §1, `boutique:latency_bucket_resolution_seconds` | `metrics.prometheus.buckets` is Phase 5 (k3s Traefik HelmChart). |
| U5 | The OTel collector exposes telemetry metrics on `0.0.0.0:8888` but no Service port names it, so it cannot be scraped by a ServiceMonitor. | — | The collector manifest is on the app branch, outside this branch's edit boundary. |
| U6 | The external synthetic probe has no target URL. | `observability/blackbox/values.yaml` | The hostname is a Phase 5 Terraform output. |
| U7 | Phase 11 is absent: no Tempo, and the collector has no `spanmetrics` connector, so `span:*` rules produce no series. | Phase 11 | Phase 11. |

## Not proven (requires a live cluster)

- Any alert firing in Alertmanager, and any SLO ratio being non-zero in a real
  query. `promtool test rules` proves the **rule logic**, not the routing.
- Loki actually enforcing retention, the stream count being ~90 rather than ~550,
  and the Fluent Bit pipeline delivering a real line. All three are Phase 10's
  exit criteria and need a cluster.
- The kubelet reservations (355 MiB / 170m) on the real node — they are the
  kubelet's documented defaults, not a measurement.
- Actual CPU/memory **usage**, as opposed to requests. No cluster exists.
