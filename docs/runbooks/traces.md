# Runbook — the traces layer (Phase 11)

**Last verified: 2026-10-14** — verified against the sources and the rendered
manifests (grafana/tempo@v2.9.0 for metric names and API paths,
otelcol-contrib v0.160.0 for the connector's config schema), not against a
live cluster: Phase 11 is manifest-and-config work, and the apply is still
Aravind's gate. Every command below is the one that will be run on the first
deploy; where a command's output could not be produced yet, it says so.

The traces layer has three moving parts and this runbook has one scenario per
part:

| Symptom | The part | Section |
|---|---|---|
| A trace that should exist is not in Tempo | collector → Tempo path, or Tempo itself | 1 |
| `traces_span_metrics_*` series stop appearing | the collector's spanmetrics pipeline | 2 |
| Tempo's disk fills up | the local (gp3) trace store | 3 |

## The pipeline, in one diagram

```
app pods --OTLP/4317--> collector (2 replicas)
                          |  traces:            memory_limiter -> tail_sampling -> batch -> otlp/tempo -> Tempo:4317
                          |  traces/spanmetrics: memory_limiter -> batch -> spanmetrics connector
                          |  metrics/spanmetrics: ... -> prometheus exporter :9464 --scrape--> Prometheus
                          `- telemetry :8888 (otelcol_* self-metrics) ------------scrape--> Prometheus
Tempo (single binary, gp3 10Gi) --metrics generator (service-graphs) --remote-write--> Prometheus
Grafana: Tempo datasource (uid `tempo`), serviceMap -> Prometheus (uid `prometheus`)
```

## Diagnostic entry point

```bash
export KUBECONFIG=~/.kube/boutique-prod.yaml

# Is every part of the path present, and Ready?
kubectl get pods -n observability -o wide | grep -E 'tempo|opentelemetrycollector'

# Tempo's own health (the distributor's /ready: 200 = the ingester ring is happy).
kubectl -n observability port-forward svc/tempo 3200:3200 &
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3200/ready

# The Prometheus every `promtool query` below runs against. Keep both
# port-forwards in the shell this runbook is being run from; the service name
# is the kube-prometheus-stack release name (see observability/tempo/values.yaml
# for why that is load-bearing).
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

# Collector targets: two endpoints per pod — telemetry (8888) and metrics (9464).
kubectl -n observability get svc opentelemetrycollector -o wide
promtool query instant http://localhost:9090 'up{job="opentelemetrycollector"}'
# No port-forward handy? The same query from a pod inside the cluster:
#   kubectl -n observability run curl --rm -it --image=curlimages/curl --restart=Never -- \
#     curl -s 'http://kube-prometheus-stack-prometheus.observability.svc:9090/api/v1/query?query=up'
```

The rule: `up{job="opentelemetrycollector"}` says whether the collector is
scrapeable; `absent(traces_span_metrics_calls_total{service_name="frontend"})`
says whether it is producing; `curl :3200/ready` says whether Tempo can accept.
Those three answers pick the section below.

---

## 1. A trace that should exist is not in Tempo

**Symptom:** a checkout was performed (loadgenerator log shows a completed
cart), the dashboard's request rate moved, but searching for the trace in
Tempo — or via the Grafana "Recent checkoutservice traces" panel — returns
nothing.

**Most likely causes, in order:**

1. The trace is still in the collector's tail-sampling `decision_wait` (5s) or
   Tempo's head block (5m cut, `ingester.max_block_duration` in
   observability/tempo/values.yaml) — wait 5 minutes before believing this is a
   failure.
2. The trace WAS sampled out: the probabilistic policy keeps a 10% baseline of
   successful traces. A single missing *successful* trace is the policy working.
   Every ERROR trace is kept — so if the trace you wanted was an error and it is
   missing, this is a real failure and causes 3-5 apply.
3. The collector → Tempo path is broken.
4. Tempo is not storing (disk, ring, compactor).

**Diagnose — work down the path, one hop at a time:**

```bash
# (a) Is the collector accepting spans at all? If this is flat, the problem is
# upstream of the traces layer (the app's OTLP wiring), not in Tempo.
promtool query instant http://localhost:9090 \
  'sum(rate(otelcol_receiver_accepted_spans[5m]))'

# (b) Is the collector FAILING to send to Tempo? send_failed climbing = Tempo
# is refusing or unreachable.
promtool query instant http://localhost:9090 \
  'sum by (exporter) (rate(otelcol_exporter_send_failed_spans{exporter="otlp/tempo"}[5m]))'

# (c) From the collector's own logs: a refused export logs an error naming the
# endpoint. (Both replicas; the -c is the container name.)
kubectl -n observability logs deploy/opentelemetrycollector -c otel-gateway --tail=200 \
  | grep -iE 'error|tempo|export' | tail -20

# (d) Does Tempo see the write? bytes received should move with traffic.
promtool query instant http://localhost:9090 \
  'sum(rate(tempo_distributor_bytes_received_total[5m]))'

# (e) Tempo's own errors, by route — the TempoRequestErrors alert's input.
promtool query instant http://localhost:9090 \
  'sum by (route) (rate(tempo_request_duration_seconds_count{status_code=~"5.."}[10m]))'

# (f) The ring: a single-binary Tempo has one ingester, in this pod. If /ready
# is not 200, the ring is the problem, not the data.
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3200/ready

# (g) The API directly, with the same TraceQL the dashboard uses. This is the
# command the Phase 11 exit criterion is proven with ("a trace for a checkout
# request spans frontend -> checkoutservice -> paymentservice").
curl -sG http://localhost:3200/api/search \
  --data-urlencode 'q={ resource.service.name = "checkoutservice" }' \
  --data-urlencode 'limit=5' | python3 -m json.tool

# Take a trace ID from the search result and fetch the full trace:
TRACE_ID='<one from the search result>'
curl -s "http://localhost:3200/api/traces/${TRACE_ID}" \
  | python3 -m json.tool | head -60
```

**Interpretation, one line per hop:**

| Where it broke | What it means | Fix |
|---|---|---|
| (a) flat | no spans reach the collector | check the app's `OTEL_EXPORTER_OTLP_ENDPOINT` and the collector Service DNS, not this runbook |
| (b) climbing | Tempo refuses writes | (f)/(e): ring or disk — sections below and 3 |
| (c) connection refused | the Tempo Service/endpoint is wrong | `kubectl -n observability get svc tempo`; the endpoint is `tempo.observability.svc.cluster.local:4317` |
| (d) flat, (b) flat | the collector is not exporting at all | `kubectl -n observability describe deploy/opentelemetrycollector` — a CrashLoop or a failing config render |
| (g) empty, (d) moving | data is arriving but not yet searchable | head-block cut: wait out `max_block_duration` (5m), or search by trace ID directly — search only sees persisted blocks |
| (g) empty, ring healthy, disk fine | compactor/retention: a 24h retention can delete what you are looking for | lower `retention` in observability/tempo/values.yaml is the wrong reflex; first confirm the trace's age |

**Rollback / recovery:** the collector is a rolling update
(`maxUnavailable: 0`), so a bad collector config is recovered by
`kubectl -n observability rollout undo deploy/opentelemetrycollector`. Tempo is
a StatefulSet with a PVC: `kubectl -n observability rollout undo sts/tempo`
restarts it without touching stored traces.

---

## 2. The spanmetrics connector produces no series

**Symptom:** the `TracesSpanmetricsMissing` alert is firing (or the traces
dashboard's "Spanmetrics series present?" stat says MISSING), and every
`span:*` panel is empty. Traces themselves may be flowing fine — this scenario
is specifically the metrics half.

**Diagnose:**

```bash
# (a) The alert's own expression. Empty result = the condition is true.
promtool query instant http://localhost:9090 \
  'absent(traces_span_metrics_calls_total{service_name="frontend", span_kind="SPAN_KIND_SERVER"})'

# (b) Are the scrape targets alive? Two per collector pod: telemetry + metrics.
promtool query instant http://localhost:9090 'up{job="opentelemetrycollector"}'

# (c) Is the prometheus exporter serving anything at all?
kubectl -n observability run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s http://opentelemetrycollector.observability.svc.cluster.local:9464/metrics \
  | grep -c traces_spanmetrics

# (d) The connector's own health, from the telemetry endpoint: a failing
# pipeline shows up as otelcol_processor_dropped_spans or a missing
# otelcol_exporter_send_failed_points on the `prometheus` exporter.
promtool query instant http://localhost:9090 \
  'sum by (exporter) (rate(otelcol_exporter_send_failed_points[5m]))'

# (e) The collector logs, both replicas: an invalid connector config makes the
# collector refuse to start — the pod would be CrashLooping, which (b) would
# already have shown as 0 targets.
kubectl -n observability logs deploy/opentelemetrycollector -c otel-gateway --tail=200 | grep -iE 'error|connector|spanmetrics'
```

**Interpretation:**

| Where it broke | What it means | Fix |
|---|---|---|
| (b) 0 targets | the ServiceMonitor or the Service ports are gone | `kubectl -n observability get servicemonitor opentelemetrycollector`; the ports are named `metrics` (9464) and `telemetry` (8888) in apps/boutique/observability/opentelemetrycollector.yaml |
| (b) targets up, (c) 0 | the exporter serves but the connector emits nothing | spans are not reaching the `traces/spanmetrics` pipeline: check (a) of section 1 — same receiver, so this usually means no spans at all |
| (c) non-zero, (a) still absent | Prometheus is not ingesting the scrape | check the ServiceMonitor's `release: kube-prometheus-stack` label — without it the operator's selector drops it silently |
| collector CrashLoop on start | the connector config was rejected by the binary | `kubectl -n observability logs` shows the field path; validate locally before re-applying: `otelcol-contrib validate --config apps/boutique/observability/opentelemetrycollector.yaml` after extracting the ConfigMap's `collector-gateway-config.yaml` key |

**Known-good local check (no cluster):**

```bash
kubectl -n observability get configmap collector-gateway-config \
  -o jsonpath='{.data.collector-gateway-config\.yaml}' > /tmp/collector.yaml
# on the operator machine, with the pinned binary:
curl -sSL https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.160.0/otelcol-contrib_0.160.0_linux_amd64.tar.gz | tar xz otelcol-contrib
./otelcol-contrib validate --config /tmp/collector.yaml
```

---

## 3. Tempo's disk filling up

**Symptom:** `TempoDiskNearFull` is firing, or traces stop being accepted
(section 1, hop (e) climbing, (f) not 200) while the PVC is at 100%.

Tempo's backend is a local filesystem on a 10Gi gp3 PVC
(`observability/tempo/values.yaml`). A full disk is a write refusal, not a
slowdown: the distributor fails pushes and every in-flight trace is lost. The
compactor deletes blocks older than the retention window (24h), so at a steady
ingest rate the volume should plateau — a climb to 100% means either ingest
grew or compaction stopped.

**Diagnose:**

```bash
# (a) How full is it, exactly? (the alert's own expression)
promtool query instant http://localhost:9090 \
  'kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"storage-tempo-.*"}
   / kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~"storage-tempo-.*"}'

# (b) Is ingest still moving? A rate that has grown since yesterday is the cause.
promtool query instant http://localhost:9090 \
  'sum(rate(tempo_distributor_bytes_received_total[5m]))'

# (c) Compactor errors — a compactor that cannot write blocks stops reclaiming.
kubectl -n observability logs sts/tempo --tail=200 | grep -iE 'compactor|compact|error' | tail -20

# (d) What is actually on the volume, and since when.
kubectl -n observability exec sts/tempo -- sh -c 'du -sh /var/tempo/traces/* 2>/dev/null | head; df -h /var/tempo'
```

**Fix, in order — the first two are values changes with an `helm upgrade`, the
last is an explicit capacity action:**

1. **Confirm retention is what you think it is.** The compactor's
   `block_retention` is rendered from `tempo.retention` (24h). Lowering it to
   12h halves the steady-state footprint:
   ```bash
   helm upgrade tempo observability/tempo -n observability --reuse-values --set tempo.tempo.retention=12h
   ```
   (The value is `tempo.tempo.retention` from the wrapper chart's point of view
   — the double nesting in observability/tempo/values.yaml is explained at the
   top of that file.)
2. **If ingest genuinely grew**, expand the claim. StatefulSet PVCs do not
   resize in place below Kubernetes 1.27's `VolumeAttributesClass` path; on
   this cluster the straightforward move is:
   ```bash
   kubectl -n observability edit pvc storage-tempo-0   # spec.resources.requests.storage: 20Gi
   ```
   k3s's local-path provisioner supports expansion; if it does not, the
   fallback is back up, delete the pod, recreate the claim — which is why the
   SPEC commits this state to gp3 with a snapshot/restore story rather than
   pretending it is disposable.
3. **Do not delete blocks by hand.** `tempo-cli` block deletion is a last
   resort and is deliberately not scripted here: the compactor's own retention
   is the control, and a manual delete races with it.

**Rollback:** every step above is reversible with the same `helm upgrade`
(the retention value is the only thing changed). A PVC expansion is not
reversible without restoring from a snapshot; take one before step 2:

```bash
# on a node, via SSM, or from the operator machine with the cluster's volume
# snapshot class configured (Phase 13 owns the snapshot runbook)
aws ec2 create-snapshot --volume-id <vol-...> --description "tempo pre-expansion $(date -u +%F)"
```

---

## What this runbook has NOT proven

Stated here rather than in a report: no command in this file has been run
against a live cluster, because Phase 11's apply gate has not been opened. The
metric names, label names, API paths and port names are verified from
grafana/tempo@v2.9.0 and otelcol-contrib v0.160.0 source and from the rendered
Helm output; the behaviour of the path end to end — a real trace traversing
frontend → checkoutservice → paymentservice, a real service graph, a real
disk-fill — is Phase 13's evidence pack, and the "Last verified" line at the
top of this file is the honest state until then.
