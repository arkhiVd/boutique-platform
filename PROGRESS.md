# boutique-platform — live progress

**Last updated: 2026-10-09** · rendered browser view: `docs/progress.html`
(regenerate with `python3 scripts/render-progress.py`)

---

## ▶ Where we are

**Phase 2 is built and planned; Phase 3 is being built on this branch.** `bootstrap/` (state
bucket, split OIDC plan/apply roles, $30 Budget, alert SNS topic) and `platform/` (VPC, three
public subnets in three AZs, IGW, four security groups, node instance profile, S3 backend with
native `use_lockfile` locking) both plan clean, both scan clean, and neither has been applied —
the apply is Aravind's gate, and the state bucket the platform stack stores state in does not
exist until that one-time bootstrap apply runs. The application manifest layer (Phase 6) and the
observability layer (Phases 9, 10, 12) are also built and validated by render, with no cluster to
deploy them into.

**What the two Wave-A plans say, exactly:**

```
terraform -chdir=bootstrap plan      Plan: 14 to add, 0 to change, 0 to destroy.
terraform -chdir=platform  plan      Plan: 42 to add, 0 to change, 0 to destroy.
```

**Cost of Wave A: $0.00.** VPC, IGW, subnets, route table, DHCP options, security groups, IAM
roles, instance profiles, the OIDC provider, the Budget and the SNS topic are all free. The first
billable thing in the repo is Phase 3's instances.

**The headline number, stated plainly because it is the one that matters:**
the platform **does not fit** on one t3.medium. `docs/resource-budget.md` holds the arithmetic —
**3600m / 4048Mi of requests against 1830m / 3741Mi schedulable = 196.7% CPU and 108.2% RAM**, of
which **2820m is the `boutique` namespace's own request**, not the observability stack. The fix is
architectural: **all four nodes are schedulable**, the k3s servers carry no control-plane taint,
because with a hard 8-vCPU quota there is no separate worker fleet to pair a control plane with
(kubeadm control-plane nodes are schedulable by default; EKS taints them). That gives
**7320m / ~9042Mi**, roughly 50% headroom on both axes.

Measured on the rendered output, not on the source: 13 PodDisruptionBudgets, 13
topologySpreadConstraints, 13 `seccompProfile: RuntimeDefault`, 13 `runAsNonRoot: true`,
14 `readOnlyRootFilesystem: true`, 26 `automountServiceAccountToken: false`, 10 HPAs
(redis-cart and loadgenerator exempt with reasons), 14 NetworkPolicies, 13 kube-dns egress
carve-outs, 12 startupProbes. The negative control is the strongest evidence here: the vendored
upstream baseline run unchanged against this repo's own policy fails with **42 violations** in
per-document mode and **54** in combined mode. The control fails; the rewrite passes.

### Needs a decision from you

| # | Decision | Why it blocks | Cost impact |
|---|---|---|---|
| 0 | **Node shape (resolved).** 3 × t3.small servers + 1 × t3.medium, all four schedulable. | Phase 3 | $0 — the shape already fits the 8.0 vCPU quota |
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
  - `[x]` `scripts/check.sh` green
  - `[ ]` Critic blind-compares the scaffold against the phase's exit criteria
- `[x]` **Phase 1 — cost guardrails (AWS Budget + OIDC + state bucket)** · built and planned
- `[x]` **Phase 2 — network + node identity: VPC, 3 public subnets, IGW, 4 SGs, node instance profile**

### Wave B — Cluster
- `[~]` **Phase 3 — k3s HA, 3 AZ, SSM-only** · built on this branch; blocked on the first cost-bearing apply
- `[~]` **Phase 4 — cluster policy baseline (PSA restricted, quota, netpol with DNS carve-out, RBAC, etcd snapshots)** · policy layer written on this branch; cluster-dependent proof pending

### Wave C — Edge and workload
- `[!]` **Phase 5 — two-layer edge: ALB + WAF + TLS + access logs + Traefik** · blocked on decision 2
- `[~]` **Phase 6 — Boutique production-grade (PDB, HPA, topology spread, netpol, OTel, chaos)** · manifest layer done; cluster-side proof blocked

### Wave D — CI/CD
- `[!]` **Phase 7 — Jenkins controller + ephemeral Kubernetes agents (JCasC)**
- `[!]` **Phase 8 — pipeline library: scan, sign, deploy, canary, auto-rollback**

### Wave E — Observability
- `[~]` **Phase 9 — Prometheus / Grafana / Alertmanager + golden signals** · built and validated; cluster-side proof pending
- `[~]` **Phase 10 — Loki + Fluent Bit logs with bounded cardinality** · built and validated; cluster-side proof pending
- `[!]` **Phase 11 — OTel Collector gateway + Tempo** · the collector ships (2 replicas, real processors); Tempo does not
- `[~]` **Phase 12 — SLOs, error budget, multiwindow multi-burn-rate alerts** · built and validated

### Wave F — Operational clarity
- `[!]` **Phase 13 — runbooks, DR drill, evidence pack**
- `[!]` **Phase 14 — release readiness + teardown to $0**

---

## Critic verdicts

| Phase | Builder verdict | Critic verdict | Biggest gap named | Rounds |
|---|---|---|---|---|
| 0 | pending | pending | — | 0 |
| 1 | built, planned, not applied | pending | the apply itself | 0 |
| 2 | built, planned, not applied | pending | flow logs off for cost; ALB→NodePort rule lands in Phase 5 | 0 |

---

## What is proven so far (real evidence, not reports)

- Account `348032171026` / `us-east-1`, default VPC `vpc-0cf47bfcd22729c1a`
- Quota: **8.0 vCPU** running on-demand standard instances → 4 × t3-class total
- `t2.micro` **not** free-tier eligible; `t3.micro` = 1.0 GiB, `t3.small` = 2.0 GiB, `t3.medium` = 4.0 GiB
- NLB blocked account-wide (`network-load-balancer-capacity-units = 0`); **ALB works**
- Route 53 zones: 0. ACM certs: 0. NAT gateways: 0. EKS clusters: 0.
- Cost since account creation: **$0.00 every month**
- Online Boutique `v0.10.7` HEAD released 2026-09-18
- Verified absent from upstream `v0.10.7` (so ours must add them): PodDisruptionBudget, HPA,
  topology spread, anti-affinity, priority classes, ResourceQuota/LimitRange, deployment
  `strategy`, egress DNS carve-out, private nodes, SLOs, any metrics instrumentation. Upstream's
  OTel collector ships **no processors at all**. Upstream `adservice` tracing is commented out.
- Verified absent and **not** to be built: `adServiceFailure`, `recommendationCacheFailure`
  (checked across v0.1.4–v0.10.7), `ml-pipeline/`, Cloud CDN, Argo CD / Config Sync descriptors
- k3s stable channel resolves to **v1.36.5+k3s1** (`curl -s https://update.k3s.io/v1-release/channels/stable`)

### Wave A — 2026-10-09, from the plans and the scanners, not from an apply

```
terraform -chdir=bootstrap plan -no-color
  Plan: 14 to add, 0 to change, 0 to destroy.

terraform -chdir=platform plan -no-color
  Plan: 42 to add, 0 to change, 0 to destroy.
  1 VPC, 1 IGW, 1 route table, 3 route table associations, 3 subnets, 2 DHCP resources,
  1 default security group, 4 security groups, 21 security group rules,
  1 node role, 1 instance profile, 1 inline role policy, 1 managed policy attachment,
  1 SSM parameter

checkov -d bootstrap     Passed checks: 69, Failed checks: 0, Skipped checks: 6
checkov -d platform      Passed checks: 103, Failed checks: 0
terraform fmt -check -recursive            clean, both stacks
tflint --recursive                          clean
gitleaks detect --no-git                    no leaks found
scripts/check.sh                            FAIL: 0
scripts/cost-estimate.sh                    $97.74/mo for the SPEC shape; Wave A itself adds $0.00
```

Also verified from the account, not from memory:

- `aws iam list-open-id-connect-providers` returned an **empty list**, so `bootstrap/` creates the
  GitHub Actions OIDC provider (guarded by `var.create_oidc_provider` for the day it already exists)
- The TLS thumbprint is read at plan time from
  `https://token.actions.githubusercontent.com/.well-known/openid-configuration`
- `AmazonSSMManagedInstanceCore` v2 in this account grants `ssmmessages:*`,
  `ssm:UpdateInstanceInformation` and `ec2messages:*` all on `"Resource": "*"` — that is the
  evidence for the node role's three wildcard-resource statements
- `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` → **8.0 vCPU**,
  asserted by a plan-time check block that warns when `instance_type_*` would exceed it
- One negative test, run and recorded: `terraform plan -var instance_type_worker=t3.xlarge` →
  `Warning: Check block assertion failed` with the arithmetic in the message

---

## Cost ledger (recomputed by `scripts/cost-estimate.sh`)

| Component | Monthly | Notes |
|---|---|---|
| 3 × t3.small servers | $29.95 | 1440 billable h, pooled free hours applied |
| 1 × t3.medium worker | $30.37 | 730 h, 0 free-tier hours |
| 4 × 16 GiB gp3 | $2.72 | 30 GiB free |
| ALB + ~2 LCU | $28.11 | decision 2 |
| logs / snapshots / ECR | ≈$6.60 | retained logs have a lifecycle |
| **Total** | **≈$97.74/mo** | **≈$138 of the 43 days left in the window (69% of the $200 credit)** |

Teardown at Phase 14 returns the account to $0. `destroy.yml` exists before the ALB exists.
