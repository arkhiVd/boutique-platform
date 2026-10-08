# boutique-platform — roadmap

Status: **Phase 0 in progress.** Phase 1 blocked on the SPEC's unresolved questions 1 and 3
(node size, ALB) — see "Approval gates".

How to read this: each phase is **one PR**, one review, one critic. A phase that cannot be
reviewed in ~10 minutes is scoped wrong and is split before work starts, not after the diff
explodes. Phases are ordered so the expensive layer is never running while there is nothing to
prove on it.

## Approval gates (project-dev §7)

Three things stop the build and require Aravind, in-session, every time:

1. **Sizing + cost decision** (SPEC unresolved Q1, Q3) — determines ~$130 vs ~$85 for the
   window. Needed before Phase 2 provisions anything.
2. **First `terraform apply`** — cost-bearing. `terraform plan` is pasted and read first.
3. **`destroy.yml`** — the only way to return the account to $0. Typed-confirmation gate plus
   a GitHub `environment:` approval, and a pasted `plan` showing what it destroys.

Everything else proceeds on the phase's own exit criteria.

---

## Wave A — Foundation

### Phase 0 — Guardrails and validation harness

**Outcome:** the repo can be worked on safely: guardrail docs, a working local gate, a
`plan.yml` CI gate that catches fmt/validate/security regressions before a human reads the PR.

**Included:** `AGENTS.md`, `CLAUDE.md`, `SPEC.md`, `ROADMAP.md`, `TASKS.md`, `.gitignore`,
`.gitattributes`, `.gitleaksignore`, `.github/pull_request_template.md`,
`.github/workflows/{plan,dependabot}.yml`, `PROGRESS.md`, `scripts/` skeleton, README.

**Dependencies and risks:** none. Cost: $0. Risk: none — no infrastructure touched.

**Exit criteria:**
- [ ] `terraform fmt -recursive -check`, `terraform validate`, `checkov`, `gitleaks`, and
      `shellcheck` all run green locally and in CI on the same commit
- [ ] `git diff --check` clean; no stray files; no secrets or tfvars committed
- [ ] The plan gate fails when a `.tf` file is malformed (proved by a deliberate break commit)

**Validation:**
- Automated: `terraform fmt -recursive -check && terraform validate && checkov -d . && gitleaks detect --no-git && shellcheck scripts/*.sh`
- Manual: Aravind reads `SPEC.md` and answers unresolved Q1/Q3.

---

### Phase 1 — Cost guardrails (the $0 floor)

**Outcome:** the account cannot silently spend. An AWS Budget with two alerts, a SNS topic, and
an email subscription, plus `scripts/cost-estimate.sh` that prints the monthly delta from the
plan.

**Included:** `bootstrap/` stack on **local state** (S3 state bucket + `use_lockfile`, split
`plan`/`apply` OIDC roles trust-scoped to `github.com/arkhiVd/boutique-platform:environment:*`,
the Budget, the S3 access-log bucket).

**Dependencies and risks:** creates IAM roles and a Budget — a policy change, so it is reviewed
as Risky. The OIDC trust condition is the sharp edge: a wrong `sub` condition is an open door.

**Exit criteria:**
- [ ] `terraform apply` of `bootstrap/` leaves `terraform plan` empty
- [ ] `aws budgets describe-budgets` shows the budget with a `usd` limit and two thresholds
- [ ] A `0.01` test spend is impossible, so instead the alarm is proven by
      `aws cloudwatch describe-alarms --alarm-names <budget-alarm>` returning `INSUFFICIENT_DATA`
- [ ] `scripts/cost-estimate.sh` prints a total within 10% of the SPEC table

**Validation:**
- Automated: `terraform validate`, `checkov -d bootstrap`, plan reviewed line by line
- Manual: Aravind confirms the budget email arrives on a real Budget notification

---

### Phase 2 — Network and node identity

**Outcome:** a VPC built for a public-subnet cluster with no NAT, narrow security groups, and a
least-privilege instance profile with SSM and ECR-pull only.

**Included:** `platform/vpc/` (VPC, 3 AZs, 1 public subnet each, IGW, route tables),
`platform/nodes/iam/` (instance profile + policy), security groups for API / node / edge /
admin.

**Dependencies and risks:** replaces nothing — the default VPC stays untouched and is never
used. `172.31.0.0/16` collides with the default VPC, so the new VPC uses a non-overlapping
CIDR. No cost until Phase 3 instances launch.

**Exit criteria:**
- [ ] `terraform plan` shows a VPC, 3 subnets in 3 distinct AZs, an IGW, and 4 SGs
- [ ] No SG has an ingress rule wider than the operator CIDR on 22/tcp, and no rule on
      22/tcp at all
- [ ] The instance profile policy document contains no `"Resource": "*"` for any action other
      than the explicitly enumerated SSM/ECR/CloudWatch paths — proven by
      `aws iam get-role-policy` output pasted into the PR

**Validation:**
- Automated: `terraform validate`, `checkov -d platform`, plan read line by line
- Manual: `aws ec2 describe-security-groups` pasted for the new VPC

---

## Wave B — Cluster

### Phase 3 — k3s cluster (HA, 3 AZ, SSM-only)

**Outcome:** a real, HA, hardened k3s cluster reachable without SSH, one node per AZ.

**Included:** `platform/nodes/` (launch template, 3 instances, `gp3` encrypted volumes,
k3s install via cloud-init with `--disable traefik` or kept — decided in the phase), the
`INSTALL_K3S_EXEC` config, node labels/taints, `scripts/bootstrap-cluster.sh`,
`scripts/doctor.sh`.

**Dependencies and risks:** **the first cost-bearing apply** (~$90/month for 3 × t3.medium).
The sharp edge is the k3s token and the kubeconfig, which must never land in state or in the
repo. Cloud-init is the only way to keep the token out of the Terraform state.

**Exit criteria:**
- [ ] `kubectl get nodes -o wide` → 3 nodes, 3 distinct AZs, all `Ready`
- [ ] `kubectl drain` of one node keeps the app up (proved in Phase 6, recorded here as the
      cluster's own quorum proof: `etcdctl member list` shows 3 healthy members)
- [ ] `aws ssm start-session --target <instance-id>` works and no key pair exists anywhere in
      the account for these instances — proven by `aws ec2 describe-instances` showing
      `KeyName: null`
- [ ] No kubeconfig, k3s token, or SSM output is present in `terraform.tfstate` or in git —
      proven by `gitleaks detect` and a `terraform show -json | grep -c token` check

**Validation:**
- Automated: `terraform validate`, plan read line by line, `scripts/doctor.sh`
- Manual: `aws ssm start-session` in a browser-visible terminal, pasted

---

### Phase 4 — Cluster policy baseline

**Outcome:** the cluster refuses to run a badly-behaved pod, and every namespace has explicit
guardrails rather than cluster-admin trust.

**Included:** namespaces, `ResourceQuota` and `LimitRange` per namespace, Pod Security
Admission `restricted` on `boutique`/`ci`, default-deny NetworkPolicy **with the DNS egress
carve-out upstream omits**, RBAC (developer / read-only / on-call roles bound to real SSO or
IAM identities), etcd snapshot schedule to S3.

**Dependencies and risks:** `restricted` PSA will reject some upstream manifests — that is the
point, and it forces Phase 6 to fix them. Snapshot IAM is a new policy.

**Exit criteria:**
- [ ] A deliberately unhardened pod (`privileged: true`) is **rejected** by the admission
      controller — proven by a pasted `kubectl run` error
- [ ] A pod with no resource requests is **rejected** by the LimitRange — proven the same way
- [ ] A default-deny pod cannot resolve DNS and an allowed pod can — proven by a pasted
      `kubectl exec` + `nslookup` from both
- [ ] An etcd snapshot exists in S3 and is listed — proven by `aws s3 ls`

**Validation:**
- Automated: `kubeconform` on all manifests, `conftest` policy test, `kubectl auth can-i` matrix
- Manual: the four negative tests above, pasted

---

## Wave C — Edge and workload

### Phase 5 — Two-layer edge: ALB + WAF + Traefik

**Outcome:** the Google production edge shape, reproduced: external ALB terminating TLS with a
WAF and access logs, fronting an in-cluster L7.

**Included:** `platform/edge/` (ALB, 3-AZ target group on Traefik's NodePort, HTTPS listener,
HTTP→HTTPS redirect listener, ACM cert — path per SPEC unresolved Q2, Web ACL with
`AWSManagedRulesCommonRuleSet` + SQLi + known-bad-inputs + a rate-limit rule, access-log bucket
with lifecycle), Traefik config for Host routing on `frontend`, `grafana`, `jenkins`.

**Dependencies and risks:** the ALB is ~$28/month, the single largest optional line. The Web
ACL must be validated in a **non-blocking (count)** mode first, or a false positive takes the
site down.

**Exit criteria:**
- [ ] `curl -sSI https://<host>/` → 200; `curl -sSI http://<host>/` → 301 to the https URL
- [ ] `curl -sSI "https://<host>/?id=1'%20OR%20'1'='1"` → 403 from the Web ACL
- [ ] ALB access logs land in S3 within 5 minutes and contain the request — proven by
      `aws s3 cp` of one log line
- [ ] Grafana and Jenkins host routes resolve through the same ALB with different backends —
      proven by two pasted curl outputs

**Validation:**
- Automated: `terraform validate`, `checkov -d platform/edge`, plan line-by-line
- Manual: the four curl checks pasted; a screenshot of the live site

---

### Phase 6 — Boutique, production-grade

**Outcome:** Online Boutique running with every hardening control Google's *docs* mandate and
its *manifests* omit, plus OTel wiring.

**Included:** upstream `v0.10.7` as a vendored baseline in `apps/boutique/`, plus overlays:
per-service ServiceAccount, `securityContext` (already upstream, extended with
`seccompProfile: RuntimeDefault` and `automountServiceAccountToken: false`), PDB per service,
HPA per service, topology spread across AZs, pod anti-affinity, NetworkPolicy per service
**with the egress DNS carve-out**, ResourceQuota, loadgenerator, OTel env
(`ENABLE_TRACING`, `COLLECTOR_SERVICE_ADDR`, `OTEL_SERVICE_NAME`) per Google's
google-cloud-operations component, and a `config.yaml` for EXTRA_LATENCY chaos.

**Dependencies and risks:** `restricted` PSA and LimitRange from Phase 4 may reject upstream
manifests; this phase fixes them rather than relaxing the policy. This is the phase where the
"utterly better than upstream" claim is either true or not.

**Exit criteria:**
- [ ] All 13 workloads `Available`, pods spread across all 3 AZs — proven by
      `kubectl get pods -n boutique -o wide --sort-by=.spec.nodeName`
- [ ] Draining one node causes **zero** failed loadgenerator requests — proven by a pasted
      `Aggregated` line from before/during/after
- [ ] Every container reports `readOnlyRootFilesystem: true` and a non-root `runAsUser` from the
      live cluster, not the manifest — proven by
      `kubectl get pod -o jsonpath='{.items[*].spec.containers[*].securityContext}'`
- [ ] A NetworkPolicy trace shows `productcatalogservice` accepting only from
      `frontend`/`checkoutservice`/`recommendationservice` and **still resolving DNS** —
      proven by an exec'd `nslookup` from inside the pod
- [ ] `EXTRA_LATENCY=3s` on productcatalogservice produces a visible latency spike in the
      dashboard (Phase 9) — proven by a paired screenshot

**Validation:**
- Automated: `kubeconform`, `conftest` (PSA + securityContext policy), `helm template`/`kustomize build` diff
- Manual: a full checkout journey on screen; the drain test pasted; a screenshot

---

## Wave D — CI/CD

### Phase 7 — Jenkins controller and dynamic agents

**Outcome:** Jenkins that is actually a production CI: configuration as code, ephemeral
Kubernetes agents, secrets outside the repo, and no long-lived workers.

**Included:** Jenkins Helm chart with `persistence` to gp3, JCasC, credentials seeded from a
Kubernetes Secret created out-of-band (never committed), the Kubernetes plugin agent template,
a shared library, RBAC + OIDC login if free, PDB/HPA, backup to S3, and the
`ci` namespace policies from Phase 4.

**Dependencies and risks:** the controller JVM is ~1 GiB and must fit alongside everything else
— this is the phase that decides if `t3.small` was never viable. Credentials seeding is the
single most dangerous step: no credential may be committed.

**Exit criteria:**
- [ ] Jenkins is reachable through the edge host route and configuration is fully described by
      JCasC (`jenkins-cli configuration-as-code:apply` is a no-op on `reload`) — proven by a
      pasted dry-run
- [ ] A build runs on a dynamically provisioned pod that is **gone** after the build — proven
      by paired `kubectl get pods -n ci` outputs
- [ ] `gitleaks detect` is clean and `terraform.tfstate`/`kubectl get secret` outputs are never
      in git — proven by the CI security gate
- [ ] Jenkins restarts and comes back with jobs and config intact (persistence proven) —
      proven by a pasted pod restart + a screenshot

**Validation:**
- Automated: `helm lint --strict`, `helm template` diff, `gitleaks`, `checkov`
- Manual: a real pipeline run, screenshotted

---

### Phase 8 — Pipeline library: build, scan, sign, deploy, promote, roll back

**Outcome:** the CI/CD path that beats Google's, because Google's own release promotion is a
single `kubectl apply` of a static manifest with no rollout controller and no rollback.

**Included:** shared library, `Jenkinsfile` per app, stages: lint/unit → build multi-arch →
`trivy` scan (fail on HIGH/CRITICAL) → SBOM (syft) → cosign sign → push to ECR with
retention policy → deploy to ephemeral `pr-<n>` → smoke gate (Google's zero-errors gate,
extended with a latency ceiling) → approval → canary 10% → burn-rate check → promote or
auto-rollback.

**Dependencies and risks:** needs Phase 6 live for a real deploy target. The canary step needs
either Argo Rollouts or a Traefik weighted service — decided in the phase, recorded in an ADR.
Auto-rollback is the part most likely to be fake; it must be tested by deliberately breaking a
canary.

**Exit criteria:**
- [ ] A PR build runs green through sign and lands in `pr-<n>` with a smoke result — pasted run
- [ ] A deliberately broken build fails at the trivy stage and never reaches ECR — pasted run
- [ ] A canary exposing 3× latency through `EXTRA_LATENCY` is **automatically rolled back** with
      no human step — proven by a pasted Jenkins stage log showing the rollback and the
      subsequent `rollout history`
- [ ] Production deployment is blocked until an explicit approval input — proven by a
      screenshot of the input step and a run where it is denied
- [ ] `terraform plan` after the app layer is empty (manifests are Helm-managed, not TF-managed)

**Validation:**
- Automated: `actionlint` on all workflows; `Jenkinsfile` linted (`jenkins-cli declarative-linter`)
- Manual: the four runs above, each pasted, plus screenshots

---

## Wave E — Observability

### Phase 9 — Metrics: Prometheus, Grafana, Alertmanager

**Outcome:** the four golden signals for every service, plus a dashboard that a stranger can
read without being told what to look at.

**Included:** kube-prometheus-stack, ServiceMonitors for every workload, recording rules for
`job:request_rate`, `job:error_ratio`, `job:latency_p95`, per-service SLO recording rules,
provisioned Grafana dashboards (cluster / app / CI / cost), Alertmanager routing to SNS email,
and the CI pipeline as a monitored system (Jenkins exporter).

**Dependencies and risks:** RAM. Prometheus is the largest single consumer. Cardinality is the
real risk — a mislabeled metric will OOM the box before it fills the disk.

**Exit criteria:**
- [ ] `promtool query instant` returns non-zero request rate and error ratio for all 11 services
- [ ] `promtool check rules` passes; no rule has a syntax error
- [ ] A provisioned dashboard shows request rate, error ratio, p95 latency heatmap, and SLO burn
      for the app in a single screenshot
- [ ] A deliberately broken alert rule fires in Alertmanager and the SNS email arrives — pasted
- [ ] Cardinality is bounded: `scrape_samples_scraped` total × series fit the target, printed
      and explained

**Validation:**
- Automated: `promtool check rules`, `promtool check config`, `helm template` diff
- Manual: the dashboard screenshot; the deliberate alert firing

---

### Phase 10 — Logs: Loki + Fluent Bit

**Outcome:** every workload's logs in one place, queryable, with cardinality and retention under
control rather than exploding.

**Included:** Loki in single-binary mode on gp3, Fluent Bit with structured JSON parsing and
per-namespace label extraction, retention and compaction to a fixed size, a log dashboard, and
a "find the failing checkout in 30 seconds" runbook.

**Dependencies and risks:** label cardinality is the #1 Loki failure. Retention cost is the
#2. Both are bounded by explicit config.

**Exit criteria:**
- [ ] A log line emitted by `productcatalogservice` is retrievable in Grafana Explore within
      60s, with the right namespace/pod/service labels — screenshot
- [ ] `logcli` returns a 500-error trace across three services for a single request ID — pasted
- [ ] Retention is enforced: a log older than the window is gone — proven by two timestamped
      queries
- [ ] Total Loki label cardinality is under an explicit printed threshold

**Validation:**
- Automated: Loki config validated (`loki -config.file=... -verify-config`), `helm template` diff
- Manual: the two queries, pasted

---

### Phase 11 — Traces: OTel Collector gateway + Tempo

**Outcome:** a trace pipeline that is *better than Google's own*, which ships a collector with
**no processors at all** — no `batch`, no `memory_limiter`, no tail sampling.

**Included:** OTel Collector gateway with `batch`, `memory_limiter`, `resourcedetection`
(EC2 attributes), tail sampling (errors + slow + a probability sample), Prometheus span-metrics
generation, Tempo backend, a service-graph dashboard, and the per-service OTel env wiring from
Google's google-cloud-operations component, extended to `adservice` which upstream comments out
as "not yet implemented" (and to Java via the OTel Java agent).

**Dependencies and risks:** memory. The collector and Tempo add ~1 GiB. Tail sampling raises
tail latency — bounded explicitly.

**Exit criteria:**
- [ ] A checkout request produces a trace spanning `frontend → checkoutservice → paymentservice`
      in Tempo, retrievable by trace ID — proven by a pasted Tempo API query
- [ ] The Tempo service graph renders dependencies — screenshot
- [ ] Red metrics (`traces_spanmetrics_*`) appear in Prometheus from the collector's
      spanmetrics connector, and error spans are counted — pasted `promtool query instant`
- [ ] An injected `EXTRA_LATENCY=3s` span appears as an outlier in the trace waterfall — screenshot
- [ ] `adservice` spans exist (upstream has none) — proven by a trace query filtered to
      `service.name=adservice`

**Validation:**
- Automated: collector config validated (`otelcol-contrib validate --config`), `helm template` diff
- Manual: the trace query and the waterfall screenshot

---

### Phase 12 — SLOs, error budgets, and alerting that does not cry wolf

**Outcome:** usability alerts, not nine-nines decoration. This is the piece Google's app repo
does not have at all, so the bar here is the SRE Workbook, not the demo.

**Included:** SLI definitions per service (availability + latency), SLO objects, multiwindow
multi-burn-rate alerts (2% of budget in 1h, 5% in 6h, 10% in 3d), a written error-budget policy
in the style of the SRE Workbook Appendix B, an `sre-error-budget` dashboard, and a synthetic
probe (blackbox exporter) measuring from outside the cluster.

**Dependencies and risks:** an SLO nobody trusts is worse than none. Every SLO's numerator and
denominator are written down and checkable.

**Exit criteria:**
- [ ] Three SLOs documented with explicit numerator, denominator, window, and target, each with
      the PromQL that computes it
- [ ] A deliberate 100% error injection fires the 2%-in-1h page **and not** the 5%-in-6h page —
      proven by pasted Alertmanager output showing exactly the intended routes
- [ ] A 1-in-20 error rate for 10 minutes does **not** page (noise immunity test) — pasted
- [ ] The error-budget policy document names the stop-shipping action and the postmortem trigger

**Validation:**
- Automated: `promtool check rules` on the SLO rules; `promtool test rules` with a synthetic
      series that must and must not alert
- Manual: the pasted Alertmanager output for both tests

---

## Wave F — Operational clarity

### Phase 13 — Runbooks, DR drills, and the evidence pack

**Outcome:** the thing that turns a demo into an operation: a `doctor.sh`, runbooks that name
commands that were actually run, and a packed set of evidence so the claim survives the cluster
being deleted.

**Included:** `scripts/doctor.sh`, runbooks for node loss / etcd restore / rollback / Jenkins
agent stall / cert expiry / cost spike / Loki full / Prometheus restart, a DR drill that
restores an etcd snapshot into a scratch namespace and is timed, `docs/adr/` with the real
decisions (EKS vs k3s, ALB vs node-IP entry, mesh mTLS gap, canary mechanism), and the
`docs/evidence/` pack.

**Dependencies and risks:** the DR drill must not run against the live cluster's etcd.

**Exit criteria:**
- [ ] `scripts/doctor.sh` exits 0 healthy and non-zero with a specific reason when a node is
      drained — pasted both runs
- [ ] The etcd restore drill completes and the restored cluster serves the app — pasted, timed
- [ ] Every runbook has a "Last verified" date and the command it claims actually exists —
      verified by a script that runs every fenced command in `docs/runbooks/` with `--dry-run`
      or in a scratch namespace
- [ ] `docs/evidence/` contains, per phase: the pasted command output, the screenshots, and the
      plan summaries — a checklist indexed from the README

**Validation:**
- Automated: a link checker for internal doc references; the runbook command dry-run script
- Manual: Aravind reads the evidence index and can find every acceptance criterion's proof

---

### Phase 14 — Release readiness

**Outcome:** the PR Aravind can put in front of an interviewer.

**Included:** security scans clean, Dependabot current, all CI required checks green on the
latest commit, docs matching behavior, the rollback/destroy path tested, the real-environment
manual test documented, and the final teardown executed so the account returns to $0.

**Exit criteria (the project-dev §7 merge gate, verbatim):**
- [ ] diff contains only the intended change, no debug code, no generated junk, no secrets
- [ ] CI green on the latest commit
- [ ] independent review complete, actionable threads resolved
- [ ] SPEC/ROADMAP/TASKS match what was built
- [ ] docs/README/changelog match the new behavior
- [ ] manual test done in the real target environment, documented in the PR
- [ ] visible changes checked on screen, screenshots attached
- [ ] for IaC: `terraform plan` empty after apply, cost delta understood, rollback known,
      destroys/replacements expected
- [ ] `destroy.yml` executed; `aws ce get-cost-and-usage` returns $0.00 for the following week

**Validation:**
- Automated: everything above
- Manual: the teardown bill check, pasted

---

## Dependency graph (what can move in parallel)

```
Phase 0 ─┬─ Phase 1 ─┬─ Phase 2 ─┬─ Phase 3 ─┬─ Phase 4 ─┬─ Phase 5 ─┬─ Phase 6 ─┬─ Phase 8 ─┐
         │           │           │           │           │           │           └─ Phase 7 ┘
         │           │           │           │           │           └────────────────────────┐
         │           │           │           │           └─ Phase 9 ─┬─ Phase 10 ─┬─ Phase 11 ┼─ Phase 12
         │           │           │           │                       └────────────┘           │
         │           │           │           └─────────────────────────────────────────────────┘
         └─ docs/adr (any time, no cluster needed)
                                    Phase 13 needs 6-12; Phase 14 needs everything.
```

Phases 9–11 are independent of each other once Phase 4 is done and can be built and judged by
three parallel critics against three independent baselines (Prometheus/Loki/Tempo upstream
conventions, not each other). Phases 1–5 are strictly sequential — each provisions on the
previous.
