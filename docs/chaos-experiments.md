# Chaos experiments

Two experiments, and only two, because the application has exactly two fault-injection surfaces.
Everything in this file has been checked against the source at `v0.10.7`; nothing here is invented.

## The fault surface, stated honestly

| Mechanism | Exists upstream? | Where |
|---|---|---|
| `EXTRA_LATENCY` environment variable | **Yes** — the only one | `src/productcatalogservice/server.go` reads it and sleeps that duration on every call. Documented in that service's README as `EXTRA_LATENCY="5.5s"`. |
| `adServiceFailure` flag | **No** | Absent from every tag v0.1.4 .. v0.10.7. There is no branch in the code for it. |
| `recommendationCacheFailure` flag | **No** | Same. SPEC.md lists both as non-goals. |
| Pod / node deletion | **n/a** | A Kubernetes operation, not an application flag. |

A grep for either flag name across the whole upstream tree returns nothing. They cannot be
injected, and this document does not pretend otherwise.

## Test 1 — latency injection

```bash
scripts/chaos/inject-latency.sh 90s
```

What it does, in order:

1. Reads the current `Aggregated` line from the loadgenerator's log (the baseline).
2. `kubectl -n boutique set env deploy/productcatalogservice EXTRA_LATENCY=2s`
3. Waits for the rollout to complete.
4. Sleeps the duration.
5. `kubectl -n boutique set env deploy/productcatalogservice EXTRA_LATENCY-` — the trailing `-`
   deletes the variable. This is the step people forget, and forgetting it turns an experiment
   into an incident.
6. Waits for the rollout, then prints the loadgenerator's `Aggregated` line again.

The equivalent Kustomize-native form, if you would rather keep the injection in-tree rather than
in a running cluster, is `apps/boutique/chaos/latency-patch.yaml` applied as a strategic-merge
patch:

```bash
kubectl -n boutique patch deploy/productcatalogservice --type=strategic \
  --patch-file apps/boutique/chaos/latency-patch.yaml
```

### Assertions

| # | Assertion | How to read it | Expected |
|---|---|---|---|
| 1 | loadgenerator request error count is **unchanged** | the `Aggregated` line's `Error` column, before vs after | 0 → 0 |
| 2 | productcatalogservice p95 latency moves | `promtool query instant` on the Phase 12 recording rule, or `kubectl top pod -n boutique` for the CPU drop | ≥ 2s, since the sleep is inside the handler |
| 3 | nothing restarts | `kubectl get pods -n boutique` before and after | no `RESTARTS` increment. A restart here means the startup probe failed, which is a different bug |
| 4 | no pod is OOMKilled | `kubectl get events -n boutique --field-selector reason=OOMKilling` | empty |

Assertion 1 is the one the PDBs and HPAs are actually for. If 2s of injected latency causes
request failures, the failures are in the *callers'* timeouts, not in the latency itself, and that
is the finding the experiment exists to produce.

### Residual risk

2s was chosen so the locust client's own timeout is not hit. It has not been measured against the
real frontend/checkout timeout values — there is no cluster yet — so the first run of this
experiment should use a shorter duration (10s of injection, not 90s) and watch assertion 1 rather
than assuming it.

## Test 2 — voluntary disruption (drain)

### 2a. Single-pod eviction

```bash
kubectl -n boutique delete pod -l app=frontend --wait=false
kubectl -n boutique rollout status deploy/frontend
kubectl -n boutique logs deploy/loadgenerator --tail=2000 | grep Aggregated
```

Assertion: the loadgenerator's error count stays at 0 across the eviction. This is the assertion
that `maxUnavailable: 1` on `frontend`'s PDB and `minReplicas: 2` on its HPA are jointly
providing. With one replica, the same command takes the edge down and the assertion fails —
which is precisely why upstream's single-replica default is worth changing.

Repeat for each of `checkoutservice`, `cartservice`, `productcatalogservice`, `adservice`. Do **not**
run it for `redis-cart`; see 2b.

### 2b. Node drain

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

**This test is not safe to run against the SPEC's one-workload-node topology, and the claim it is
supposed to prove is not currently true.** Written out plainly:

- `apps/boutique/` schedules every workload onto nodes that carry the `boutique` namespace
  toleration. In the SPEC's recommended shape there is exactly **one** such node (a t3.medium).
  Draining it leaves nowhere for any pod to go, so every pod in the namespace stops and the app is
  down for the duration of the drain.
- The PDBs change *what a drain can take*, not *where it goes*. `maxUnavailable: 1` on a
  2-replica deployment caps the disruption at one pod; it does not create a second node.
- `redis-cart`'s PDB is `minAvailable: 1`, which means it blocks voluntary eviction entirely. A
  drain of the node holding it will hang at that pod until the budget is overridden. That is
  intentional: an evicted `redis-cart` empties every cart silently, so the budget converts a
  silent data-loss event into a loud blocked drain that an operator has to acknowledge. The
  runbook's answer is to delete the budget explicitly as part of a planned maintenance window, not
  to have it be quietly ignored.

So the honest statement of what the drain test proves **today**:

| Topology | Expected result |
|---|---|
| 1 workload node, drain it | **App down for the drain duration.** Zero failed requests is NOT achievable and is not claimed. |
| 1 workload node, delete one pod (test 2a) | Zero failed loadgenerator requests. Proven. |
| 2+ workload nodes, drain one | Zero failed loadgenerator requests, subject to `redis-cart`'s PDB and the CPU-requests over-commit recorded in `apps/boutique/quota.yaml`. The surviving node has 2000m of CPU against 2820m of requests, so the evicted pods will be **Pending**, not running. |

That last row is the real reason the "one node drain causes zero failed requests" acceptance
criterion in SPEC.md cannot be signed off in this phase, and the fix is the same
SPEC-unresolved-question-1 decision that `quota.yaml` records: either a second schedulable
workload node, or relaxing the workload-node taint so `boutique` can use the three k3s servers.

### What would make the drain claim provable

1. A second node with the workload taint (or the taint relaxed).
2. `redis-cart`'s PDB handled explicitly during the drain, as above.
3. The CPU request total brought under the surviving node's capacity.
4. A recorded run with the loadgenerator's `Aggregated` line before, during and after, attached to
   `docs/evidence/`.

Until then this document is the record of the gap, and the gap is the finding.
