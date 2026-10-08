# apps/boutique — the vendored baseline and the hardened rewrite

Two things live in this directory: the unmodified upstream manifests, kept as provenance, and the
production rewrite of the same application. The whole point of the layout is that the second can
be diffed against the first.

```
apps/boutique/
├── upstream-kubernetes-manifests.yaml   verbatim upstream. DO NOT EDIT.
├── namespace.yaml                       `boutique`, PSA restricted in all three modes
├── priorityclass.yaml                   biz / observability / batch
├── quota.yaml                           ResourceQuota + LimitRange, with the arithmetic
├── Kustomization                        the build entry point (`kubectl kustomize apps/boutique/`)
├── base/                                the 12 Boutique workloads, one file per service
├── netpol/                              default-deny + one allow policy per service, DNS carve-out included
├── observability/                       namespace + OTel Collector, in namespace `observability`
└── chaos/                               the EXTRA_LATENCY patch, and why nothing else
```

## Build

```bash
kubectl kustomize apps/boutique/ > rendered.yaml
```

The collector is not under `base/` on purpose. A Kustomize `namespace:` field overwrites the
namespace of *every* resource it touches, including ones that already declare one, so putting the
collector inside `base/`'s `namespace: boutique` would silently relocate it into `boutique` and
break the `opentelemetrycollector.observability.svc.cluster.local:4317` endpoint every service
now points at. `observability/` is its own Kustomization with no namespace directive.

## What was added, and what upstream ships instead

| Control | Upstream v0.10.7 | Here |
|---|---|---|
| `PodDisruptionBudget` | absent, all 13 workloads | all 13 |
| `HorizontalPodAutoscaler` | absent, all 13 | 10. See the exclusions below. |
| `topologySpreadConstraints` | absent, all 13 | all 13, `ScheduleAnyway` |
| `podAntiAffinity` | absent, all 13 | all 13, preferred weight 100 |
| `priorityClassName` | absent, all 13 | all 13, three classes |
| `ResourceQuota` / `LimitRange` | absent | `quota.yaml`, with the sums |
| `strategy` / `revisionHistoryLimit` / `progressDeadlineSeconds` | absent, all 13 | all 13 |
| `seccompProfile` | absent, all 13 | all 13, pod-level `RuntimeDefault` |
| `automountServiceAccountToken: false` | absent, all 13 | all 13 (pod and ServiceAccount) |
| `startupProbe` | absent, all 13 | all 13 |
| OTel `OTEL_EXPORTER_OTLP_ENDPOINT` | absent | 9 services |
| OTel Collector **processors** | `processors:` is empty | `memory_limiter`, `tail_sampling`, `batch` |
| NetworkPolicy | opt-in component, all egress `- {}` | `netpol/`, every egress explicit |

### The two HPA exclusions

- **`redis-cart`** — the store is a single `emptyDir` in a single pod. A second replica is not a
  second cache, it is a second divergent one. Scaling it is a data-model change.
- **`loadgenerator`** — the pod *is* the load. `USERS=10, RATE=1` per pod, so scaling it multiplies
  demand on every other service instead of adding capacity.

And one more, in `observability/`:

- **`opentelemetrycollector`** — runs `tail_sampling`, whose per-trace decision is made from the
  spans of that trace. Scaling the collector without a trace-aware load-balancing exporter in
  front of it silently corrupts sampling decisions, so the replica count is manual (and set to 2)
  until Phase 11 lands that exporter.

## What was dropped

- **`frontend-external`** (`type: LoadBalancer`) — SPEC.md pins NLB as blocked account-wide
  (`network-load-balancer-capacity-units = 0`) and requires the two-layer ALB + Traefik edge. A
  cloud load balancer here would fail to provision *and* bypass the Web ACL.
- **`sidecar.istio.io/rewriteAppHTTPProbers`** on `frontend` and `loadgenerator` — SPEC.md names a
  service mesh an explicit non-goal, so an Istio sidecar hint is a pointer to infrastructure this
  platform does not run.

## What was fixed, not relaxed

Upstream's own manifests were checked against the `restricted` PSA profile that `namespace.yaml`
enforces. Two things failed and were fixed rather than accommodated:

1. **`seccompProfile`** was missing on all 13 workloads. Added at pod level, which PSA accepts and
   which reaches initContainers too.
2. **`redis-cart` had no ServiceAccount** — it was the only workload running under `default`, and
   `default` gets a token projected. It now has a dedicated one with
   `automountServiceAccountToken: false`, like the other twelve.

One deliberate deviation from upstream's values: the OTel Collector runs as `10001:10001`, not
`1000`. Upstream sets 1000 there, but the image it runs declares `USER 10001:10001` (resolved from
the registry API on 2026-10-08) and overriding a declared image user is how volume permission
errors reach production. The control that matters for PSA — `runAsNonRoot: true` — is upstream's
and is kept. Evidence is in `observability/opentelemetrycollector.yaml`.

## Known gaps, recorded not hidden

- **`adservice` and `shippingservice` tracing is stubbed upstream** and is not fixed here.
  `docs/adr/0004-adservice-tracing-gap.md`.
- **`cartservice` has no instrumentation at all upstream.** Not a stub — never built.
- **The `OTEL_TRACES_SAMPLER*` variables are inert** for the six instrumented images; they
  hard-code `AlwaysSample()`. The real sampling decision is the collector's `tail_sampling`. Set
  so a successor image picks them up.
- **The CPU request total (2820m) exceeds one t3.medium's 2000m.** `quota.yaml` carries the
  arithmetic and the three options. Ties to SPEC.md unresolved question 1.
- **`SHOPPING_ASSISTANT_SERVICE_ADDR` points at a service that this deployment does not ship.**
  It is an opt-in Kustomize component upstream and needs AlloyDB. Kept for fidelity; the
  loadgenerator does not exercise `/assistant`.
