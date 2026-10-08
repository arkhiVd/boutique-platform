# boutique-platform — live progress

**Last updated: 2026-10-08 22:45 UTC** · rendered browser view: `docs/progress.html`
(regenerate with `python3 scripts/render-progress.py`)

---

## ▶ Where we are

**Wave A, Phase 0.** The repo's guardrails and the full phased plan are written against live
account evidence and against the real `GoogleCloudPlatform/microservices-demo` `v0.10.7`.
Nothing has been provisioned. Three decisions from Aravind unblock the rest.

### Needs a decision from you

| # | Decision | Why it blocks | Cost impact |
|---|---|---|---|
| 1 | **Node size.** `t3.small` (2 GiB) cannot host Boutique + Jenkins + Prometheus + Loki + Tempo (~9.5 GiB of requests on 6 GiB of RAM). `t3.medium` (4 GiB) × 3 fits, but has **zero free-tier hours**. | Phase 3 provisions nodes | $85 (t3.small+no ALB) → $176 (t3.medium+ALB) over the 43-day window |
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
  - `[ ]` GitHub repo created, CI plan gate, `scripts/check.sh` green
  - `[ ]` Critic blind-compares the scaffold against the phase's exit criteria
- `[!]` **Phase 1 — cost guardrails (AWS Budget + OIDC + state bucket)** · blocked on decision to allow IAM changes
- `[!]` **Phase 2 — network + node identity** · blocked on decision 1

### Wave B — Cluster
- `[!]` **Phase 3 — k3s HA, 3 AZ, SSM-only** · blocked on decisions 1 + the first cost-bearing apply
- `[!]` **Phase 4 — cluster policy baseline (PSA restricted, quota, netpol with DNS carve-out, RBAC, etcd snapshots)**

### Wave C — Edge and workload
- `[!]` **Phase 5 — two-layer edge: ALB + WAF + TLS + access logs + Traefik** · blocked on decision 2
- `[!]` **Phase 6 — Boutique production-grade (PDB, HPA, topology spread, netpol, OTel, chaos)** · the phase the whole claim rests on

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
