# boutique-platform — live progress

**Last updated: 2026-10-09** · rendered browser view: `docs/progress.html`
(regenerate with `python3 scripts/render-progress.py`)

---

## ▶ Where we are

**Phase 3 and 4 are built and planned; nothing is applied.** On `feat/cluster`, the `platform/`
stack now carries the cluster itself — 4 EC2 instances behind 2 launch templates, one KMS CMK,
the k3s join token written write-only into SSM, and cloud-init that installs k3s v1.36.5+k3s1
using nothing but an IMDS token, an instance role, and an AZ to elect a leader. Phase 4 adds the
etcd snapshot bucket and its systemd timer, the RBAC, the PDB/NetworkPolicy/ResourceQuota/
LimitRange baseline, and a restore drill that refuses to touch the live cluster. The apply is still
Aravind's gate, and the state bucket the platform stack stores state in does not exist until that
one-time bootstrap apply runs.

**What the three plans say, exactly:**

```
terraform -chdir=bootstrap plan      Plan: 14 to add, 0 to change, 0 to destroy.
terraform -chdir=platform  plan      Plan: 42 to add, 0 to change, 0 to destroy.   (Phase 2)
terraform -chdir=platform  plan      Plan: 58 to add, 0 to change, 0 to destroy.   (Phase 3+4)
```

**Cost of Waves A-C so far: $0.00 applied.** The first billable thing in the repo is still Phase
3's instances, because the first cost-bearing apply has not been run. Two new cost lines land with
them that the SPEC's table does not yet carry: the CMK at $1.00/month and detailed monitoring at
$0.30 per instance per month (**+$2.20/month, $3.13 over the 43-day window**) — 69% of the $200
credit becomes 71%.

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
  - Launch templates per node role, 3 servers (one per AZ) + 1 t3.medium, **all four schedulable, none tainted**
  - Root volumes encrypted gp3 under a CMK this stack owns; **no `key_name`, no port 22, SSM only**
  - The join token is an **ephemeral variable written into a write-only `value_wo` SecureString**: 0 hits in the plan text, the plan JSON and the saved plan file, and the provider nulls the value on read
  - Cloud-init elects the leader by AZ, reads the token and the leader address from SSM with the instance role, hardens the k3s unit, and installs the etcd snapshot timer on the leader
  - `scripts/bootstrap-cluster.sh` (kubeconfig to `~/.kube/boutique-prod.yaml`, 0600, never inside the repo) and `scripts/doctor.sh` (11 checks, one verdict, exit 1 on any failure)
- `[~]` **Phase 4 — cluster policy baseline (PSA restricted, quota, netpol with DNS carve-out, RBAC, etcd snapshots)** · policy layer written on this branch; cluster-dependent proof pending
  - 4 PDBs for the k3s add-ons, the `boutique` default-deny **with the kube-dns egress carve-out**, `observability` + `ci` quotas and LimitRanges, and `cluster/priority.yaml`
  - RBAC as manifests, not `kubernetes_*` resources: every binding targets a Group, because there is no IdP yet and a group is the only subject that can be bound before it resolves
  - `scripts/etcd-restore-drill.sh`: restores into scratch, times each phase, and **refuses `TARGET=cluster-live` without `LIVE_ACK=yes`**

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

### Waves B — 2026-10-09, from the plan, the scanners and two stubbed runs

```
terraform -chdir=platform plan -no-color
  Plan: 58 to add, 0 to change, 0 to destroy.
  aws_default_security_group.boutique, aws_iam_instance_profile.boutique_node,
  aws_iam_role.boutique_node, aws_iam_role_policy.boutique_node,
  aws_iam_role_policy_attachment.boutique_node_ssm_core,
  aws_instance.k3s_server["us-east-1a"], aws_instance.k3s_server["us-east-1b"],
  aws_instance.k3s_server["us-east-1c"], aws_instance.k3s_worker,
  aws_internet_gateway.boutique, aws_kms_alias.platform, aws_kms_key.platform,
  aws_launch_template.k3s_server, aws_launch_template.k3s_worker,
  aws_route_table.boutique, aws_route_table_association.boutique[3],
  aws_s3_bucket.etcd_snapshots, aws_s3_bucket_lifecycle_configuration.etcd_snapshots,
  aws_s3_bucket_policy.etcd_snapshots,
  aws_s3_bucket_public_access_block.etcd_snapshots,
  aws_s3_bucket_server_side_encryption_configuration.etcd_snapshots,
  aws_s3_bucket_versioning.etcd_snapshots,
  aws_security_group.boutique_edge / boutique_node_admin / boutique_node_api / boutique_node_internal,
  aws_security_group_rule.* (21 rules), aws_ssm_parameter.k3s_channel,
  aws_ssm_parameter.k3s_leader_ip, aws_ssm_parameter.k3s_token,
  aws_subnet.boutique[3], aws_vpc.boutique, aws_vpc_dhcp_options.*,
  aws_vpc_dhcp_options_association.boutique

checkov -d platform     Passed checks: 160, Failed checks: 0, Skipped checks: 4
                         4 skips, each with a written reason on the resource:
                         CKV_AWS_109 (account-root administration of a key policy),
                         CKV_AWS_8 x2 (volume encryption declared on the launch template),
                         CKV_AWS_18 (access logging needs a second bucket)
                         + CKV2_AWS_11 (VPC flow logs, Phase 2)
                         plus CKV_AWS_144/CKV2_AWS_62 in the stack's .checkov.yaml
terraform fmt -check -recursive            clean, both stacks
tflint --recursive                          clean
shellcheck -x + bash -n                     clean on the 4 new scripts and the 2 node scripts
kubeconform -strict -kubernetes-version 1.36.3 cluster/policies/
                                          Summary: 9 resources found - Valid: 9, Invalid: 0, Errors: 0
conftest test cluster/policies/ -p policy/  198 tests, 198 passed, 0 warnings, 0 failures
gitleaks detect --no-git                    no leaks found
scripts/check.sh                            PASS: 103  FAIL: 0  MISSING: 0
```

Also verified from the tooling, not from memory:

- **The join token is nowhere.** `terraform plan -out=tfplan`, then
  `terraform show -json tfplan | grep -c <the-token>` → **0**, and `grep -c <the-token> tfplan` → **0**.
  Terraform itself refuses to write an ephemeral value into a normal attribute, and the AWS
  provider's read path nulls `value` when `has_value_wo` is set.
- **k3s does not taint its server nodes** (docs.k3s.io/advanced; the label is set, the taint is
  not) — which is what makes the SPEC's scheduling model hold on 4 nodes instead of 1.
- **The kubelet's read-only port is off by k3s's own construction**:
  `pkg/daemons/agent/agent_linux.go` builds `argsMap["read-only-port"] = "0"` with a comment
  explaining that the structured config drops a zero.
- **The systemd watchdog must NOT be set**: k3s unsets `NOTIFY_SOCKET` right after `READY=1`, so
  the kubelet cannot feed it and systemd kills the service at the timeout (k3s-io/k3s#13725).
- **k3s's S3 snapshot credentials fall through to the instance role** — the chain in
  `pkg/etcd/s3/s3.go` is Static → FileAWSCredentials → IAM — so the snapshot timer needs no key pair.
- **Amazon Linux 2023 with kernel 6.12 is the current default AMI**, read from SSM at plan time,
  and the k3s install script handles it explicitly (container-selinux + the k3s-selinux policy).
- Two negative tests, run and recorded: `scripts/doctor.sh` against a stubbed cluster reports
  **PASS 8 / WARN 2 / FAIL 0, exit 0**, and against a broken kubeconfig reports
  **PASS 1 / WARN 3 / FAIL 6, exit 1** — which is also how the one real bug found in this phase
  was caught (an AZS array assignment that made every node look absent). The restore drill's two
  guard rails were exercised the same way.

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
| 4 × 16 GiB gp3 | $2.72 | 30 GiB free, CMK instead of the managed key |
| ALB + ~2 LCU | $28.11 | decision 2 |
| logs / snapshots / ECR | ≈$6.60 | retained logs have a lifecycle |
| **Subtotal (the SPEC table)** | **≈$97.74/mo** | **≈$138.26 over the 43 days left (69% of the $200 credit)** |
| 1 × KMS CMK | $1.00 | **a line the SPEC table does not carry** — one key for EBS and the token |
| detailed monitoring | $1.20 | $0.30 × 4 nodes, **also new** — the t3 sustained-CPU risk is otherwise unobservable |
| **Total as built** | **≈$99.94/mo** | **≈$141.39 over the window (71% of the $200 credit)** |

Teardown at Phase 14 returns the account to $0. `destroy.yml` exists before the ALB exists.
