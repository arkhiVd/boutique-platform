# boutique-platform — live progress

**Last updated: 2026-10-18** · rendered browser view: `docs/progress.html`
(regenerate with `python3 scripts/render-progress.py`)

---

## 2026-10-18 — Phase 14: release gate passed; teardown awaits its approval

| gate (ROADMAP Phase 14) | state |
|---|---|
| CI green on the latest commit | yes: secret scan + terraform plan, on PRs #3, #4, #5 and `main` |
| the CI plan is empty after apply | yes: "No changes" (it needed the imported certificate ARN, PR #5) |
| security scans clean | gitleaks clean; Dependabot alerts enabled, 0 open |
| Dependabot current | Actions bumps merged (#2, every SHA checked against its tag); Terraform roots now watched |
| SPEC/ROADMAP/TASKS/README match what was built | SPEC shape and cost, README status and teardown, TASKS current phase: updated |
| real-environment test documented | `docs/evidence/` (index: `docs/evidence/README.md`) |
| rollback path known | `docs/runbooks/rollback.md`, checked live |
| teardown path tested | `scripts/teardown.sh` inventory run; bucket emptying tested on a scratch versioned bucket |
| teardown executed, $0 the following week | **not yet**: ROADMAP approval gate 3 |

Found and fixed on the way: five orphaned EBS volumes (31 GiB, from the 2026-10-14
cluster) that a `terraform destroy` would never have removed, and `cost-estimate.sh`
reporting the cluster as 6 GiB instead of 10.

## 2026-10-17/18 — Phase 13: drills that found five live faults (`feat/phase-13-operations`)

Phase 13's drills were run against the live cluster, and each one broke something
real. Everything below was fixed on the cluster, written into the repo so a new
node or a reinstall comes up the same way, and re-measured.

| drill | what it found | fix | after |
|---|---|---|---|
| drain the agent (`docs/evidence/phase-13/drain.txt`) | the leader's k3s **exited**: etcd writes slowed to 1.5s, the controller-manager missed its 5s lease, and `leaderelection lost` is fatal in k3s (4th such restart) | leases 60s/40s on every server (`config.yaml.d/50-leader-election.yaml`) | rolling restart, leases verified at 60s |
| the same drain | pods never moved back; a 2 GB etcd follower reached **36 MiB available**, its kubelet and SSM agent went silent, the cluster ran on two etcd members | kubelet memory reservations + eviction at 200Mi on every node; Prometheus prefers the agent | follower rebooted (2.5 min), allocatable now honest |
| etcd restore into a local k3s (`scripts/etcd-restore-local.sh`) | "bootstrap data encrypted with **different token**": every node had joined with the token's **KMS ciphertext** (bootstrap read the SecureString without `--with-decryption`), so the CMK protected nothing | `k3s token rotate` to the decrypted value, rolled to all four nodes; bootstrap decrypts | restore serves the shop: 21/21 pods, home + product 200, **555 s** |
| runbook commands, executed (`scripts/check-runbooks.py`) | a wrong Terraform output, a dead kubeconfig, an undeployed backup CronJob, cluster-DNS URLs, placeholders, and **no gp3 volume could ever be resized** | runbooks fixed; `allowVolumeExpansion: true` | 12/12 runbooks pass live |
| evidence capture (`scripts/evidence-capture.sh`) | **Grafana's host route answered 404** (IngressRoute named a Service that never existed); the leader thrashed (I/O stall 25%, load 4.6) because Jenkins and Grafana under-requested memory and the scheduler kept packing the node they are pinned to | backend name fixed; requests set to measured working sets | leader: 892 MiB available, load 0.9, I/O stall 0.7% |

Smaller: Fluent Bit's readiness probe stayed failed for 90 minutes after Loki
recovered and pulled its own metrics out of Prometheus (readiness now `/`);
`doctor.sh` passed with pods at 0/1 (it now fails on unready containers) and gained
an edge check through the ALB. redis-cart's single-replica PDB blocks a drain by
design; `node-loss.md` now handles it explicitly.

**Correction to "The join token is nowhere" (Wave B, below):** the token was in
neither state nor git, but until 2026-10-17T20:23Z every node used the
parameter's ciphertext as the token. Snapshots older than that restore only with
the ciphertext (`docs/runbooks/etcd-restore.md`).

```
scripts/doctor.sh          PASS 9 / WARN 4 / FAIL 0
scripts/check.sh           PASS 154 / FAIL 0 / MISSING 0
scripts/check-runbooks.py  12 runbooks, live
terraform plan             bootstrap and platform: no changes
```

What is still **not** proven is listed per criterion in `docs/evidence/README.md`:
the pipeline runs (Phase 7–8), the SLO fault-injection tests (Phase 12), the
zero-loss drain (Phase 6), and a 403 from the Web ACL, which is deliberately in
count mode.

## 2026-10-17 — alerting told the truth for the first time (`fix/alerting-truth`)

A live audit found the platform looked healthy only because it could not see or say otherwise.
Every item below was measured on the cluster, fixed in the repo, applied, and re-measured.

| found (measured) | fix | after |
|---|---|---|
| Alertmanager → SNS: **403 on every notification since deploy** (node role had no `sns:Publish`; the `-page`/`-ticket` topics never existed) | both receivers → `boutique-platform-alerts`; `AlertPublish` statement on the node role | 403s stop; `alertmanager_notifications_total{integration="sns"}` moves |
| next failure: SNS **400 `Invalid parameter: Subject`** (stock subject appends every label) | short `boutique.sns.subject` template; labels, summary, runbook in the body | delivery succeeds |
| apiserver + kubelet targets **DOWN**: ~36k samples vs a 10k limit (k3s serves the whole registry from one process, twice) | sampleLimit 20000 + drops of duplicated families | all up |
| Prometheus self-scrape **DOWN**: `rule_group` label 241 chars vs a 200 limit | per-monitor `labelValueLengthLimit: 512` | up |
| **3 critical false positives**: KubeScheduler/ControllerManager/Proxy Down (not separate on k3s) | monitors and their rules disabled | gone |
| spanmetrics **dark**: wrong metric name (`traces_span_metrics_*`), NetworkPolicy blocked :9464, ServiceMonitor never applied | rename in rules/dashboards/runbooks, netpol rule, apply | series present, `TracesSpanmetricsMissing` resolved |
| 5 ServiceMonitors **never applied** (otel collector, loki, fluent-bit, blackbox, jenkins) | applied | scraped |
| fluent-bit **404** on `/metrics` | path `/api/v2/metrics/prometheus` | 4/4 up |
| HPA ceilings needed **6470m** CPU vs a **3000m** quota — most HPAs could never scale | ceilings sized to an N-1 budget, quota 3600m; Rego rule `deny_hpa_ceiling_exceeds_quota` + fixture | 99% of quota at max, gate enforced |
| `doctor.sh` passed while Prometheus was blind | fails on any DOWN target or firing page/critical | honest verdict |

```
scripts/doctor.sh   PASS 8 / WARN 4 / FAIL 0   (40 active targets, all up; no page/critical firing)
scripts/check.sh    PASS 149 / FAIL 0 / MISSING 0
```

**Alert delivery closed the same day:** the bootstrap `alert_email` had been a GitHub noreply
address that could never confirm, so the topic had 0 subscribers. It now points at a real inbox
(local tfvars only), `terraform -chdir=bootstrap apply` added the subscription, the inbox confirmed
it, and both a direct SNS publish and an `amtool`-injected alert went out with no new
`alertmanager_notifications_failed_total`. Known warnings:
memory limits overcommitted 121–188% per node (`KubeMemoryOvercommit`), four single-replica PDBs
block a drain, launch-template AMI drift on a full platform plan, CI's plan-only token default is
under the 32-character minimum.

## ▶ Where we are

**Everything below the approval gates is built, merged to `main` — and since 2026-10-14, applied.**
Both stacks are live in `us-east-1`. Waves C, D and E are now **deployed and verified live**
(`scripts/doctor.sh`: **PASS 9 / WARN 1 / FAIL 0**) as of 2026-10-15; the numbers below were re-run
that day against this commit, not carried forward from an earlier one.

What is applied and at what stage:

| phase | state | what it means |
|---|---|---|
| 0 guardrails | merged, green | SPEC / ROADMAP / TASKS / ADRs / `scripts/check.sh` |
| 1–2 network, IAM, VPC | **applied** | state bucket, VPC, subnets, security groups; bootstrap's 14 resources are live |
| 3–4 cluster | **applied** | 1 × c7i-flex.large (leader) + 3 × t3.small running, k3s v1.36.5+k3s1, etcd snapshots, RBAC, restore drill |
| 5 edge | **applied** | ALB active and logging to S3, count-mode Web ACL logging to CloudWatch, Traefik targets attached |
| 6 metrics and logs | **applied, verified live** | kube-prometheus-stack, Grafana, Loki, Fluent Bit, Promtail→Fluent Bit trail, golden-signal dashboards |
| 7–8 CI/CD | **applied, verified live** | Jenkins controller `ci` 2/2 Running (0 failed plugin loads, 0 JCasC errors, `/login` 200), pods scheduled, shared library ready |
| 11 traces | **applied** | Tempo up, spanmetrics wired, OTel collector gateway shipping traces |

**The gate reads 145 PASS / 0 FAIL / 0 MISSING** as of this working tree.

```
terraform -chdir=bootstrap plan      0 resource changes (one output normalises "30" -> "30.0")
terraform -chdir=platform  plan      No changes. Your infrastructure matches the configuration.
```

Both stacks reach a clean plan; the bootstrap line is an output-only refresh against AWS's
`limit_amount` formatting, not a resource diff.

**Billing started on 2026-10-14.** The current cost line, recomputed by `scripts/cost-estimate.sh`
(priced 2026-10-15) for the shape that is actually running:

```
committed total   $129.27/month   $182.85 over 43 days (guarded)  -> 91% of the $200 credit
incl. worst case  $211.40/month   $299.02 over 43 days            -> OVER the credit
exit 0 (guarded figure under the credit; the worst case is a modelled t3 CPU-credit risk)
```

Two cost lines land with the instances that the SPEC's table does not yet carry: the CMK at
$1.00/month and detailed monitoring at $0.30 per instance per month (**+$2.20/month, $3.13 over
the 43-day window**). The earlier `$82.56/month` line was the 4 × t3.small shape measured on
2026-10-14; the leader's move to c7i-flex.large is what puts ~$47/month on top of it.

**The node shape changed twice, and both reasons are measured, not aesthetic.** The spec's
3 × t3.small + 1 × t3.medium cannot launch in this account: `RunInstances` rejects t3.medium with
`InvalidParameterCombination: The specified instance type is not eligible for Free Tier`, and
`describe-instance-types --filters free-tier-eligible=true` confirms t3.medium and `t2.*` are
ineligible while t3.small, t4g.small, `c7i-flex.large` and `m7i-flex.large` are. The first
deployed shape was therefore **four equal t3.small** ($15.18/month cheaper than the blocked one).
On 2026-10-15 the cluster was **resized to the approved 1-large + 3-small shape**: the leader —
the bootstrap node, the `--cluster-init` etcd member and the node observed wedging under load —
kept `c7i-flex.large`, while the two followers went to `t3.small` (user-approved; applied one node
at a time so an etcd quorum of three was never lost, then confirmed with a clean
`terraform plan`). vCPU is unchanged at exactly 8 of the 8 quota; RAM is now 6 GiB advertised
(4 GiB on the leader, 2 GiB on each follower and the worker). `scripts/cost-estimate.sh` carries
both prices (`P_C7I_FLEX_LARGE=0.08479`, verified via pricing `GetProducts` on 2026-10-15) and
defaults `SHAPE=1xc7i-flex.large+3xt3.small`, so its worst-case t3 CPU-credit model now
overstates the risk: c7i-flex is not burstable and accrues no surcharge.

**The headline number, stated plainly because it is the one that matters:**
the platform **does not fit** on one node. `docs/resource-budget.md` holds the arithmetic —
**3850m / 4688Mi of requests against 1830m / 3741Mi schedulable = 210.4% CPU and 125.3% RAM**, of
which **2820m is the `boutique` namespace's own request**, not the observability stack (Phase 11
added Tempo at 250m/512Mi and the collector's 128Mi → 192Mi per replica; before it the numbers
were 3600m / 4048Mi = 196.7% / 108.2%). The fix is
architectural: **all four nodes are schedulable**, the k3s servers carry no control-plane taint,
because with a hard 8-vCPU quota there is no separate worker fleet to pair a control plane with
(kubeadm control-plane nodes are schedulable by default; EKS taints them). On the deployed
shape that is **7320m / ~6960Mi schedulable — 53% CPU and 67% RAM**, roughly half the cluster
free on both axes. The single-node arithmetic stays in the repo deliberately: it is the
regression bound the gate enforces, not a description of what is deployed.

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
| 0 | **Node shape (re-resolved by the apply).** Decided as 3 × t3.small servers + 1 × t3.medium; deployed as **4 × t3.small**, all four schedulable, because the account rejects t3.medium at the API. | Phase 3 | $0 — 8 vCPU exactly at quota, and $15.18/mo cheaper than the shape that could not launch |
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
- `[x]` **Phase 3 — k3s HA, 3 AZ, SSM-only** · applied and verified; resized to the approved 1-large + 3-small shape on 2026-10-15
  - Launch templates per node role, 3 servers (one per AZ) + 1 worker, **all four schedulable, none tainted**; the servers are `object({leader = "c7i-flex.large", followers = "t3.small"})` — the leader keeps the large shape as the etcd anchor, the two followers were resized one node at a time on 2026-10-15 with quorum held (see the apply findings below)
  - Root volumes encrypted gp3 under a CMK this stack owns; **no `key_name`, no port 22, SSM only**
  - The join token is an **ephemeral variable written into a write-only `value_wo` SecureString**: 0 hits in the plan text, the plan JSON and the saved plan file, and the provider nulls the value on read
  - Cloud-init elects the leader by AZ, reads the token and the leader address from SSM with the instance role, hardens the k3s unit, and installs the etcd snapshot timer on the leader
  - `scripts/bootstrap-cluster.sh` (kubeconfig to `~/.kube/boutique-prod.yaml`, 0600, never inside the repo) and `scripts/doctor.sh` (11 checks, one verdict, exit 1 on any failure)
- `[~]` **Phase 4 — cluster policy baseline (PSA restricted, quota, netpol with DNS carve-out, RBAC, etcd snapshots)** · policy layer written on this branch; cluster-dependent proof pending
  - 4 PDBs for the k3s add-ons, the `boutique` default-deny **with the kube-dns egress carve-out**, `observability` + `ci` quotas and LimitRanges, and `cluster/priority.yaml`
  - RBAC as manifests, not `kubernetes_*` resources: every binding targets a Group, because there is no IdP yet and a group is the only subject that can be bound before it resolves
  - `scripts/etcd-restore-drill.sh`: restores into scratch, times each phase, and **refuses `TARGET=cluster-live` without `LIVE_ACK=yes`**

### Wave C — Edge and workload
- `[x]` **Phase 5 — two-layer edge: ALB + WAF + TLS + access logs + Traefik** · applied and verified
- `[x]` **Phase 6 — Boutique production-grade (PDB, HPA, topology spread, netpol, OTel, chaos)** · deployed and verified live on 2026-10-15

### Wave D — CI/CD
- `[x]` **Phase 7 — Jenkins controller + ephemeral Kubernetes agents (JCasC)** · wrapper chart, namespace-scoped RBAC and daily backup merged; **the controller boots verified on 2026-10-15** (2/2 Running, 0 failed plugin loads, 0 JCasC errors, `/login` 200) — the six failures that got in the way are all documented in `ci/jenkins/values.yaml`
- `[~]` **Phase 8 — pipeline library: scan, sign, deploy, canary, auto-rollback** · 9 shared-library steps plus the root Jenkinsfile, all twelve gates run locally in their pinned containers; no pipeline has executed on the cluster yet (awaiting a first real build)

### Wave E — Observability
- `[x]` **Phase 9 — Prometheus / Grafana / Alertmanager + golden signals** · deployed and verified live on 2026-10-15 (8/8 pods Running, scrapes active)
- `[x]` **Phase 10 — Loki + Fluent Bit logs with bounded cardinality** · deployed and verified live on 2026-10-15 (log line volumes confirmed flowing)
- `[x]` **Phase 11 — OTel Collector gateway + Tempo** · deployed and verified live on 2026-10-15 (collector gateway + single-binary Tempo on gp3)
- `[~]` **Phase 12 — SLOs, error budget, multiwindow multi-burn-rate alerts** · built and validated; alert rules live, not yet fired on purpose

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
- Quota: **8.0 vCPU** running on-demand standard instances → the deployed 4 nodes sit exactly at it (1 × c7i-flex.large leader + 3 × t3.small); a fifth node cannot launch without a quota increase
- Free-tier eligibility is enforced **by the API, not by the console** (`RunInstances` fails with
  `InvalidParameterCombination`). Eligible in `us-east-1`: **t3.small**, t4g.small, t3.micro,
  t4g.micro, t8i.micro, t8i.small, c7i-flex.large, m7i-flex.large. **Not** eligible: **t3.medium**
  (4.0 GiB), `t2.*`. Sizes: t3.micro 1.0 GiB, t3.small 2.0 GiB, t3.medium 4.0 GiB (unusable)
- NLB blocked account-wide (`network-load-balancer-capacity-units = 0`); **ALB works**
- Route 53 zones: 0. ACM certs: 0. NAT gateways: 0. EKS clusters: 0.
- Cost since account creation: **$0.00 until 2026-10-14**, when the first apply started billing
- Online Boutique `v0.10.7` HEAD released 2026-09-18
- Verified absent from upstream `v0.10.7` (so ours must add them): PodDisruptionBudget, HPA,
  topology spread, anti-affinity, priority classes, ResourceQuota/LimitRange, deployment
  `strategy`, egress DNS carve-out, private nodes, SLOs, any metrics instrumentation. Upstream's
  OTel collector ships **no processors at all**. Upstream `adservice` tracing is commented out.
- Verified absent and **not** to be built: `adServiceFailure`, `recommendationCacheFailure`
  (checked across v0.1.4–v0.10.7), `ml-pipeline/`, Cloud CDN, Argo CD / Config Sync descriptors
- k3s stable channel resolves to **v1.36.5+k3s1** (`curl -s https://update.k3s.io/v1-release/channels/stable`)

### 2026-10-15 — waves C, D and E verified live, and the resize to 1-large + 3-small

The cluster was rebuilt on `c7i-flex.large` servers (t3.medium still rejected), then resized to
the shape the user approved — the leader keeps `c7i-flex.large`, the two followers go back to
`t3.small`. The resize was applied one node at a time so the etcd quorum of three was never
lost, and closed with a clean `terraform plan`:

```
$ terraform apply -auto-approve -target=aws_launch_template.k3s_server \
      -target='aws_instance.k3s_server["us-east-1b"]'     # follower → t3.small, then wait Ready
$ terraform apply -auto-approve -target='aws_instance.k3s_server["us-east-1c"]'  # second follower
$ terraform plan                                             # No changes. Your infrastructure matches the configuration.
```

Watch item: follower 1b wedged once after the resize — memory 1.68/1.9 GiB used and load 11 on
2 vCPU while still hosting the pre-resize pod set (Loki-0 is AZ-pinned to us-east-1b). Kubelet
stopped heartbeating, the node took `node.kubernetes.io/unreachable` taints and pods hung
Terminating. It recovered with `aws ec2 reboot-instances --instance-ids i-043323974c30b6b52`;
memory then settled at 59%. `scripts/doctor.sh` currently reports the followers at 83% / 59% RAM
— the 2 GiB followers are the tightest constraint left and the reason a 5th pod on 1c should be
watched.

Waves C, D and E were then deployed by one scripted entry point, `scripts/deploy-workloads.sh`
(namespaces → policies → Traefik → Boutique → EBS CSI → Grafana secret → Jenkins secrets →
kube-prometheus-stack → Loki → Fluent Bit → Tempo → blackbox → Jenkins RBAC + chart → rollout
waits → verdict), and verified:

```
$ ./scripts/doctor.sh
  VERDICT: PASS -- 9 checks green, 1 warning(s), cluster healthy
  (warning: 4 PDBs allow no voluntary disruption — single-replica components by design)

$ ./scripts/check.sh
  PASS: 145   FAIL: 0   MISSING: 0
```

The Jenkins controller's first boot took six fixes, each with the measured evidence recorded in
`ci/jenkins/values.yaml`: the namespace ServiceAccount was never applied (`ci/rbac/`); two
Secrets the chart projects were missing (`scripts/create-jenkins-secrets.sh`, with the chart's
own key names `jenkins-admin-user`/`jenkins-admin-password`); both the init and the k8s-sidecar
containers were OOMKilled at 512Mi / 64Mi (now 1Gi / 256Mi); the plugins failed on a two-round
dependency ladder, pinned with the exact versions Jenkins named; and the JCasC credentials block
used `domain:` where this version wants the `domainCredentials:` list. The standalone PVC is the
chart's `home-pvc.yaml`, not a volumeClaimTemplate — deleting it by hand needs another
`helm upgrade` to recreate.

The cost ledger was re-priced for the live shape (`$0.08479/hr` for c7i-flex.large, verified via
pricing `GetProducts` on 2026-10-15): committed **$129.27/month / $182.85 over the 43-day window**,
91% of the $200 credit, gate exit 0.

The operator's ISP address rotates (three in 48 hours), which locked `kubectl` out of 6443 while
the cluster kept reporting itself healthy. `scripts/update-admin-cidr.sh` now reconciles it: it
resolves the egress address, **imports an already-present out-of-band rule into Terraform state**
(the first version instead tried to create a duplicate and failed with
`InvalidPermission.Duplicate`, leaving the stack half-swapped — state pointing at a destroyed
rule), writes it to the gitignored tfvars, applies the one rule resource, revokes any leftover
6443 /32, and proves the API server still answers. It is idempotent and safe on a timer; the
in-sync check now requires tfvars, state and AWS to agree, because a stale tfvars line alone is a
latent lockout on the next full `terraform apply` anywhere. Live state after the run: **tfvars,
state and AWS all say `149.88.103.57/32`**, and `terraform plan` is clean.

### The first apply — 2026-10-14, live account, three runs to green

The apply is the test harness, and it found four things the plan could not. Each was fixed,
re-applied, and re-verified rather than reasoned about.

```
$ terraform -chdir=platform apply   run 1 (partial)
  aws_instance.k3s_server[us-east-1a]   created   i-0d1515227f91d7ac5
  aws_instance.k3s_worker               FAILED    InvalidParameterCombination:
                                                  The specified instance type is not eligible for Free Tier
  aws_lb.edge                           FAILED    InvalidConfigurationRequest:
                                                  Access Denied for bucket
  aws_wafv2_web_acl_logging_configuration.edge  FAILED  WAFInvalidParameterException: ARN isn't valid
```

**Finding 1 — the account enforces free-tier instance types at the API.** Not a console filter:

```
$ aws ec2 run-instances --instance-type t3.medium ...
  InvalidParameterCombination: The specified instance type is not eligible for Free Tier.
$ aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
      --query 'sort_by(InstanceTypes,&InstanceType)[].InstanceType' --output text
  t8i.micro  c7i-flex.large  t4g.small  t3.micro  t4g.micro  t3.small  m7i-flex.large  t8i.small
```

**Finding 2 — ALB access logs support SSE-S3 only.** The bucket was SSE-KMS. AWS documents that
"the only server-side encryption option that's supported is Amazon S3-managed keys (SSE-S3)" and
lists an unsupported encryption option as a direct cause of `Access Denied for bucket`.

**Finding 3 — ALB access logs need ACLs enabled.** The same bucket defaulted to
`BucketOwnerEnforced`, which rejects the `x-amz-acl: bucket-owner-full-control` header the ELB
log delivery service writes with. Both log buckets are `BucketOwnerPreferred` now, public ACLs
still blocked by the existing public access block.

**Finding 4 — a WAF log group name must start with `aws-waf-logs-`.** The error ("ARN isn't
valid") does not say so; the CloudWatch Logs `create-log-group` call does, and the KMS key needed
a scoped `CloudWatchLogsEncryptsTheWafLogGroup` statement before that call would succeed.

All four are in commit `98d9542` with the measurements in the message. Verification, not a report:

```
$ aws s3 ls s3://boutique-platform-alb-logs-.../AWSLogs/348032171026/
2026-10-14 11:14:55         97 ELBAccessLogTestFile          <- ELB wrote its own test object

$ aws wafv2 get-logging-configuration --resource-arn ...:webacl/boutique-platform-edge/...
  LogDestinationConfigs: [ ...log-group:aws-waf-logs-boutique-platform-edge:*]

$ aws ec2 describe-instances --filters Name=instance-state-name,Values=running
  i-00c9e8290e8bb8e53  t3.small     i-0ece0618a4e58171d  t3.small
  i-0d1515227f91d7ac5  t3.small     i-07293ba5b41972420  t3.small

$ terraform -chdir=platform plan   ->  No changes. Your infrastructure matches the configuration.
$ ./scripts/check.sh              ->  PASS: 136   FAIL: 0   MISSING: 0
$ checkov -d ./platform           ->  Passed 224, Failed 0, Skipped 8
```

What this does **not** prove: no pod has ever run on these nodes. k3s itself, the app, and every
chart are still un-deployed; the four checkov skips added here are named platform constraints, not
waivers for a component nobody has exercised.

### Waves D — 2026-10-14, the edge answered, and the address under it moved

Traefik was installed and every ALB target read `Target.Timeout`. Six defects, every one of them
found by measuring the live path rather than re-reading the plan, and every one fixed in source.

**D1 — the NodePort security-group rules were written backwards.** Both rules sat on
`boutique_edge` *sourced from* `boutique_node_internal`, which is a rule permitting the nodes to
reach the ALB on 32080/32443: a path nothing uses. The ALB's own forwards and health checks
originate from the edge group, and they were refused. An ingress rule belongs to the group that
receives the packet. Measured after the fix, on the receiving group:

```
$ aws ec2 describe-security-group-rules --filters Name=group-id,Values=sg-010db8487b424e326
  32080  32080  tcp  sg-0740958ab70774ffc     <- the ALB
  32081  32081  tcp  sg-0740958ab70774ffc
  32443  32443  tcp  sg-0740958ab70774ffc
```

**D2 — the same group's egress was 443 and DNS only.** Direction on the node is half of a
handshake. `boutique_edge` allowed outbound 443 to the world and 53 to the resolver, and nothing
to the nodes, so the ALB's health checks were dropped at the source no matter what the node
answered. Three egress rules, one per port, rather than a `32080-32443` range that would become
implicit permission for every future NodePort.

**D3 — the health check asked a question the entrypoint cannot answer with 200.** It probed
`GET http://<node>:32080/ping` expecting 200. Port 32080 is Traefik's `web` entrypoint, and that
entrypoint answers *every* request with its own redirect:

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:32080/ping
301
$ curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:32443/ping
404      # Traefik's ping lives on the `traefik` entrypoint, which the Service did not expose
```

Traefik's own `--ping` handler is on the `traefik` entrypoint (`:8080`), which nothing exposed.
Rather than relaxing the matcher to `301` -- which would assert only "something is listening" --
that entrypoint is now published as NodePort 32081 and both target groups health-check
`http://<node>:32081/ping` for 200. The chart warns in as many words that this port should not be
exposed on a production deployment, because it hosts `/dashboard/` and `/api`; `api.dashboard` is
set to `false`, so the exposed entrypoint answers exactly one path. No document in this repo reads
the Traefik dashboard -- the dashboards story is Grafana's.

```
$ kubectl get svc traefik -n traefik -o jsonpath='{range .spec.ports[*]}{.name}:node{.nodePort}{" "}{end}'
traefik:node32081 web:node32080 websecure:node32443
$ aws elbv2 describe-target-health --target-group-arn ...tf-https
  i-04d2feb020ccb3d6a  healthy    i-081186d2cd5668fe2  healthy
  i-08dbd7c33ed1deea5  healthy    i-015ea1031b2a671a7  healthy
```

Two smaller chart defects went with it: `frontendHost`/`grafanaHost`/`jenkinsHost` were read by
`templates/routes.yaml` but never defined, rendering `Host(``)`; and Traefik was a DaemonSet
asking for one RWO `local-path` PVC, which pinned three of four pods `Pending` with
`didn't find available persistent volumes to bind`. `persistence.enabled: false` sends the chart
back to `emptyDir` on `/data`, which is correct for a proxy that holds no state worth a volume.
The Service was `<pending>` the whole time because it was still `LoadBalancer`.

**D4 — a plan that wanted to replace all four nodes over a comment.** `launch_template.version`
is Optional+Computed: config says `$Latest`, AWS returns the resolved number, so state holds
`"6"`. Every plan after that showed `version = "6" -> "$Latest" # forces replacement`. An
instance's launch-template version cannot be changed after launch, so the change can only ever
take effect at boot; it is now ignored, and a bootstrap edit propagates the way
`platform/README.md` already says it does -- an explicit `terraform apply -replace`.

**D5 — the address the API was reachable on moved underneath it.** Applying the `user_data` fix
in Wave C did not edit files on a running node; it stopped, modified and started all four:

```
$ aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=StopInstances
  2026-10-14T17:36:57+05:30   StopInstances
$ aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=StartInstances
  2026-10-14T17:37:19+05:30   StartInstances
```

A public IPv4 released on stop is a different address after start, and k3s came back under the
unit cloud-init had already written, so `--tls-san` still named the address that had just been
released. The serving cert and `~/.kube/boutique-prod.yaml` went stale together, while the ALB --
which targets private IPs, which never moved -- reported every target healthy. That asymmetry is
the whole reason this was not caught by the health check: the platform's two views of "working"
had diverged.

Fixed twice over. Four Elastic IPs, attached to running instances, so the address stops rotating
at all ($0.005/h only for an *unattached* address; these never are). And the kubeconfig rewrite
now sets `tls-server-name: localhost`:

```
$ kubectl get nodes
  boutique-agent-i-015ea1031b2a671a7      Ready    <none>
  boutique-follower-i-04d2feb020ccb3d6a   Ready    control-plane,etcd
  boutique-follower-i-081186d2cd5668fe2   Ready    control-plane,etcd
  boutique-leader-i-08dbd7c33ed1deea5     Ready    control-plane,etcd
```

`k3s` always puts `DNS:localhost` in the dynamic serving cert, so verifying the name against
`localhost` rather than against the transport address makes the file immune to address rotation
without weakening anything: the cluster CA in the same file is what says "this is my cluster".

**D6 — a PodDisruptionBudget in a namespace that does not exist to it.** The Traefik PDB lived in
`kube-system` while the Helm release installs into `traefik`. A PDB only ever selects pods in its
own namespace, so this one reported `expectedPods: 0` and protected nothing. `scripts/doctor.sh`
failed `disruption` on it, which is the check earning its keep:

```
$ kubectl get pdb -A
  kube-system/coredns                  1  N/A  0
  kube-system/local-path-provisioner   1  N/A  0
  kube-system/metrics-server           1  N/A  0
  traefik/traefik                      1  N/A  3
$ ./scripts/doctor.sh
  PASS: 9   WARN: 1   FAIL: 0
  VERDICT: PASS -- 9 checks green, 1 warning(s), cluster healthy
$ ./scripts/check.sh
  PASS: 136   FAIL: 0   MISSING: 0
```

The single warning is the three single-replica k3s addons with `disruptionsAllowed=0`, which
`cluster/policies/policies.yaml` documents as the intended visible reminder rather than a defect
to hide.

Not proven yet: nothing has been served through the ALB to a browser. The IngressRoute matches
`Host(`boutique.local`)` and the app behind it does not exist, so the edge currently answers 301
on port 80 and 404 on 443, which is Traefik working with nothing to route to.

### Waves C — 2026-10-14, the cluster formed, and what stopped it

The instance replacement in Wave A brought four nodes up, and none of them joined each other.
Five defects, each found by reading the node rather than the plan, and each fixed in source:

**C1 — node egress only allowed DNS and HTTPS.** The ingress rule for 6443 from the admin CIDR
was present and correct; the internal security group's *egress* was 53 and 443, so the follower
could reach SSM and GitHub but never the leader. `Get "https://10.90.12.149:6443/cacerts":
context deadline exceeded`, 483 restarts deep, while `describe-security-group-rules` showed no
rule for 6443 at all. A handshake needs both halves. Scoped egress to the group itself rather
than to `10.90.0.0/16`, so "node to node" still means exactly the group's name.

**C2 — the leader never got `--cluster-init`.** k3s therefore fell back to kine, and
`/var/lib/rancher/k3s/server/` held `kine.sock` and `db/state.db` with no `db/etcd/` directory
at all. The second server refused to join with `failed to bootstrap cluster data: etcd
disabled`, SPEC.md:267 ("three k3s servers form an etcd quorum") was unmeetable, and the
Phase 4 snapshot timer was pointed at a datastore that was not etcd.

**C3 — launch template versions are never promoted to default.** The instances are pinned to
`version = "$Default"`, and AWS reports `LatestVersionNumber=3 / DefaultVersionNumber=1`.
`-replace` therefore booted the *original* 464-line user_data while the template held the fixed
one, which is why C2 survived its own fix. Pinned to `$Latest`.

**C4 — a readable stale leader address is worse than an absent one.** `ssm_wait` returned as
soon as the parameter existed, and on a replace it still held the *previous* leader. Both
followers built `--server https://10.90.12.149:6443` while the live leader was already at
`10.90.0.50`. `leader_wait` now re-reads the parameter until an address answers `/cacerts`,
which covers a stale value and a leader whose apiserver has not started yet.

**C5 — two labels the operator and the scheduler both need were missing.** The apiserver
certificate carried no SAN for the public address `bootstrap-cluster.sh` points the kubeconfig
at (`x509: certificate is valid for 10.43.0.1, 10.90.x.x, 127.0.0.1, ::1, not 100.61.37.125`),
and no node carried `topology.kubernetes.io/zone` — k3s stamps `providerID: k3s://<hostname>`,
so nothing ever resolves it to an AZ. Every `topologySpreadConstraints` in `apps/boutique/base`
keys on that label, so the AZ spread was silently a no-op. Both now come from IMDS at boot.

Separately, `scripts/bootstrap-cluster.sh` and `scripts/doctor.sh` called `aws ssm
get-invocation`, which does not exist (it is `get-command-invocation`), and asked for
`--query 'Command.Id'` when the field is `CommandId` — so every `send-command` captured the
string `None`. `doctor.sh` also built `host:6443:6443`. All three scripts were unrunnable
before this wave.

Commits `8c968a7` and `eb8b16d`. Verification, not a report:

```
$ kubectl get nodes -L topology.kubernetes.io/zone
boutique-leader-...      Ready  control-plane,etcd  2m26s  v1.36.5+k3s1  us-east-1a
boutique-follower-...    Ready  control-plane,etcd     36s  v1.36.5+k3s1  us-east-1b
boutique-follower-...    Ready  control-plane,etcd     51s  v1.36.5+k3s1  us-east-1c
boutique-agent-...       Ready  <none>                 69s  v1.36.5+k3s1  us-east-1c

$ kubectl get --raw=/healthz/etcd  ->  ok
  control-plane nodes Ready: 3 of 3 (quorum is 2)
  ls /var/lib/rancher/k3s/server/db/etcd/  ->  config  member  name

$ ./scripts/doctor.sh  ->  VERDICT: PASS -- 10 checks green, 0 warning(s), cluster healthy
$ ./scripts/check.sh   ->  PASS: 136   FAIL: 0   MISSING: 0
```

Still not proven: the etcd snapshot timer is `enabled / active` but its first run is three hours
away (`LAST PASSED -`), so no snapshot has been written to S3 yet, and the restore drill in
Phase 4 has never executed against this datastore. No chart has been installed and no
application pod exists.

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
| 4 × t3.small nodes | $45.14 | 2920 billable h, pooled free hours applied — the shape that actually launches |
| 4 × 16 GiB gp3 | $2.72 | 30 GiB free, CMK instead of the managed key |
| ALB + ~2 LCU | $28.11 | decision 2 |
| logs / snapshots / ECR | ≈$6.60 | retained logs have a lifecycle |
| **Subtotal (the SPEC table)** | **≈$82.56/mo** | **≈$116.78 over the 43 days left (58% of the $200 credit)** |
| 1 × KMS CMK | $1.00 | **a line the SPEC table does not carry** — one key for EBS and the token |
| detailed monitoring | $1.20 | $0.30 × 4 nodes, **also new** — the t3 sustained-CPU risk is otherwise unobservable |
| **Total as built** | **≈$84.76/mo** | **≈$119.83 over the window (60% of the $200 credit)** |
| …if CPU saturates its 20% baseline | +$82.12 | **worst case ≈$166.88/mo ≈$235.95 over the window — over the $200 credit** |

The shape change from `3 × t3.small + 1 × t3.medium` (the figure every earlier revision of this
table carried) moved the committed line from **$97.74/mo to $82.56/mo**, because t3.medium could
not have launched anyway. The worst case is still over the credit; `scripts/cost-estimate.sh`
prints that warning on every run rather than burying it here.

Teardown at Phase 14 returns the account to $0. `destroy.yml` exists before the ALB exists.

---

## Phase 5 — what the edge build actually produced (2026-10-09)

**Branch:** `feat/edge`, merged to `main`. Validation by real command, not by assertion.

### Terraform — the AWS layer

```
terraform -chdir=platform plan
Plan: 89 to add, 0 to change, 0 to destroy.
```

The 89 include, from me: the ALB, two target groups on the Traefik NodePorts (four attachments
each, because attachment is by index — instance IDs are unknown until apply and a `for_each`
keyed on an unknown value is a hard error), an HTTP listener that is a **fixed-action 301
redirect** and never forwards, an HTTPS listener with a TLS 1.3 policy, an ACM import gated on a
`cert_mode` variable, the Web ACL with five rule groups **all in count mode by default**, the
WAF log group, and two S3 buckets (access logs, and a disjoint audit bucket, because a bucket
cannot log to itself).

### The Web ACL is a control, not a decoration

Four AWS managed rule groups verified to exist for this account:

```bash
$ aws wafv2 list-available-managed-rule-groups --scope REGIONAL \
    --query 'ManagedRuleGroups[?starts_with(Name,`AWSManagedRules`)].Name'
AWSManagedRulesCommonRuleSet AWSManagedRulesKnownBadInputsRuleSet
AWSManagedRulesSQLiRuleSet AWSManagedRulesLinuxRuleSet
```

**The Log4j question, answered rather than assumed.** Two checkov findings (CKV_AWS_192,
CKV2_AWS_76) demand a rule referencing a Log4j AWS *managed rule group by name*. AWS ships
no such group. The Log4JRCE_* rules live *inside*
`AWSManagedRulesKnownBadInputsRuleSet`, which this ACL already attaches:

```bash
$ aws wafv2 describe-managed-rule-group --scope REGIONAL --vendor-name AWS \
    --name AWSManagedRulesKnownBadInputsRuleSet --query 'Rules[].Name' | tr '\t' '\n'
JavaDeserializationRCE_BODY
JavaDeserializationRCE_URIPATH
JavaDeserializationRCE_QUERYSTRING
JavaDeserializationRCE_HEADER
Log4JRCE_QUERYSTRING
Log4JRCE_BODY
Log4JRCE_URIPATH
Log4JRCE_HEADER
```

So the coverage is real, the suppression is justified with a URL, and a `log4j-coverage` rule at
priority 15 gives that group its own CloudWatch metric so the coverage is attributable. This
matters because the app ships a Java service (`adservice`).

### TLS — the path that was needed, not the path that is convenient

There is no Route 53 zone and no ACM certificate in the account, so a DNS-validated certificate
from a public CA is impossible. Two paths are implemented behind a `cert_mode` variable:

- `self-signed` (default): `scripts/tls/generate-selfsigned.sh` writes a key to a gitignored
  path and prints the `aws acm import-certificate` command, so the key never enters state.
- `http01`: no ACM cert; cert-manager solves HTTP-01 against the ALB hostname through sslip.io
  and TLS terminates at Traefik.

The **TLS policy was verified, not guessed**:

```bash
$ aws elbv2 describe-ssl-policies --query 'SslPolicies[?contains(Name,`TLS13`)].Name'
ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09
ELBSecurityPolicy-TLS13-1-2-Ext1-PQ-2025-09
ELBSecurityPolicy-TLS13-1-2-Ext2-PQ-2025-09
ELBSecurityPolicy-TLS13-1-0-PQ-2025-09
ELBSecurityPolicy-TLS13-1-2-PQ-2025-09
ELBSecurityPolicy-TLS13-1-3-PQ-2025-09
```

`ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` is the one used.

### The gate caught two real violations, which is the whole point of a gate

Traefik's Middleware CRD was wrong in two ways, and `kubeconform` on the **rendered** chart
output caught both — the raw template cannot be validated because `{{- if }}` is not YAML:

```
Summary: 15 resources found in 1 file - Valid: 15, Invalid: 0, Errors: 0, Skipped: 0
```

1. `redirectScheme.port: 443` — the CRD types the port as a **string**, so the API server would
   have rejected it.
2. `sourceCriterion` was nested at spec level; the schema only allows it inside `rateLimit`.
   Fixed by keying on the client IP instead of `X-Forwarded-For`, which is the correct control
   anyway: the header is attacker-controlled on a request that never reached the ALB.

Both would have been discovered at `helm install` on a real cluster, which is exactly the class
of failure a local gate should catch first.

### ACME on a DaemonSet is impossible, and that shaped the design

The chart refuses to render a DaemonSet with any `--certificatesresolvers.*.acme.*` argument:
ACME writes `acme.json`, and a DaemonSet runs one pod per node, each with its own copy, so
renewals would race and clobber. The HTTP-01 challenge therefore runs in **cert-manager**
(single Deployment, account key in a Secret) and Traefik reads the issued certificate from that
Secret. Declaring the resolver only by name, and not at all in self-signed mode.

### checkov: 228 passed, 0 failed, 4 skipped — every skip named

Real findings **fixed in code, not suppressed**: CKV_AWS_158 and CKV_AWS_145 (KMS on the log
group and both log buckets), CKV_AWS_18 (access logging, which required a second disjoint
bucket), CKV_AWS_300 (abort-incomplete-multipart on both buckets), CKV_AWS_233
(create-before-destroy on the cert).

Four remain suppressed, each with a URL and a reason: CKV_AWS_378 (the http target group is
plaintext by design — the second layer forces the upgrade), CKV_AWS_338 (14-day retention is
correct for a 43-day platform; the value is a variable), CKV_AWS_192 and CKV2_AWS_76 (Log4j
coverage, above).

### Also

- `shellcheck -x scripts/tls/generate-selfsigned.sh scripts/*.sh` clean; `gitleaks detect --no-git`
  finds nothing; `grep -rIn 'BEGIN.*PRIVATE KEY' --include='*.tf' .` is empty — no key in state.
- `tflint --recursive` clean.
- The full gate: **108 → 109 pass, 0 fail, 0 missing** once the checkov suppression above was
  recorded.
- `docs/runbooks/edge.md` written: unhealthy targets, WAF false positive, cert expiry, and the
  plaintext backstop — each with the real command and the rollback path.

---

## Phase 7 and 8 — the CI/CD layer (2026-10-14, built on `feat/cicd`, merged)

Jenkins, in the cluster, as a Helm wrapper. Everything that does not need a cluster is proven;
nothing that needs one has been run.

### What landed

- `ci/jenkins/` — a wrapper around `jenkins/jenkins` **5.9.68**: JCasC (matrix authorization in
  four groups, a kubernetes cloud, eleven plugin pins with `installLatestPlugins: false`), an
  agent pod template with a `dind` sidecar and `containerCap: "8"`, a 10Gi `local-path` PVC, the
  `platform-ci-controller` priority class, and `installPlugins` pinned rather than floated. The
  chart creates no RBAC and no ServiceAccount on purpose: `ci/rbac/` does, five files, and the
  Role carries no `secrets` verb.
- `ci/backup/cronjob.yaml` — 03:17 UTC, tar the PVC, `aws s3 cp`, prune at 14 days,
  `automountServiceAccountToken: false` because it never talks to the API.
- `policy/ci.rego` — the namespace-profile mechanism: `baseline` for `ci` and `observability`,
  `restricted` everywhere else, so the one token mount Jenkins needs does not loosen `boutique`.
- `pipelines/` — the shared library: `tools` (one pinned container per command), `buildAndTest`
  (gates, then buildx), `scanAndSign`, `deployToStaging`, `smokeGate`, `canaryAndRollback`,
  `promoteToProd`, plus three shell resources holding the logic that deserves shellcheck.
- `Jenkinsfile` — twelve gates, then build → scan → deploy → smoke → canary (with automatic
  rollback) → approval → promote. Parameters, not secrets; a stage with no input says so and
  stops rather than reporting a release it did not perform.

### What each claim rests on

| claim | evidence |
|---|---|
| the chart is valid | `helm lint --strict` clean; `helm template ci ci/jenkins` renders `StatefulSet ci`, the two Services and the PVC |
| the policy accepts `ci/` and still rejects the app | `conftest test ci/` **144 passed**; old-vs-new policy over apps+cluster+ci+observability **2430 tests, byte-identical output**, `--combine` identical, all 3 fixtures with identical exit codes |
| the manifests are schema-valid | `kubeconform -strict` **6/6 valid** on the non-chart files; the literal `kubeconform … ci/` exits 1 on `Chart.yaml`/`values.yaml` with "missing 'kind' key", which is why `check.sh` filters exactly those, and the filter is documented there |
| the pipeline's gates are real | all twelve green in their pinned containers on this machine, with the same `docker run` shape `vars/tools.groovy` uses — including the two that were red on the first attempt (the shellcheck image is `FROM scratch` and its entrypoint is already the binary; `helm repo add` has to run in the same container as `dependency build`) |
| the pins exist | eleven plugin versions each return **HTTP 200** from `updates.jenkins.io/download/plugins`; every container tag checked against its registry's tag API |
| nothing leaked in | `gitleaks` clean; the 19 non-comment `password|token|secret` hits in `ci/` and `pipelines/` are field names, Secret/key names, mount paths and `${...}` placeholders |
| the whole gate still passes | `scripts/check.sh` **127 pass, 0 fail, 0 missing** — up from 112 by exactly fifteen lines: 6 kubeconform (`ci/rbac`, `ci/backup`), 3 conftest fixture rejections, 3 shellcheck and 3 `bash -n` for the new `pipelines/resources/*.sh` |

The cost estimate is unchanged at **$97.74/month**: `scripts/cost-estimate.sh` and everything it
reads were not touched by this phase. The Jenkins number that *does* change is the controller's
120m / 576Mi of requests, now measured from our own chart instead of quoted from the upstream
default, in `docs/resource-budget.md` §4.

### What is unproven, and why

The controller has never booted. JCasC has never applied. No agent pod has started, no
`container('dind')` has reached a daemon, no image has been built, and the canary has never rolled
anything back — each of those needs a cluster, and two of them also need an application this
repository does not deploy. Five rows in `TASKS.md`'s blockers table carry them;
`docs/runbooks/ci.md` carries the commands that will be run and what each failure will look like.

## Phase 11 — the traces layer (2026-10-14)

**Branch:** `feat/traces`, merged to `main`. Validation by real command, not by assertion. Nothing applied: no
`helm install`, no `kubectl apply`, no cluster exists. The ROADMAP's five Phase 11 exit criteria
all need one — a trace read back by ID, a rendered service graph, `promtool query instant` of
`traces_spanmetrics_*`, a waterfall screenshot, adservice spans — so **none of them is claimed
here**. What this phase proves is the other half of the ROADMAP's own validation list, the
automated half: `otelcol-contrib validate --config`, `helm template`, and every gate in
`scripts/check.sh`. The manual half is TASKS U13 and Phase 13.

### What landed

- **`observability/tempo/`** — a wrapper chart pinning `grafana/tempo` **1.24.4 / app 2.9.0**
  (verified the latest with `helm search repo grafana/tempo --versions`; the chart carries
  `deprecated: true`, which is documented in `Chart.yaml` and is not a blocker: the app is 2.9.0
  and the values are this platform's, not the chart's defaults). Single binary on a 10Gi gp3
  claim, `metricsGenerator.processors: [service-graphs]` and **never `span-metrics`** — one
  producer per metric family, because two writers on the same family violates the single-writer
  rule and the collector already owns spanmetrics. Remote-write into
  `kube-prometheus-stack-prometheus.observability.svc:9090/api/v1/write`, 24h retention,
  memberlist ring at RF 1, pod + container securityContext, `automountServiceAccountToken: false`,
  and a `serviceMonitor` with the `release` label the operator selects on.
- **Three Tempo alerts** — `TempoRequestErrors` (5xx by route), `TempoRequestLatency` (p99 vs the
  query-frontend's own 5s SLO), `TempoDiskNearFull` (the local-store variant of the Phase 9 disk
  alert). `TracesSpanmetricsMissing` is defined **once**, in
  `observability/rules/spanmetrics.yaml`; `tempo/alerts.yaml` carries a comment pointing at it
  rather than a second copy that could drift.
- **The collector's spanmetrics half** — a second `traces/spanmetrics` pipeline off the same OTLP
  receiver with **no `tail_sampling` in it**, feeding the `spanmetrics` connector
  (`histogram.unit: s`, buckets `[0.05s … 10s]` matching Traefik's ladder, explicit dimensions
  `http.method`/`http.route`, `exclude_dimensions: [collector.instance.id]`, cardinality limit
  5000) → `metrics/spanmetrics` → `prometheus` exporter on `0.0.0.0:9464`. The main `traces`
  pipeline keeps `[memory_limiter, tail_sampling, batch]` and now ends at `otlp/tempo` (the debug
  exporter is gone, which also closes the Phase 6 blocker "collector `debug` → Tempo").
- **Rules** — `span:request_rate:ratio`, `span:error_ratio:ratio`, `span:latency_p95:seconds`,
  `boutique:edge_to_span_ratio` (all `label_replace` `service_name` → `job` so they join the edge
  metrics, server spans only, `STATUS_CODE_ERROR` — the label value the connector actually emits).
  The placeholder spanmetrics group that shipped with the golden-signals file was removed and its
  header bullet now points at `spanmetrics.yaml`.
- **Dashboard, datasource, scrape** — `observability/dashboards/traces.yaml` (a ConfigMap carrying
  `traces.json` under `grafana_dashboard: "1"` — see the deviations note), a `tempo` datasource in
  kps with `serviceMap.datasourceUid: prometheus`, `enableRemoteWriteReceiver: true` on the
  Prometheus CRD, and a ServiceMonitor scraping both collector endpoints (`telemetry` :8888 self
  metrics at 30s, `metrics` :9464 spanmetrics at 15s).
- **`docs/runbooks/traces.md`** — three scenarios (trace missing / spanmetrics silent / Tempo disk
  full), each walked hop by hop through the pipeline with the exact `curl`, `promtool query` and
  `kubectl logs` commands and an interpretation table, plus a "what this runbook has NOT proven"
  section.

### Evidence

```
helm lint --strict observability/tempo
                                            1 chart(s) linted, 0 chart(s) failed
helm template tempo observability/tempo -n observability | kubeconform -strict
  -kubernetes-version 1.36.3 (+ the CRDs-catalog schema location)
                                            Summary: 6 resources found - Valid: 6, Invalid: 0, Errors: 0
                                              (StatefulSet, ConfigMap, Service, ServiceAccount,
                                               ServiceMonitor, PrometheusRule)
promtool check rules (observability/rules/*.yaml, tempo/alerts.yaml, loki/alerts.yaml)
                                            spanmetrics 5 · tempo 3 · golden-signals 6 ·
                                            boutique-alerts 9 · slo-recording 19 · loki 4 — all SUCCESS
conftest test <rendered tempo> -p policy/    108 tests, 108 passed, 0 warnings, 0 failures
                                             (the first run FAILED 1: CPU request 250m vs limit 1 —
                                              fixed in values.yaml, not by touching the policy)
otelcol-contrib 0.160.0 validate --config <the extracted ConfigMap key>
                                            rc=0
                                             (first run rejected service.telemetry.metrics.address —
                                              removed in 0.160 — config now uses telemetry.metrics.readers)
python3 scripts/check-dashboards.py observability/dashboards/traces.yaml
                                            ok: 1 dashboard JSON document(s) parse
python3 scripts/resource-budget.py ...       3850m / 4688Mi = 210.4% CPU / 125.3% RAM of schedulable,
                                             accepted bound 250% → RESULT: FITS
gitleaks detect --no-git                    no leaks found
scripts/check.sh                            PASS: 118  FAIL: 0  MISSING: 0
                                             (every section: whitespace, terraform, gitleaks,
                                              kubeconform over the raw manifests AND over the
                                              rendered traefik + tempo charts, conftest both modes,
                                              helm lint/template, the fluent-bit dry-run, promtool
                                              on all six rule files, the five dashboards' JSON,
                                              the node-capacity budget, shellcheck/bash -n,
                                              actionlint, the python checks)
```

### Decisions worth recording, because each was a real fork

- **Pre-sampling fan-out.** Feeding spanmetrics from the sampled pipeline would have made the
  error ratio a lie (100% of errors counted, 10% of successes) and the rate a tenth of the truth.
  The cost is a second pipeline's memory_limiter/batch, at 192Mi per replica.
- **Single producer per metric family**, enforced by splitting the two producers between Tempo
  (`service-graphs` only) and the collector (`spanmetrics` only).
- **The dashboard is a `.yaml`, not a `.json`.** The repo convention's `.json` files cannot carry
  the `grafana_dashboard: "1"` label the sidecar selects on, and a bare `.json` is invisible to
  `scripts/check-dashboards.py`. The JSON lives inside the ConfigMap and the parser reads it from
  there.
- **Loki's `derivedFields` stays `[]`.** Pointing Tempo traces at Loki needs a
  traceID→log pattern this platform's Loki (3.x) query syntax has to be verified against, not
  guessed; the comment says exactly what would be added and why it is not there yet.
- **Policy satisfied, never waived.** Tempo's first values had CPU `250m/1` — `conftest` rejected
  it (Guaranteed QoS), and the values were changed to `250m/250m`. `policy/resources.rego` is
  byte-identical to before this phase.
- **`scripts/check.sh` now kubeconforms the rendered Tempo chart**, the same treatment traefik
  already got: the chart's sources are Go template text and its `ServiceMonitor`/
  `PrometheusRule` are CRDs, so the render is the only place they can be schema-checked.

### Cost, moved by one line

`scripts/cost-estimate.sh`'s CPU-credit model reads `MEASURED_REQUEST_MILLI`, which was 3600 and
is now 3850 (measured, from the same render). The committed cost is unchanged — instances are
priced by shape, not by requests — but the modelled worst case moved:

```
  platform requests      3850m  (admission guarantee only)
  worst case sustained   3850m  = requests fully used -> $82.12/mo surcharge risk
  !! total incl. worst case $179.87/month  $254.42 over 43 days - OVER the $200 credit
```

The worst case was already over the credit ($170.74 / $241.51); Phase 11 widens that gap by
$12.91. Expected sustained (1280m, 80% of the t3 baseline under demo traffic) is unchanged at
$0.00 surcharge.

### Not proven by this phase

| claim | status |
|---|---|
| A real trace crossing collector → Tempo → Grafana | **not proven** — no cluster; TASKS U13, runbook scenario 1 |
| `readOnlyRootFilesystem` on the Tempo pod at runtime | **not proven** — the emptyDir covers `/tmp` only while `metricsGenerator.enabled` is true, and the values file names that footgun |
| The remote-write URL's release name (`kube-prometheus-stack-prometheus`) | **reasoned, not observed** — derived from every ServiceMonitor/Rule in the repo carrying `release: kube-prometheus-stack` plus the operator's default `{release: <release name>}` selector, which `kube-prometheus-stack/values.yaml` states explicitly. Nothing scrapes and nothing remote-writes until a cluster proves the pairing. |
| The `jaeger-metrics` ServiceMonitor endpoint | **known-inert** — `tempoQuery` sidecar is off, the port is not on the Service, the operator skips it; reasoned in `observability/tempo/values.yaml` |
| The Tempo chart's `deprecated: true` flag | **documented, not resolved** — pinning is the mitigation; the replacement chart (`tempo-vulture`/`tempo` split upstream) is a separate decision |
