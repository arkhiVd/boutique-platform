# Runbook — Prometheus restarts, is slow to come back, or is blind

**Last verified: 2026-10-17** — every fenced command below was executed by
`scripts/check-runbooks.py` against the live cluster: reads run for real, writes as
server-side dry-runs (output in `docs/evidence/phase-13/runbook-check.txt`).

One Prometheus replica (`prometheus-kube-prometheus-stack-prometheus-0`) on an
8 GiB gp3 claim, limit 768Mi, 7d retention. It **prefers the agent node**: on a
2 GB etcd follower it left 36 MiB available and took the cluster's etcd leader
down with it (2026-10-17). Its claim is bound to us-east-1c, so it can run on the
agent or on follower `i-08c5`, nowhere else. Its priority (500) is below the
shop's (1000) on purpose: under pressure it waits, the shop does not.

While Prometheus is down, **no alert can fire**, so this runbook is urgent even
when the shop is fine.

## Diagnostic entry point

```bash
kubectl -n observability get pod prometheus-kube-prometheus-stack-prometheus-0 -o wide
kubectl -n observability describe pod prometheus-kube-prometheus-stack-prometheus-0 | sed -n '/Events/,$p' | tail -8

# Restarts and the last termination reason (OOMKilled = the 768Mi limit).
kubectl -n observability get pod prometheus-kube-prometheus-stack-prometheus-0 \
  -o jsonpath='{range .status.containerStatuses[*]}{.name} restarts={.restartCount} last={.lastState.terminated.reason}{"\n"}{end}'

kubectl -n observability logs prometheus-kube-prometheus-stack-prometheus-0 -c prometheus --tail=30 \
  | grep -iE "WAL|replay|error|out of memory|compaction"
```

## 1. Pending: "Insufficient memory" or "didn't match PersistentVolume's node affinity"

The claim pins it to us-east-1c. If neither 1c node has room, move a stateless
shop pod off the agent (the scheduler will not, because shop pods outrank it):

```bash
AGENT="$(kubectl get nodes -l boutique.io/role=agent -o name | head -1)"
kubectl describe "$AGENT" | sed -n '/Allocated resources/,/Events/p'
kubectl cordon "${AGENT#node/}"
kubectl -n boutique delete pod -l app=emailservice --field-selector "spec.nodeName=${AGENT#node/}"
kubectl uncordon "${AGENT#node/}"
```

## 2. CrashLoop with OOMKilled

Head series grew past what 768Mi holds. Find what grew before raising the limit:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
promtool query instant http://localhost:9090 'prometheus_tsdb_head_series'
promtool query instant http://localhost:9090 'topk(10, count by (job) ({__name__=~".+"}))'
```

The scrape-side guards are `sampleLimit` per target and the metric drops for
the k3s apiserver and kubelet in `observability/kube-prometheus-stack/values.yaml`.

## 3. Up, but targets are down (Prometheus is blind)

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.health!="up") | "\(.labels.job) \(.scrapeUrl) \(.lastError)"'
```

`scripts/doctor.sh` fails on any down target. The causes found so far are each
written up in `PROGRESS.md` (2026-10-17): sample limit, label length, a
NetworkPolicy, a wrong metrics path.

## Verify

```bash
kubectl -n observability get pod prometheus-kube-prometheus-stack-prometheus-0
scripts/doctor.sh
```
