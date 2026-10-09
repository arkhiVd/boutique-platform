# boutique-platform — live progress

**Last updated: 2026-10-09** · rendered browser view: `docs/progress.html`
(regenerate with `python3 scripts/render-progress.py`)

---

## ▶ Where we are

**Wave E, Phases 9 / 10 / 12 — observability metrics, logs and SLOs.** Built on
`feat/observability-metrics-logs`. Everything is validated by render and by the
tool that would catch the failure; nothing is deployed, because there is no
cluster yet. Phase 11 (traces) is still open.

**The headline number, stated plainly because it is the one that matters:**
the platform **does not fit** on one t3.medium. `docs/resource-budget.md` holds
the arithmetic — **3600m / 4048Mi of requests against 1830m / 3741Mi schedulable
= 196.7% CPU and 108.2% RAM**, of which **2820m is the `boutique` namespace's
own request**, not the observability stack. That is a Phase 4/6 and
SPEC-question-1 blocker, and no amount of metrics tuning closes it.

### Needs a decision from you

| # | Decision | Why it blocks | Cost impact |
|---|---|---|---|
| 0 | **Workload-node shape.** This is now a measured number, not an estimate. `boutique` alone requests 2820m of a 1830m node. SPEC's own diagram assumes the 3 t3.small servers share the load; its taint line contradicts that. | Phase 3 and every phase after it | $0 — relaxing the taint. A larger node is blocked by the 8.0 vCPU quota. |
| 1 | **Node size.** `t3.small` (2 GiB) cannot host Boutique + Jenkins + Prometheus + Loki + Tempo. `t3.medium` (4 GiB) × 3 fits, but has **zero free-tier hours**. | Phase 3 provisions nodes | $85 (t3.small+no ALB) → $176 (t3.medium+ALB) over the 43-day window |
| 2 | **ALB or node-IP entry.** The ALB gives the two-layer edge, WAF and access logs; it costs ~$28/mo. | Phase 5 | ~$40 of the window |
| 3 | **TLS path.** No Route 53 zone and no ACM cert exist, so the default is a self-signed imported cert unless we use `<lb>.ip.sslip.io` + HTTP-01. | Phase 5 | $0 either way |

---

## Waves and phases

Legend — phase: `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked
Critic: `pending` · `pass` · `gap named`

### Wave A — Foundation
- `[~]` **Phase 0 — guardrails & validation harness** · critic: `pending`
  - `[x]` Live account evidence gathered (quota, instance types, blocked services, cost, VPC, SGs)
  - `[x]` Real Online Boutique `v0.10.7` architecture + what Google ships vs documents as guidance
  - `[x]` SPEC / ROADMAP / AGENTS / TASKS written
  - `[x]` `scripts/check.sh` green — **49 PASS / 0 FAIL / 0 MISSING**
  - `[ ]` Critic blind-compares the scaffold against the phase's exit criteria
- `[!]` **Phase 1 — cost guardrails (AWS Budget + OIDC + state bucket)** · blocked on decision to allow IAM changes
- `[!]` **Phase 2 — network + node identity** · blocked on decision 1

### Wave B — Cluster
- `[!]` **Phase 3 — k3s HA, 3 AZ, SSM-only** · blocked on decisions 0 + 1 + the first cost-bearing apply
- `[!]` **Phase 4 — cluster policy baseline (PSA restricted, quota, netpol with DNS carve-out, RBAC, etcd snapshots)**

### Wave C — Edge and workload
- `[!]` **Phase 5 — two-layer edge: ALB + WAF + TLS + access logs + Traefik** · blocked on decision 2
- `[~]` **Phase 6 — Boutique production-grade (PDB, HPA, topology spread, netpol, OTel, chaos)** · manifest layer done on `feat/app-hardening`; 2312Mi/2820m measured, recorded as blocker U1

### Wave D — CI/CD
- `[!]` **Phase 7 — Jenkins controller + ephemeral Kubernetes agents (JCasC)**
- `[!]` **Phase 8 — pipeline library: scan, sign, deploy, canary, auto-rollback**

### Wave E — Observability
- `[~]` **Phase 9 — Prometheus / Grafana / Alertmanager + golden signals** · built and validated; cluster-side proof pending
  - Prometheus `retention: 7d`, 1 replica, 30s scrape, `sampleLimit: 10000`
  - Grafana: sidecar dashboards + Loki datasource with a fixed uid, password from a Secret
  - Alertmanager: `page` → SNS (continue) and `ticket` → SNS
  - KSM + node-exporter at their request floors
  - 9 golden-signal rules, 9 alerts, 19 SLI recording rules — all `promtool`-clean
  - 4 dashboards on `grafana_dashboard: "1"`, all JSON-parsed
  - Traefik / Jenkins / blackbox / **Loki** / **Fluent Bit** ServiceMonitors
- `[~]` **Phase 10 — Loki + Fluent Bit logs with bounded cardinality** · built and validated; cluster-side proof pending
  - Loki `SingleBinary`, filesystem on gp3, `retention_period: 168h` enforced by the compactor
  - Bound in numbers: **90 streams** ({namespace, app, container}) instead of ~550 ({namespace, pod, container}); `pod` in structured metadata
  - 7 parsers for the six real formats, a Loki output with exactly 3 labels
  - 4 Loki alerts; a runbook with the LogQL path across three services by request ID
- `[!]` **Phase 11 — OTel Collector gateway + Tempo** · the collector ships (2 replicas, real processors, memory_limiter + tail_sampling + batch); Tempo and the spanmetrics connector do not. `span:*` rules written, produce no series.
- `[~]` **Phase 12 — SLOs, error budget, multiwindow multi-burn-rate alerts** · built and validated
  - 99.9% availability, 99% latency, both at SRE Workbook Table 5.2 windows
  - `promtool test rules` → **SUCCESS** on all three cases: the 14.4x page fires, the 6x and 1x tickets do not, and a 1-in-20-for-10-minutes blip does not page

### Wave F — Operational clarity
- `[!]` **Phase 13 — runbooks, DR drill, evidence pack** · `find-the-failing-checkout.md` written
- `[!]` **Phase 14 — release readiness + teardown to $0**

---

## Critic verdicts

Each phase is judged by a fresh-context agent that reads the **real output**, never the builder's
summary, and blind-compares against the real Online Boutique deployment.

| Phase | Builder verdict | Critic verdict | Biggest gap named | Rounds |
|---|---|---|---|---|
| 0 | pending | pending | — | 0 |
| 9 | built, render-validated | pending | node CPU over-commit (196.7%) | 0 |
| 10 | built, binary-validated | pending | retention and 90-stream bound unmeasured | 0 |
| 12 | built, promtool-tested | pending | alerts never fired live | 0 |

---

## What is proven so far (real evidence, not reports)

- Account `348032171026` / `us-east-1`, default VPC `vpc-0cf47bfcd22729c1a`, 6 public subnets across 6 AZs
- Quota: **8.0 vCPU** running on-demand standard instances → 4 × t3-class total
- `t2.micro` **not** free-tier eligible; `t3.micro` = 1.0 GiB, `t3.small` = 2.0 GiB, `t3.medium` = 4.0 GiB
- NLB blocked account-wide (`network-load-balancer-capacity-units = 0`); **ALB works**
- Route 53 zones: 0. ACM certs: 0. NAT gateways: 0. EKS clusters: 0.
- Cost since account creation: **$0.00 every month**
- Online Boutique `v0.10.7` HEAD released 2026-09-18
- Verified absent from upstream `v0.10.7`: PodDisruptionBudget, HPA, topology
  spread, anti-affinity, priority classes, ResourceQuota/LimitRange, deployment
  `strategy`, egress DNS carve-out, private nodes, SLOs, **any metrics
  instrumentation**. Upstream's OTel collector ships **no processors at all**.
- **Node capacity, measured from the renders:** 3600m / 4048Mi of requests vs
  1830m / 3741Mi schedulable = **196.7% CPU, 108.2% RAM — does not fit.** Arithmetic
  and every remedy, quantified, in `docs/resource-budget.md`.
- **The Fluent Bit config did not start.** Three fatal errors shipped in it and
  passed `helm lint --strict` and `helm template`: a `Format none` parser, an
  Oniguruma-invalid `(?s:...)` regex, `Parser_Cri On` on a filter that rejects it —
  plus no `[OUTPUT]` at all, so the chart's default of two *elasticsearch*
  outputs was in force. All four were found by running the pinned
  `fluent/fluent-bit:5.1.3` binary against the render, and `scripts/check.sh`
  now runs that on every gate.

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
