# boutique-platform — live progress

**Last updated: 2026-10-09 00:50 UTC** · rendered browser view: `docs/progress.html`
(regenerate with `python3 scripts/render-progress.py`)

---

## ▶ Where we are

**Phase 6 is written.** The manifest layer of the whole "beats upstream" claim exists and is
validated by command output, on branch `feat/app-hardening`. Nothing has been provisioned, and no
`kubectl apply` has been run anywhere — every number below comes from `kustomize build` on the
source, not from a cluster.

Measured on the rendered output, not on the source:

| Control | Count |
|---|---|
| `PodDisruptionBudget` | **13** (all 13 workloads) |
| `topologySpreadConstraints` | **13** |
| `seccompProfile: RuntimeDefault` | **13** |
| `runAsNonRoot: true` | **13** |
| `readOnlyRootFilesystem: true` | **14** (13 service containers + loadgenerator's initContainer) |
| `automountServiceAccountToken: false` | **26** (13 pod specs + 13 ServiceAccounts) |
| `HorizontalPodAutoscaler` | **10** — redis-cart and loadgenerator are exempt, with a reason the policy checks |
| `NetworkPolicy` | **14** — one default-deny plus one allow per service, every egress explicit |
| `kube-dns` egress carve-out | **13** (the rule upstream's `- {}` egress replaces) |
| `startupProbe` | **12** (90s budget for adservice's JVM and cartservice's .NET cold start) |

Memory requests: **2312 Mi (2.26 GiB)** for the `boutique` namespace — fits a t3.medium's 4 GiB
with ~1.1 GiB spare. CPU requests: **2820m** against a t3.medium's **2000m** — **does not fit**,
and that is the one number in this phase that is a finding rather than an achievement. Recorded in
`TASKS.md` U1 with three named closes.

**The negative control is the strongest evidence here:** the vendored upstream baseline, run
unchanged against this repo's own policy, fails with **42 violations** in per-document mode and
**54** in combined mode. The control fails; the rewrite passes.

### Still needs a decision from you

| # | Decision | Why it blocks | Measured |
|---|---|---|---|
| 1 | **Node shape.** As before | Phase 6 can actually schedule | **2820m of CPU requests vs 2000m on one t3.medium.** Either relax the workload-node taint (recommended, matches SPEC's own diagram) or accept Pending pods |
| 2 | **ALB or node-IP entry.** | Phase 5 | unchanged |
| 3 | **TLS path.** | Phase 5 | unchanged |


---

## Waves and phases

Legend — phase: `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked
Critic: `pending` · `pass` · `gap named`

### Wave A — Foundation
- `[~]` **Phase 0 — guardrails & validation harness** · critic: `pending`
  - `[x]` Live account evidence gathered (quota, instance types, blocked services, cost, VPC, SGs)
  - `[x]` Real Online Boutique `v0.10.7` architecture + what Google ships vs documents as guidance
  - `[x]` SPEC / ROADMAP / AGENTS / TASKS written
  - `[ ]` GitHub repo created, CI plan gate, `scripts/check.sh` green
  - `[ ]` Critic blind-compares the scaffold against the phase's exit criteria
- `[!]` **Phase 1 — cost guardrails (AWS Budget + OIDC + state bucket)** · blocked on decision to allow IAM changes
- `[!]` **Phase 2 — network + node identity** · blocked on decision 1

### Wave B — Cluster
- `[!]` **Phase 3 — k3s HA, 3 AZ, SSM-only** · blocked on decisions 1 + the first cost-bearing apply
- `[!]` **Phase 4 — cluster policy baseline (PSA restricted, quota, netpol with DNS carve-out, RBAC, etcd snapshots)**

### Wave C — Edge and workload
- `[!]` **Phase 5 — two-layer edge: ALB + WAF + TLS + access logs + Traefik** · blocked on decision 2
- `[~]` **Phase 6 — Boutique production-grade (PDB, HPA, topology spread, netpol, OTel, chaos)** · the phase the whole claim rests on
  - `[x]` Upstream `v0.10.7` vendored verbatim with provenance (URL, tag, sha256, licence)
  - `[x]` `apps/boutique/base/`: 13 workloads, every control present, CPU requests == limits
  - `[x]` `apps/boutique/netpol/`: default-deny + per-service allow **with the DNS egress carve-out**
  - `[x]` `policy/`: rego rules + 3 deliberately-failing fixtures, both conftest modes green
  - `[x]` OTel Collector with real processors (`memory_limiter`, `tail_sampling`, `batch`)
  - `[x]` `quota.yaml` sized with measured arithmetic; PSA `restricted` on `boutique`
  - `[x]` `scripts/chaos/inject-latency.sh` + the runbook, with the fault surface stated honestly
  - `[ ]` Cluster-dependent: pods `Available`, drain test, live `jsonpath` proof — blocked, see U1

### Wave D — CI/CD
- `[!]` **Phase 7 — Jenkins controller + ephemeral Kubernetes agents (JCasC)**
- `[!]` **Phase 8 — pipeline library: scan, sign, deploy, canary, auto-rollback**

### Wave E — Observability
- `[!]` **Phase 9 — Prometheus / Grafana / Alertmanager + golden signals**
- `[!]` **Phase 10 — Loki + Fluent Bit logs with bounded cardinality**
- `[!]` **Phase 11 — OTel Collector gateway + Tempo (beat upstream: it ships zero processors)**
- `[!]` **Phase 12 — SLOs, error budget, multiwindow multi-burn-rate alerts**

### Wave F — Operational clarity
- `[!]` **Phase 13 — runbooks, DR drill, evidence pack**
- `[!]` **Phase 14 — release readiness + teardown to $0**

---

## Critic verdicts

Each phase is judged by a fresh-context agent that reads the **real output**, never the builder's
summary, and blind-compares against the real Online Boutique deployment.

| Phase | Builder verdict | Critic verdict | Biggest gap named | Rounds |
|---|---|---|---|---|
| 0 | pending | pending | — | 0 |

---

## What is proven so far (real evidence, not reports)

- Account `348032171026` / `us-east-1`, default VPC `vpc-0cf47bfcd22729c1a`, 6 public subnets across 6 AZs
- Quota: **8.0 vCPU** running on-demand standard instances → 4 × t3-class total
- `t2.micro` **not** free-tier eligible; `t3.micro` = 1.0 GiB, `t3.small` = 2.0 GiB, `t3.medium` = 4.0 GiB
- NLB blocked account-wide (`network-load-balancer-capacity-units = 0`); **ALB works**
- Route 53 zones: 0. ACM certs: 0. NAT gateways: 0. EKS clusters: 0.
- Cost since account creation: **$0.00 every month**
- Online Boutique `v0.10.7` HEAD released 2026-09-18; images at `us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/<svc>:v0.10.7`
- Verified absent from upstream `v0.10.7` (so ours must add them): PodDisruptionBudget, HPA,
  topology spread, anti-affinity, priority classes, ResourceQuota/LimitRange, deployment
  `strategy`, egress DNS carve-out, private nodes, SLOs, any metrics instrumentation. Upstream's
  OTel collector ships **no processors at all**. Upstream `adservice` tracing is commented out.
- Verified absent and **not** to be built: `adServiceFailure`, `recommendationCacheFailure`
  (checked across v0.1.4–v0.10.7), `ml-pipeline/`, Cloud CDN, Argo CD / Config Sync descriptors

### Phase 6 manifest layer — 2026-10-09, from the render not the source

```
kustomize build apps/boutique/                2942 lines, 13 Deployments
kubeconform -strict -kubernetes-version 1.36.3 apps/ apps/boutique/netpol/ policy/tests/
  Summary: 136 resources found in 36 files - Valid: 136, Invalid: 0, Errors: 0
conftest test apps/boutique/base -p policy/          1044 tests, 1044 passed
conftest test apps/boutique/base -p policy/ --combine   18 tests,   18 passed
conftest test policy/tests/should-fail -p policy/       54 tests,   22 failures
conftest test apps/boutique/upstream-kubernetes-manifests.yaml -p policy/
                                                        648 tests,   42 failures  <-- the control
scripts/check.sh                             PASS: 50   FAIL: 0   MISSING: 0
gitleaks detect --no-git                      no leaks found
```

Also verified, from the source rather than from memory, because the wiring depends on it:

- `src/productcatalogservice/server.go` is the **only** reader of `EXTRA_LATENCY` in the tree, so
  it is the only chaos target.
- `src/shippingservice/main.go` has a second empty `initTracing()` — same upstream issue #422 as
  adservice. It was not in the brief; it is recorded in `docs/adr/0004-adservice-tracing-gap.md`.
- `src/cartservice/` has **no** OpenTelemetry reference at all — not a stub, never built.
- The six instrumented images read `COLLECTOR_SERVICE_ADDR` only and hard-code `AlwaysSample()`,
  so `OTEL_TRACES_SAMPLER*` is inert for them today. Set anyway, reason documented.
- The OTel Collector image declares `USER 10001:10001` (registry API, `sha256:5f92255513d9…`),
  so the manifest follows the image rather than upstream's `1000`.
- Upstream's collector runs an initContainer that curls `metadata.google.internal`. On AWS that
  fails, so the collector would never start. Replaced with a static ConfigMap.


---

## Cost ledger (recomputed by `scripts/cost-estimate.sh`)

| Component | Monthly | Notes |
|---|---|---|
| 3 × t3.medium | $91.28 | 0 free-tier hours → full price |
| 3 × 16 GiB gp3 | $1.44 | 30 GiB free |
| ALB + ~2 LCU | $28.11 | decision 2 |
| logs / snapshots / ECR | <$3 | retained logs have a lifecycle |
| **Total** | **≈$124/mo** | **≈$176 over the 43 days left in the plan window** |

Teardown at Phase 14 returns the account to $0. `destroy.yml` exists before the ALB exists.
