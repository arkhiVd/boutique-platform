# boutique-platform — live progress

**Last updated: 2026-10-09 03:10 UTC** · rendered browser view: `docs/progress.html`
(regenerate with `python3 scripts/render-progress.py`)

---

## ▶ Where we are

**Wave A, Phase 2 is built and planned; nothing is provisioned.** Two Terraform stacks exist on
branch `feat/infra-bootstrap-vpc`: `bootstrap/` (state bucket, split OIDC roles, $30 Budget, alert
SNS topic) and `platform/` (VPC, three public subnets in three AZs, IGW, four security groups,
node instance profile, S3 backend with native `use_lockfile` locking). Both plan clean, both scan
clean, and neither has been applied — the apply is Aravind's gate, and the state bucket the
platform stack stores state in does not exist until that one-time bootstrap apply runs.

**What the two plans say, exactly:**

```
terraform -chdir=bootstrap plan      Plan: 14 to add, 0 to change, 0 to destroy.
terraform -chdir=platform  plan      Plan: 42 to add, 0 to change, 0 to destroy.
```

**Cost of Wave A: $0.00.** VPC, IGW, subnets, route table, DHCP options, security groups, IAM
roles, instance profiles, the OIDC provider, the Budget and the SNS topic are all free; the state
bucket holds a state file, not data. The first billable thing in the repo is Phase 3's instances.

**Three decisions from Aravind still unblock the rest.**

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
  - `[x]` `scripts/check.sh` runs and reports pass/fail per tool with real output
  - `[ ]` GitHub repo created and CI checks green on a real PR run
  - `[ ]` Critic blind-compares the scaffold against the phase's exit criteria
- `[x]` **Phase 1 — cost guardrails: state bucket, split OIDC plan/apply roles, $30 Budget, alert topic**
  - built and planned; the one-time local-state apply is the remaining step
- `[x]` **Phase 2 — network + node identity: VPC, 3 public subnets, IGW, 4 SGs, node instance profile**
  - built and planned; no instance, load balancer or NAT gateway is created, so nothing bills

### Wave B — Cluster
- `[ ]` **Phase 3 — k3s HA, 3 AZ, SSM-only** · next; blocked on decisions 1 + the first cost-bearing apply
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
| 1 | built, planned, not applied | pending | the apply itself | 0 |
| 2 | built, planned, not applied | pending | flow logs off for cost; ALB→NodePort rule lands in Phase 5 | 0 |

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

### Wave A — 2026-10-09, from the plans and the scanners, not from an apply

```
terraform -chdir=bootstrap plan -no-color
  Plan: 14 to add, 0 to change, 0 to destroy.
  aws_s3_bucket.tfstate, aws_s3_bucket_lifecycle_configuration.tfstate,
  aws_s3_bucket_public_access_block.tfstate,
  aws_s3_bucket_server_side_encryption_configuration.tfstate,
  aws_s3_bucket_versioning.tfstate, aws_iam_openid_connect_provider.github_actions[0],
  aws_iam_role.plan, aws_iam_role_policy.plan, aws_iam_role.apply, aws_iam_role_policy.apply,
  aws_budgets_budget.monthly, aws_sns_topic.alerts, aws_sns_topic_policy.alerts,
  aws_sns_topic_subscription.alerts_email

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
scripts/check.sh                            PASS: 17  FAIL: 0  MISSING: 0
scripts/cost-estimate.sh                    $97.74/mo for the SPEC shape; Wave A itself adds $0.00
```

Also verified from the account, not from memory:

- `aws iam list-open-id-connect-providers` returned an **empty list**, so `bootstrap/` creates the
  GitHub Actions OIDC provider (guarded by `var.create_oidc_provider` for the day it already exists)
- The TLS thumbprint is read at plan time from
  `https://token.actions.githubusercontent.com/.well-known/openid-configuration` →
  `ab9d0263244dd0326eb67015705a667e79cfe998`
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
| 3 × t3.medium | $91.28 | 0 free-tier hours → full price |
| 3 × 16 GiB gp3 | $1.44 | 30 GiB free |
| ALB + ~2 LCU | $28.11 | decision 2 |
| logs / snapshots / ECR | <$3 | retained logs have a lifecycle |
| **Total** | **≈$124/mo** | **≈$176 over the 43 days left in the plan window** |

Teardown at Phase 14 returns the account to $0. `destroy.yml` exists before the ALB exists.
