# boutique-platform — specification

## Problem

Run the Google Online Boutique sample application as a **production-grade platform** on a
single AWS Free-plan account, with Jenkins CI/CD and a full observability stack — using only
services that account can actually reach, at a cost that fits its remaining free-tier window.

The problem is not "deploy a demo app". It is that Google's own Online Boutique deployment is
a *minimal, kind-deployable baseline by design*: its `docs/product-requirements.md` explicitly
mandates "preserve the golden user journey taken by Kubernetes beginners" and "preserve the
simplicity of the GKE quickstart". Everything that makes a deployment survivable —
PodDisruptionBudget, HPA, topology spread, priority classes, ResourceQuota, private nodes,
Binary Authorization, egress DNS carve-outs, SLOs — is deliberately **absent from the shipped
manifests** and exists only in Google's hardening *docs*.

This platform therefore has a specific, testable claim: **the same application, the same
architecture shape as Google's production deployment, with every hardening control Google's
docs mandate actually present, proven with command output.**

## Users

| User | Constraint |
|---|---|
| Aravind (operator) | One human, free-tier account, 43 days of credit window left, 8 vCPU quota, no NAT budget, wants hiring-visible evidence |
| Platform consumers | Developers pushing PRs through Jenkins into ephemeral test namespaces and then prod |
| On-call during a demo | Needs a Grafana dashboard, an SLO burn alert, and a runbook, not a shell |
| Recruiter / interviewer | Reads the repo and the evidence pack; every claim must be checkable |

## Current scope

One cluster (`boutique-prod`), one VPC, three availability zones, one edge ALB, one Jenkins
controller, one observability namespace, one application namespace. Single-writer, single-owner.

## Original build constraints (2026-10-08, live evidence)

Gathered before any design decision, from the account itself (`348032171026`, `us-east-1`):

| Constraint | Value | Consequence |
|---|---|---|
| Running On-Demand instance vCPU quota | **8.0** | max 4 × t3-class instances, total, including CI nodes |
| EC2 free-tier hours | 750/month aggregated | ~1.0 node is free; every extra node-hour is billed |
| `t2.micro` free tier eligible | **false** | any tutorial pinning `t2.micro` is wrong here |
| `t3.micro` RAM | 1.0 GiB | cannot host Boutique + Jenkins + observability — OOMKills |
| Network Load Balancer | **blocked account-wide** (`network-load-balancer-capacity-units = 0`) | edge must be ALB or a node-port entry |
| ALB | works | ~$28/mo all-in; 63% of the cheap variant's cost |
| Route 53 hosted zones | 0 | no DNS validation path for ACM → no real public hostname by default |
| ACM certificates | 0 | certs must be imported (self-signed) or issued over HTTP-01 via a wildcard-DNS name |
| NAT gateways | 0 (would be $32+/mo) | nodes run in **public** subnets and must be hardened accordingly |
| EKS control plane | $73/mo | disqualified: 3.5× the 6-month budget |
| Free-plan window ends | **~2026-11-20** | the cluster is a short-lived validation target; the repo is the durable artifact |
| Credit budget | $200 over 6 months | hard ceiling on the whole build |

## Required behavior

**Cluster**
- Three-node k3s cluster, one node per AZ (`us-east-1a/b/c`), HA etcd, quorum survivable with
  one node lost.
- Nodes reachable only through SSM Session Manager; no SSH key pair, no port 22, no bastion host.
- `kubectl` access only through a short-lived, auditable path; never a long-lived kubeconfig in
  the repo, in CI secrets, or on disk unencrypted.

**Edge (two-layer, mirroring Google's external-ALB → mesh-ingress shape)**
- ALB terminates TLS, redirects 80 → 301 to 443, ships access logs to S3, fronts a Web ACL
  (Cloud Armor analogue: AWSManagedRulesCommonRuleSet + SQLi + known-bad-inputs + rate limit).
- In-cluster Traefik routes host-based traffic to `frontend`, `grafana`, `jenkins`.
- `curl -sSI https://<host>/` returns 200 with a valid cert chain and an `HTTP/2` response;
  `curl -sSI http://<host>/` returns 301 to the https URL.

**Application**
- All 11 Online Boutique services + `redis-cart` + `loadgenerator` running, each with: a
  dedicated ServiceAccount, `readOnlyRootFilesystem: true`, `runAsNonRoot: true`,
  `allowPrivilegeEscalation: false`, capabilities dropped `ALL`, requests and limits set.
- Every service reachable through the edge and rendering a full checkout journey.
- `loadgenerator` drives real traffic; the aggregated error count is observable and alerteable.

**CI/CD**
- A PR builds, unit-tests, container-scans, SBOMs, signs, and deploys to an ephemeral PR
  namespace; a zero-error smoke gate fails the PR on any request error (Google's gate, hardened).
- Merge to `main` promotes to production behind an explicit approval gate, with a canary step
  and automatic rollback on SLO burn.

**Observability**
- Prometheus scrapes cluster, node, workload, and Jenkins metrics; recording rules produce
  request-rate / error-rate / latency ratios per service.
- Logs for every workload land in Loki with structured parsing, queryable in a provisioned
  Grafana dashboard.
- Traces from the instrumented services land in Tempo through an OTel Collector gateway with
  `batch`, `memory_limiter`, and tail sampling.
- Multiwindow multi-burn-rate SLO alerts fire before a user-visible outage.

**Operational clarity**
- A `scripts/doctor.sh` that reports cluster health in one shot.
- Runbooks for: node loss, rollback, etcd restore, cost spike, Jenkins agent stall, cert expiry.
- Every destructive and cost-bearing action has a tested rollback path.

## Architecture and data flow

```
                 ┌───────────────────────── AWS (us-east-1) ──────────────────────────┐
                 │                                                                   │
  operator ──SSM─┤─► k3s server a (t3.small) ─┐                                        │
                 │   k3s server b (t3.small) ─┼─► etcd quorum of 3, one per AZ (HA)   │
                 │   k3s server c (t3.small) ─┘                                        │
                 │                                                                   │
                 │   k3s agent   (t3.medium)  ── all workloads live here              │
                 │        │  Traefik (in-cluster L7, Host-based routing)             │
                 │        ▼                                                           │
  internet ──► ALB ──(TLS, WAF, access logs)──► target group ──► Traefik ──► frontend │
                 │                                                         │         │
                 │   ┌───────────────── namespace: observability ─────────┐│         │
                 │   │ Prometheus • Grafana • Alertmanager • Loki •       ││         │
                 │   │ Tempo • OTel Collector gateway                     ││         │
                 │   └────────────────────────────────────────────────────┘│         │
                 │   ┌───────────────── namespace: ci ─────────────────────┤         │
                 │   │ Jenkins controller (JCasC) → ephemeral agent pods    │         │
                 │   └─────────────────────────────────────────────────────┘│         │
                 │   ┌───────────────── namespace: boutique ───────────────┘         │
                 │   │ 11 services + redis-cart + loadgenerator                       │
                 │   └───────────────────────────────────────────────────────────────┘
                 └───────────────────────────────────────────────────────────────────┘

  vCPU: 3×2 + 1×2 = 8 of the 8.0 quota — at the ceiling, no 5th instance is possible
  RAM : 3×2 + 1×4 = 10 GiB against ~9.5 GiB of workload requests
```

**Delivery path:** PR → GitHub Actions (plan gate) → Jenkins (build/test/scan/sign/push to ECR)
→ ephemeral `pr-<n>` namespace + smoke gate → approval → promote to `boutique` with canary
and auto-rollback on burn-rate alert.

**State ownership:** Terraform state in S3 with native `use_lockfile` locking. Application
state is `redis-cart` `emptyDir` (deliberate, matching upstream), with a documented loss
semantics note. Observability state (Prometheus TSDB, Loki, Tempo) is `gp3` PVCs with
snapshot/restore runbooks.

## Security and privacy

- **Trust boundary 1 — internet to edge:** ALB + Web ACL. TLS 1.2+ minimum, HTTP→HTTPS
  redirect, access logging to a dedicated S3 bucket with a 30-day lifecycle.
- **Trust boundary 2 — edge to cluster:** ALB target group restricted to the three node
  security-group sources on the Traefik NodePort only.
- **Trust boundary 3 — node access:** SSM only. No key pairs created, no port 22 rule, no
  bastion. Nodes have public IPs (no NAT budget) so their security groups are explicit and
  narrow: `6443/tcp` from operator CIDR only, `10250/tcp` intra-cluster only, `8472/udp`
  (Flannel VXLAN) intra-cluster only, ephemeral high ports from the ALB SG only.
- **Trust boundary 4 — in-cluster:** default-deny NetworkPolicy in `boutique` and `ci`, plus
  per-service allow policies **including the DNS egress carve-out that upstream omits**.
  Pod Security Admission `restricted` enforced on `boutique`.
- **Least privilege:** one IAM instance profile shared by nodes, scoped to SSM, CloudWatch
  agent, ECR-pull, and S3 log/state access only. Jenkins agents get no AWS credentials
  unless a specific pipeline needs them, and then only through a scoped OIDC assumption.
- **Secrets:** never in the repo, never in Terraform, never in a kubeconfig. Jenkins
  credentials live in the Jenkins credential store; database/registry tokens are injected at
  runtime. `.gitleaksignore` carries fingerprints only.
- **Required scans:** `gitleaks` in CI; `checkov` on all Terraform; `trivy` on images and IaC;
  `kube-linter`/`conftest` on manifests where applicable.

## Pinned versions

| Thing | Version | Verified on |
|---|---|---|
| Terraform | `1.15.9` (installed); `required_version = ">= 1.10.0"` — 1.10 needed for `use_lockfile` | 2026-10-08 |
| AWS provider | `~> 6.68` (latest 6.x is 6.68.0) | 2026-10-08 |
| k3s | `v1.36.5+k3s1` (stable channel) | 2026-10-08 |
| Helm | `3.16.3` | 2026-10-08 |
| kubectl | `v1.36.3` | 2026-10-08 |
| Online Boutique | `v0.10.7` (HEAD is v0.10.7, released 2026-09-18); images at `us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/<svc>:v0.10.7` | 2026-10-08 |
| Jenkins chart / app | `5.9.68` / `2.580.1` (LTS) | 2026-10-08 |
| kube-prometheus-stack chart / app | `92.1.1` / `v0.94.1` | 2026-10-08 |
| Loki chart / app | `7.3.0` / `3.6.12` | 2026-10-08 |
| Tempo chart / app | `1.24.4` / `2.9.0` | 2026-10-08 |
| cert-manager chart / app | `v1.21.2` / `v1.21.2` (optional; sslip.io + HTTP-01 path) | 2026-10-08 |
| OTel Collector | `0.160.0` (matches upstream) | 2026-10-08 |
| Python (any tooling) | `3.13` (`python3.13`) | 2026-10-08 |
| Node | `.nvmrc` pinned, consumed by `setup-node` | 2026-10-08 |

Re-verify when a phase reopens. Do not take versions from memory.

## Cost and limits

Budget: the remaining Free-plan window (43 days) must stay inside the $200 credit.

| Design line | Monthly | Remaining window (≈1.42 mo) |
|---|---|---|
| 3 × `t3.small` k3s servers (1440 billable h × $0.0208) | $29.95 | $42.64 |
| 1 × `t3.medium` workload node (730 h × $0.0416) | $30.37 | $43.23 |
| 4 × 16 GiB `gp3` (64 − 30 free) | $2.72 | $3.88 |
| ALB + ~2 LCU | $28.11 | $40.00 |
| Logs / snapshots / egress | $6.60 | $9.40 |
| **Total** | **≈$97.74** | **≈$138** (69% of the $200 credit) |
| Without the ALB | ≈$69.63 | ≈$99 (50%) |

Two hard requirements follow, both enforced by CI:
1. A `destroy.yml` must be able to take the whole platform down to $0, and its dry-run must be
   shown before it is approved.
2. `scripts/cost-estimate.sh` must recompute the above from current pricing and print it as
   part of the plan gate. It exits non-zero if the window total exceeds the credit budget.

Teardown expectation: **destroy after validation.** The repo, the evidence pack, and the
rendered screenshots are the deliverables that persist.

## Non-goals

- **Not EKS.** Disqualified on cost ($73/mo control plane), not capability. An EKS migration
  path is documented, not built.
- **Not multi-region.** Two layers of edge exist; a second region does not, and no claim of
  multi-region failover is made.
- **Not a service mesh.** Istio/Cilium Service Mesh needs a sidecar per pod and more RAM than
  4 GiB/node can host next to Jenkins and Prometheus. mTLS is achieved at ingress and
  documented as a gap with the reason.
- **Not Binary Authorization / Sigstore admission.** Image signing (cosign) and attestation
  are in scope; a cluster admission controller that verifies it is out of scope.
- **Not GitOps-only delivery.** Jenkins is the requested engine. Argo CD is evaluated as an
  alternative in an ADR, not run alongside.
- **Not the synthetic fault flags.** `adServiceFailure` / `recommendationCacheFailure` do not
  exist upstream (verified across v0.1.4–v0.10.7). Chaos is `EXTRA_LATENCY` plus pod/node
  deletion only.
- **Not a real domain.** Hostnames are either ALB DNS directly or `<lb>.ip.sslip.io`; the
  default is explicitly a non-production cert path.

## Acceptance criteria

Every criterion below is *observable* and names the check that proves it.

**Cluster**
- [ ] Three k3s servers form an etcd quorum across three AZs; `kubectl drain` of one server keeps control-plane quorum and the app up — proven by `etcdctl member list` + `scripts/doctor.sh` + a recorded drain test
- [ ] The workload node is labelled and tainted so only application, CI, and observability
      namespaces schedule on it — proven by `kubectl get node -o jsonpath` for the taints and
      `kubectl get pods -A -o wide` showing nothing system-critical scheduled elsewhere
- [ ] `terraform plan` is empty after `apply`, including the edge and observability layers — proven by a pasted plan summary showing `0 to add, 0 to change, 0 to destroy`
- [ ] Nodes have no SSH rule: `aws ec2 describe-security-groups` shows no `22/tcp` ingress on the node SG and no key pair referenced in the launch template — proven by `scripts/security-audit.sh` and `aws ec2 describe-instances` showing `KeyName: null`
- [ ] Total vCPU across all instances is ≤ 8.0 (the quota) — proven by `scripts/cost-estimate.sh` and `aws service-quotas get-service-quota`

**Edge**
- [ ] `curl -sSI https://<host>/` returns `200` with a valid chain; `curl -sSI http://<host>/` returns `301` to the https URL — proven by pasted curl output
- [ ] Web ACL blocks an SQLi-pattern request with `403` — proven by a pasted curl with `?id=1' OR '1'='1`

**Application**
- [ ] All 13 workloads `Available` with `replicas == readyReplicas` — proven by `kubectl get deploy -n boutique -o wide`
- [ ] Full checkout journey succeeds with `0` request errors over ≥50 loadgenerator requests — proven by the Jenkins smoke gate and a pasted `kubectl logs -l app=loadgenerator | grep Aggregated`
- [ ] Every Boutique container has `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, no privilege escalation, capabilities dropped, and requests=limits CPU — proven by `kubectl get deploy -n boutique -o jsonpath` + a `conftest`/`kubeconform` gate in CI

**Resilience**
- [ ] PodDisruptionBudgets and HorizontalPodAutoscalers exist for every service, topology spread constrains pods across AZs, and one node drain causes zero failed requests — proven by a recorded drain + loadgenerator error count
- [ ] A failed canary rolls back automatically with no manual step — proven by a pasted Jenkins stage log showing rollback and a post-rollback `rollout history`

**CI/CD**
- [ ] A PR produces: unit tests green, trivy scan report, SBOM, cosign signature, ephemeral `pr-<n>` namespace, smoke gate result — proven by pasted Jenkins run output
- [ ] Jenkins agents are ephemeral pods that exit after the build, not long-lived workers — proven by `kubectl get pods -n ci` before and after
- [ ] Production deploy is gated on an explicit human approval input — proven by the Jenkinsfile and a screenshot of the input step

**Observability**
- [ ] Prometheus scrapes every Boutique pod and exposes a per-service request rate, error ratio, and p95 latency — proven by `promtool query instant` pasted output
- [ ] Multiwindow multi-burn-rate alerts exist per SLO and fire in a deliberate test — proven by a recorded alert firing in Alertmanager
- [ ] A trace for a checkout request spans `frontend → checkout → payment` in Tempo — proven by a Tempo API query returning the span set
- [ ] A Grafana dashboard shows request rate, error ratio, latency heatmap, and SLO burn for the app — proven by a screenshot attached to the PR

**Operational clarity**
- [ ] `scripts/doctor.sh` exits 0 on a healthy cluster and non-zero with a readable reason when something is wrong — proven by a pasted healthy run and a deliberate break
- [ ] Every runbook references a command that was actually run during the build — proven by the runbooks' "Last verified" lines

## Unresolved questions

These need a decision before the phase that depends on them. They are recorded, not guessed.

| # | Decision | Why it blocks | Cost impact |
|---|---|---|---|
| 1 | **Node shape.** The workload requests sum to ~9.5 GiB; 3 × t3.small gives 6 GiB, 3 × t3.medium gives 12 GiB but 0 free-tier hours. The recommended shape (`scripts/cost-estimate.sh`) is **3 × t3.small as k3s servers + 1 × t3.medium as the workload node** = 10 GiB, 8 vCPU (exactly at quota), ~$138 for the window. | Phase 3 provisions nodes | $54 (3×small, no ALB, does not fit) → $180 (3×medium + ALB, 90% of credit) |
| 2 | **TLS path.** With no Route 53 zone and no ACM cert, options are (a) ALB DNS + a self-signed imported cert, (b) `<hash>.ip.sslip.io` + cert-manager HTTP-01 over a wildcard-DNS name, (c) no TLS and HTTP only. (b) gives a real public CA chain and is the recommended default. | Phase 5 | $0 either way |
| 3 | **ALB or no ALB.** Dropping the ALB saves ~$28/mo and leaves a node-IP entry with no WAF and no access logs. Keeps the platform further inside budget but loses the two-layer edge story. | Phase 5 | ~$40 of the window |
| 4 | **Jenkins placement.** In-cluster is the production pattern (dynamic agents, ephemeral, no SSH) and is the default; it rides on the medium workload node. A separate node is impossible — it would be the 5th instance and the 9th vCPU, both over quota. | Phase 7 | none (resolves itself) |
| 5 | **Registry retention.** ECR is usable with a 500 MB free tier. The lifecycle policy number must be tied to that limit rather than picked arbitrarily. | Phase 8 | $0 (a delete policy) |
| 6 | **Public GitHub repo?** The CI plan gate needs OIDC role trust for a repo, and the repo is hiring evidence. Default: public, with split plan/apply OIDC roles SHA-pinned actions. | Phase 0/1 | $0 |

## Cost and risk notes

- Everything in this SPEC's "Required behavior" must be proven against the **real** deployment
  before the running cluster is destroyed. An agent's report is never evidence.
- The 43-day window means the build order matters more than usual: platform → edge → app →
  CI → observability → evidence pack, so the expensive parts are never left running unattended.
