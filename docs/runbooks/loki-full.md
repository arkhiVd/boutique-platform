# Runbook — Loki's volume is filling up, or log lines are being dropped

**Last verified: 2026-10-17** — every fenced command below was executed by
`scripts/check-runbooks.py` against the live cluster: reads run for real, writes as
server-side dry-runs (output in `docs/evidence/phase-13/runbook-check.txt`).

Loki runs single-binary on a 10 GiB gp3 claim (`storage-loki-0`) with a
filesystem backend and `retention_period: 168h`, enforced by its local compactor
(`observability/loki/values.yaml`). The alerts are `LokiLogLinesDropped`,
`LokiRequestErrors`, `LokiRequestLatency` and `LokiIngesterStreamsHigh`
(`observability/loki/alerts.yaml`).

## Diagnostic entry point

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

# How full is the claim? (used / capacity)
promtool query instant http://localhost:9090 \
  'kubelet_volume_stats_used_bytes{persistentvolumeclaim="storage-loki-0"}
   / kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="storage-loki-0"}'

# Is anything being dropped on the way in? Non-zero = lines lost.
promtool query instant http://localhost:9090 'sum(rate(fluentbit_output_errors_total[10m]))'
promtool query instant http://localhost:9090 'sum(rate(loki_discarded_samples_total[10m])) by (reason)'

kubectl -n observability get pod loki-0 -o wide
kubectl -n observability logs loki-0 -c loki --tail=50 | grep -iE "error|retention|compact"
```

## 1. The volume is filling faster than retention empties it

Retention deletes chunks older than 168h, so a full volume means ingest grew.
Find the stream that grew before deciding anything:

```bash
kubectl -n observability port-forward svc/loki 3100:3100 &
# The noisiest apps over the last hour, by bytes.
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=topk(5, sum by (namespace, app) (bytes_over_time({namespace=~".+"}[1h])))' \
  | jq -r '.data.result[] | "\(.metric.namespace)/\(.metric.app) \(.value[1])"'
```

**Fix, in order of preference:**

1. Fix the noisy workload (a debug log level left on is the usual one).
2. Shorten retention in `observability/loki/values.yaml` (`limits_config.retention_period`)
   and `helm upgrade loki observability/loki -n observability`.
3. Grow the claim (gp3 expands online; it cannot shrink):

```bash
kubectl -n observability patch pvc storage-loki-0 --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"15Gi"}}}}'
```

## 2. Fluent Bit reports output errors

```bash
kubectl -n observability get pods -l app.kubernetes.io/name=fluent-bit -o wide
kubectl -n observability logs -l app.kubernetes.io/name=fluent-bit --tail=20 --prefix | grep -iE "error|retry"
```

Output errors with a healthy Loki are usually Loki's per-stream limits
(`loki_discarded_samples_total` by `reason` above names which).

## Rollback

Retention and limits are a `helm rollback loki <revision> -n observability`
(`rollback.md`). A PVC expansion is not reversible.

## Verify

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
promtool query instant http://localhost:9090 \
  'kubelet_volume_stats_used_bytes{persistentvolumeclaim="storage-loki-0"}
   / kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="storage-loki-0"}'
```
