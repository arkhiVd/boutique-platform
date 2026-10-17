# boutique-platform — tasks

## Current phase: 14 — release readiness (2026-10-18)

Phases 0–13 are applied and live; Phase 13 (runbooks, DR drills, evidence pack) is on
`feat/phase-13-operations`. The open items are no longer here: each unproven exit
criterion is listed, with its reason, in `docs/evidence/README.md`, and the dated
results are in `PROGRESS.md`. What remains for Phase 14 is the release gate and the
teardown to $0, which needs Aravind's approval in-session (ROADMAP "Approval gates").

The sections below are the Phase 3–4 record, kept as history: their "not applied"
statements describe 2026-10-09, before the first apply.

## What is proven, and by what

| Phase | What landed | Proven by |
|---|---|---|
| 3 | `platform/nodes.tf` — KMS CMK + alias, 2 launch templates, 3 servers (one per AZ) + 1 worker, the join-token SSM parameter written write-only, the leader-address parameter, `platform/cluster-bootstrap.sh` (cloud-init) and `platform/etcd-snapshot.sh`; `scripts/bootstrap-cluster.sh` (SSM kubeconfig, never in git) and `scripts/doctor.sh` (11 checks, one verdict) | `terraform -chdir=platform plan`: **58 to add, 0 to change, 0 to destroy**; `checkov -d platform`: **160 passed, 0 failed, 4 skipped (all with reasons)**; `tflint` clean; `shellcheck -x` + `bash -n` clean on 4 new scripts; the rendered user_data passes `bash -n` on the node; `grep -c <token>` = **0** in the plan text, the plan JSON and the saved plan file; `scripts/check.sh`: **103 PASS / 0 FAIL / 0 MISSING** |
| 4 | `platform/etcd-backup.tf` (snapshot bucket: CMK, public-access-block, versioning, TLS-deny policy, lifecycle expiry), `cluster/rbac/` (4 ClusterRoles + 4 bindings, all group-based), `cluster/policies/` (4 add-on PDBs, the `boutique` default-deny with the DNS carve-out, `observability` + `ci` quotas and LimitRanges with the arithmetic), `cluster/priority.yaml`, `scripts/etcd-restore-drill.sh` | `kubeconform -strict -kubernetes-version 1.36.3 cluster/policies/`: **9 valid / 0 invalid**; `conftest test cluster/policies/ -p policy/`: **198 passed, 0 failures**; the drill's two guard rails (no `TARGET=cluster-live` without `LIVE_ACK=yes`; no write under `/var/lib/rancher/k3s`) exercised against a stubbed environment |
| 7 and 8 | **CI/CD, on `feat/cicd`, merged to `main`.** `ci/jenkins/` wrapper chart on `jenkins/jenkins` 5.9.68 — JCasC, eleven plugin pins, the kubernetes agent pod template with its `dind` sidecar, PVC, priority class; `ci/rbac/` (SA `jenkins`, Role, RoleBinding, SA `jenkins-agent`, and the `boutique` RoleBinding that lets an agent deploy an app); `ci/backup/cronjob.yaml`; `policy/ci.rego` (namespace profiles, so `ci` and `observability` run `baseline` and everything else stays `restricted`); `pipelines/` shared library (9 `vars/` steps + 3 shell resources); the root `Jenkinsfile` (12 gates, 6 stages); `ci/jenkins/README.md`, `docs/runbooks/ci.md` | `helm lint --strict` clean; `helm template ci ci/jenkins` → `StatefulSet ci` only — the ServiceAccount/Role/RoleBinding come from `ci/rbac/` and the CronJob from `ci/backup/` by design, so the rendered grep shows one kind and the source grep shows six files; `kubeconform -strict` **6/6 valid** on the non-chart files (the literal `kubeconform … ci/` exits 1 on `Chart.yaml`/`values.yaml` with "missing 'kind' key" — check.sh filters exactly those); `conftest test ci/` **144 passed**; policy A/B old-vs-new over apps+cluster+ci+observability **2430 tests, byte-identical output**, `--combine` identical, all 3 fixtures identical exit codes; `shellcheck -x` + `bash -n` clean; `actionlint` clean; `gitleaks` clean; **11 plugin pins HTTP 200** from `updates.jenkins.io/download/plugins`; all **12 Jenkinsfile gates green** in their pinned containers (same `docker run` shape as `vars/tools.groovy`); `scripts/check.sh` **127 PASS / 0 FAIL / 0 MISSING** |
| 0 | SPEC / ROADMAP / AGENTS / TASKS, `scripts/check.sh`, `scripts/cost-estimate.sh`, ADRs 0001–0003, CI plan gate | `check.sh` 0 FAIL; gitleaks clean; actionlint clean |
| 1 | `bootstrap/` — state bucket, split OIDC plan/apply roles, AWS Budget, SNS alerts | `terraform validate`, `plan: 14 to add, 0 to change, 0 to destroy`, `checkov 70 passed 0 failed 6 skipped` |
| 2 | `platform/` — VPC `10.90.0.0/16`, 3 public subnets, 4 security groups, narrow node instance profile | `plan: 42 to add, 0 to change, 0 to destroy`, `checkov 103 passed 0 failed`, `tflint` clean |
| 6 | `apps/boutique/` — upstream v0.10.7 vendored verbatim with provenance; all 13 workloads hardened (PDB, HPA, topology spread, anti-affinity, `seccompProfile`, `automountServiceAccountToken: false`, CPU requests == limits, `startupProbe`); `netpol/` with the kube-dns carve-out upstream omits; `policy/` rego + 3 failing fixtures; OTel collector with real processors | `kustomize build` 3033 lines; `kubeconform` 136/136 valid; `conftest` 1044/1044 pass, 22/22 fixtures rejected; `gitleaks` clean |
| 9 | `observability/kube-prometheus-stack/` on chart `92.1.1`; golden-signal recording rules; alerts; 4 dashboards; ServiceMonitors | `helm lint --strict` 0 failed; `promtool check rules` 9 rules |
| 10 | Loki `SingleBinary` with **enforced** 168h retention; Fluent Bit parsers for all six real log formats and a Loki output with exactly 3 labels | `promtool check rules` 4 rules; `scripts/check-fluentbit-config.py` runs the render through `fluent-bit --dry-run` in the pinned image |
| 12 | SLOs 99.9% / 99% with multiwindow multi-burn-rate (14.4x / 6x / 1x); `docs/slo.md`; burn-rate fixtures | `promtool test rules` → **SUCCESS**: the 14.4x page fires, the 6x and 1x do not, and a 1-in-20-for-10-min blip does not page |
| 11 | `observability/tempo/` (single binary on gp3, chart `grafana/tempo` **1.24.4 / app 2.9.0**, metrics-generator on service-graphs only), collector `spanmetrics` connector fed by a second pre-sampling `traces/spanmetrics` pipeline, `traces_spanmetrics_*` recording rules + `TracesSpanmetricsMissing`, `traces` Grafana dashboard, `docs/runbooks/traces.md`, remote-write receiver on Prometheus and the `tempo` datasource | `helm lint --strict` 0 failed; `helm template` render → `kubeconform -strict -kubernetes-version 1.36.3` **6/6 valid** (incl. PrometheusRule/ServiceMonitor via the CRD catalog); `promtool check rules` **5 rules** in `observability/rules/spanmetrics.yaml` + 3 in `tempo/alerts.yaml`; `conftest test <rendered tempo>` **108/108**; `otelcol-contrib v0.160.0 validate` **rc=0** on the extracted collector config; `scripts/check-dashboards.py` parses `traces.yaml`; budget recomputed **210.4% CPU / 125.3% RAM** (was 196.7% / 108.2%) |

## Blockers

| Item | Waiting on |
|---|---|
| Phase 3 first apply | Aravind's approval — it is the first cost-bearing apply (~$61/mo) |
| Phase 3 cluster-dependent exit criteria | `kubectl get nodes -o wide` (4 nodes, 3 AZs, all Ready), `KeyName: null` on `describe-instances`, `terraform show -json | grep -c token`, the drain/quorum test — all need a live cluster |
| Phase 4's live negative tests | a rejected privileged pod, a request-less pod rejected by the LimitRange, DNS failing from a denied pod, `aws s3 ls` of a real snapshot |
| Phase 1/2 apply | Aravind's approval — the state bucket does not exist yet, and the Phase 2 apply is an IAM change (Risky class) |
| Phase 5 ALB + Web ACL | SPEC Q3 — the ALB decision |
| Phase 6 drain test (`zero failed requests`) | A schedulable node to drain to. **Root cause now identified and fixed: the workload-node taint.** See U1 |
| Phase 6 collector `debug` → Tempo | **Resolved on this branch (Phase 11):** the collector's `traces` pipeline now ends at `otlp/tempo` (debug exporter removed), so traces land in Tempo instead of being logged. What still needs the live cluster: one checkout trace actually readable through `/api/traces/<id>` — see `docs/runbooks/traces.md` and U13 |
| adservice / shippingservice tracing | `docs/adr/0004-adservice-tracing-gap.md` — a pinned OTel Java agent, and where its temp dir lives under `readOnlyRootFilesystem: true` |
| k3s Traefik histogram buckets | Phase 5 — Traefik's defaults (0.1/0.3/1.2/5.0) make the p95 latency SLI resolve to one of four values |
| External probe target | Phase 5 Terraform output |
| Phase 7 controller boot, JCasC apply, agent pods | a cluster — `kubectl apply` and `helm install` are not run by this phase, and nothing in it proves the controller starts |
| Phase 7 backup end to end | the S3 snapshot bucket (Terraform, not applied) and Secret `jenkins-backup-credentials` |
| Phase 8 image build, SBOM, sign, push | no `Dockerfile` in this repository, no `aws_ecr_repository` anywhere in Terraform, no cosign key |
| Phase 8 ephemeral `pr-<n>` preview namespaces | a grant outside `boutique`; `deployToStaging(prNumber: …)` fails with that sentence rather than applying to a namespace that does not exist |
| Phase 8 smoke gate, canary, promotion | a deployed application — this repository deploys none of its own, so each stage is wired and unexercised |

## Decisions taken in-session (SPEC unresolved questions, now resolved)

| # | Was | Now | Consequence |
|---|---|---|---|
| Q1 | node shape | **4 × t3.small (3 servers + 1 worker), all four nodes schedulable** | decided as `3 × t3.small + 1 × t3.medium`; the apply measured that t3.medium is not free-tier eligible in this account, so the shape became four equal nodes — see U1 and PROGRESS.md |
| Q2 | TLS path | `<host>.ip.sslip.io` + cert-manager HTTP-01 | no Route 53 zone exists; gives a real public CA chain |
| Q3 | ALB | ALB + WAF, then full teardown at Phase 14 | two-layer edge, $28/mo of the budget |
| Q4 | Jenkins placement | in-cluster, on the schedulable pool | a separate node would be the 5th instance and the 9th vCPU — impossible |
| U8/U9 | systemd watchdog / kubelet read-only port | **watchdog OFF, read-only port confirmed OFF** | both settled from the k3s source and issue tracker rather than from convention |
| U10 | the join token | **ephemeral variable → write-only `value_wo` on a SecureString** | keeps it out of the plan, the plan file and the state; costs the requirement that every Terraform command supplies one |

## Unknowns recorded rather than guessed

| # | Unknown | Measured value | What it blocks |
|---|---|---|---|
| U1 | **Node budget: 3850m CPU / 4688Mi of requests against one workload node's 1830m / 3741Mi schedulable = 210.4% CPU, 125.3% RAM.** 2820m of it is `boutique`; Phase 11 added 250m/512Mi (Tempo) and took the collector from 128Mi to 192Mi per replica (was 3600m / 4048Mi = 196.7% / 108.2% before it). | `docs/resource-budget.md` | nothing any more — resolved by making all four nodes schedulable (4 × 1830m = 7320m, ~9042Mi). Recorded here because it is the reason Phase 3 must **not** taint the k3s servers. |
| U2 | **A t3 instance is burstable at a 20% baseline ≈ 400m sustained**, not 2000m. Requests are not the binding limit — sustained CPU is. | `docs/resource-budget.md` | modelled in `scripts/cost-estimate.sh` as a CPU-credit surcharge guard. Light demo traffic should stay under baseline; sustained load is the risk. |
| U3 | Shippingservice / adservice tracing | both `initTracing()` bodies are upstream TODOs (issue #422) | Phase 11 trace completeness |
| U4 | cartservice instrumentation | none upstream, not a stub, never built | the checkout trace has a hole |
| U5 | `OTEL_TRACES_SAMPLER*` | inert for the six instrumented images; they hard-code `AlwaysSample()` | nothing — real sampling is the collector's `tail_sampling` |
| U6 | `redis:alpine` digest | `sha256:3811787313eb…` resolved from the registry, not guessed | re-resolve when the image is rebuilt |
| U7 | Startup-probe budgets | 60s Go/Python/JS, 90s JVM/.NET — chosen, not measured | the first real run should confirm 90s is enough and not more |
| U8 | **The systemd watchdog must NOT be enabled for k3s.** k3s unsets `NOTIFY_SOCKET` immediately after `READY=1`, so the kubelet's watchdog goroutine (upstream since 1.35) cannot feed it and systemd kills the service at the timeout. k3s-io/k3s#13725, maintainers declined to fix. | k3s source + upstream Kubernetes docs | nothing — the drop-in carries accounting only, and liveness is `Restart=always` plus `scripts/doctor.sh` |
| U9 | **The k3s read-only port is 10255 OFF by k3s's own construction**, not by this repo's configuration: `pkg/daemons/agent/agent_linux.go` builds `argsMap["read-only-port"] = "0"` with a comment saying the structured config drops a zero. | k3s source | nothing — and no security-group rule mentions 10255 anywhere in Phase 2 |
| U10 | **An ephemeral variable cannot have a default.** Every `terraform plan`/`apply` in `platform/` must be handed `TF_VAR_k3s_token`, including CI. | verified: `terraform plan` stops with "No value for required variable" | recorded as the operational cost of the write-only token design; CI now passes a fixed non-secret string that never reaches AWS |
| U11 | **Two nodes may land in `us-east-1c`.** The worker is placed in `local.azs[2]` so every AZ holds at least one node; the SPEC's one-per-AZ contract is about the control plane. | SPEC scheduling model | if a reviewer wants a strict spread, the worker moves to `local.azs[1]` for $0 |
| U12 | **The etcd snapshot timer writes from the leader only, and retention is S3 lifecycle rather than k3s.** `--etcd-s3-retention` is a *server* flag that the on-demand CLI path does not set. | k3s docs, `k3s etcd-snapshot` reference | 30-day expiry is enforced by the bucket rule; a k3s-native retention would need the flags on the server process instead |
| U13 | **Phase 11's traces layer is proven from sources, renders and the pinned binaries, not from a cluster.** Every metric/label name in the rules and dashboard was checked against grafana/tempo@v2.9.0 and otelcol-contrib v0.160.0 source, and every manifest passed its gate, but no span has actually traversed collector → Tempo → Grafana. Two specific claims are unverified by construction: that Tempo's `readOnlyRootFilesystem` has no unwritten runtime path in a real pod (the runbook has the `/tmp` footgun named), and that the remote-write URL `kube-prometheus-stack-prometheus.observability.svc:9090/api/v1/write` — derived from the repo's `release: kube-prometheus-stack` selector convention, not observed — matches the release name actually installed. | the validation outputs in this phase's PROGRESS section | the Phase 13 evidence pack: a checkout trace read via `curl :3200/api/traces/<id>`, a rendered service graph, and `TracesSpanmetricsMissing` staying silent for 15m |

## Completed

- 2026-10-08 Phase 0 — scaffold from live account evidence (`aws sts get-caller-identity`,
  `describe-vpcs`, `describe-security-groups`, `describe-instance-types`, quota checks,
  `ce get-cost-and-usage`) and from the real `GoogleCloudPlatform/microservices-demo` `v0.10.7`.
  Validated by inspection; no infrastructure touched.
- 2026-10-09 Phase 1, `bootstrap/` — the S3 state bucket
  `boutique-platform-tfstate-<account>-us-east-1` (versioning, SSE-S3, all four
  public-access-block flags, noncurrent versions expired at 30 days), the GitHub Actions OIDC
  provider for `token.actions.githubusercontent.com`, the split `boutique-platform-plan`
  (read-only) and `boutique-platform-apply` roles sharing one trust policy, the AWS Budget
  `boutique-platform-monthly` at $30 with 50% and 80% forecast alerts, and the
  `boutique-platform-alerts` SNS topic with its email subscription. Validated by
  `terraform plan` (14 to add), `validate`, `fmt -check -recursive`,
  `checkov -d bootstrap` (69 passed, 0 failed, 6 skipped with reasons),
  `tflint --recursive`, and `gitleaks detect --no-git`. Residual risk: no apply has run.
- 2026-10-09 Phase 2, `platform/` — VPC `10.90.0.0/16`, three public subnets in
  `us-east-1a/b/c` with the Cloud Controller Manager and ELB subnet tags, IGW plus a
  `0.0.0.0/0` route, `AmazonProvidedDNS` DHCP options, four security groups and 21 standalone
  `aws_security_group_rule` resources, and the `boutique-platform-node` instance profile whose
  inline policy is SSM, ECR-pull, CloudWatch, one S3 prefix and one SSM parameter. Validated by
  `terraform plan` (42 to add), `validate`, `fmt -check -recursive`,
  `checkov -d platform` (103 passed, 0 failed), `tflint --recursive`, `scripts/check.sh`
  (0 FAIL), and `gitleaks detect --no-git`. Residual risk, recorded rather than hidden: no
  `terraform apply` has been run for either stack, so the plan line is the proof and not the
  applied result; VPC flow logs are off for cost; the ALB-to-NodePort rule lands in Phase 5;
  the etcd snapshot bucket is created in Phase 4.
- 2026-10-09 Phase 6, 9, 10, 12 — manifest and observability layers, on `feat/app-hardening` and
  `feat/observability-metrics-logs`, merged here. See the table above.
- 2026-10-09 Phase 3 and 4 on `feat/cluster`. `platform/` was first merged in from
  `feat/infra-bootstrap-vpc` (it was never on this branch, and a second copy of the network stack
  is two clusters of drift waiting to happen), unchanged except for the node-role policy
  extensions Phase 3 needed. Phase 3 then added the cluster: 4 instances behind 2 launch templates,
  one CMK, the write-only join-token parameter, and the cloud-init that installs k3s from an IMDS
  token, an SSM token read with the instance role, and an AZ-derived leader election. Phase 4 added
  the snapshot bucket and timer, the RBAC, the PDB/NetworkPolicy/quota/LimitRange baseline, and
  the restore drill. Validated by plan (58 to add / 0 to change / 0 to destroy), checkov
  (160 passed, 0 failed, 4 skipped with reasons), tflint, shellcheck, kubeconform (9 valid),
  conftest (198 passed), gitleaks, and `scripts/check.sh` at 103 PASS / 0 FAIL / 0 MISSING.
  **Nothing has been applied.** Every cluster-dependent exit criterion is in the blockers table.
- 2026-10-14 Phases 7 and 8 on `feat/cicd`, merged to `main`. The Jenkins controller as a wrapper
  chart (`ci/jenkins/`, 5.9.68 pinned, `installLatestPlugins: false` with eleven pins whose
  versions each return HTTP 200 from the Jenkins update center), the identity it runs as
  (`ci/rbac/`, five files, no `secrets` verb, agent deploy granted in `boutique` only), the daily
  PVC→S3 backup (`ci/backup/cronjob.yaml`, fails loudly while the bucket does not exist), the
  namespace profile in `policy/ci.rego` that lets `ci` keep a token mount without loosening
  `boutique`, the shared library (`pipelines/`, 9 steps + 3 shell resources, every tool image
  pinned), the root `Jenkinsfile` (12 gates that mirror `scripts/check.sh`, then
  build/scan/deploy/smoke/canary-with-auto-rollback/promote), and the two documents an operator
  needs (`ci/jenkins/README.md`, `docs/runbooks/ci.md`). Proven by the ten validations in the
  table above, by the policy A/B (2430 tests, byte-identical old-vs-new), and by running all
  twelve gates in their pinned containers on this machine. **Nothing is deployed, nothing is
  merged, and every cluster-dependent claim is in the blockers table.**

- 2026-10-14 Phase 11 on `feat/traces` — the traces layer. `observability/tempo/` (single
  binary on a 10Gi gp3 claim, chart `grafana/tempo` 1.24.4 / app 2.9.0, metrics-generator on
  `service-graphs` only — spanmetrics belongs to the collector, never both — remote-write into
  Prometheus), the collector's `spanmetrics` connector fed by a second `traces/spanmetrics`
  pipeline that deliberately bypasses `tail_sampling` so the error ratio is not biased, the
  `span:*` recording rules and `TracesSpanmetricsMissing`, the `traces` dashboard (ConfigMap
  form), Prometheus's remote-write receiver plus the `tempo` datasource, and
  `docs/runbooks/traces.md`. Validated by `helm lint --strict` (0 failed), the render through
  `kubeconform -strict` (6/6), `promtool check rules` (5 + 3 rules), `conftest` on the render
  (108/108 — the CPU-limit rule caught the first Tempo values, fixed rather than waived),
  `otelcol-contrib v0.160.0 validate` rc=0 (it rejected the pre-0.130 `address` key; the config
  now uses `readers`), the dashboard parser, and `scripts/check.sh` at 0 FAIL. Nothing applied;
  the live end-to-end claims are recorded as U13 rather than marked done.

## Residual risk for Phase 3 and 4, recorded rather than hidden

| # | Risk | Why it is not closed here |
|---|---|---|
| R1 | **The join-token design is proven from the provider source, not from an applied state.** The two facts it rests on — Terraform refusing ephemeral values in normal attributes, and the AWS provider nulling `value` when `has_value_wo` — are verified from the tooling and from `hashicorp/terraform-provider-aws@v6.68.0`'s read path. The plan-level evidence (0 hits for the token in the text, the JSON and the saved plan file) is measured. What is NOT measured is `terraform show -json` after an apply, which needs the apply. | the apply is Aravind's gate |
| R2 | **Cloud-init's node behaviour is unexercised.** The script is `bash -n` and `shellcheck` clean in both its source and its rendered form, and the embedded etcd script is checked the same way. No node has booted, so the leader-election-by-AZ, the SSM polling, the k3s install flags and the drop-in are unrehearsed. | no cluster |
| R3 | **The RBAC binds to Groups with no IdP.** That is deliberate (see the header of `cluster/rbac/rbac.yaml`), but it means the developer role grants nobody until Phase 8 wires GitHub OIDC. An interviewer reading the repo should see this as a stated gap, not a pretend binding. | no IdP exists |
| R4 | **The restore drill's scratch restore is exercised against a stubbed `etcdctl` and `aws`, not against a real snapshot.** The guard rails and the timing/verdict reporting are proven; the actual restore of a real 5–10 MB etcd snapshot is not. | no cluster, no snapshot bucket |
| R5 | **Two cost lines the SPEC's table does not carry**: the CMK at $1.00/mo and detailed monitoring at $0.30 per instance per month ($1.20/mo for four instances) = **+$2.20/mo, $3.13 over the 43-day window**. `scripts/cost-estimate.sh` still prints the SPEC's shape and total; the delta is here, not silently absorbed. | the SPEC's cost table is the Phase 0 contract and was left alone |
| R6 | **`terraform plan` after an apply is not proven empty.** The usual drift sources are handled: `ignore_changes` covers the tags a cloud controller would add plus `tags_all`, the launch template is not force-newed by a user_data edit, and `metadata_options`/monitoring/volumes are repeated identically on the instance where EC2 honours them. `user_data`'s base64 read-back encoding is the one thing that could produce a perpetual diff and it can only be settled by applying. | no apply |
| R7 | **The k3s installer script is fetched over TLS and not digest-pinned.** The artefact it installs is pinned by `INSTALL_K3S_VERSION`. | recorded in `platform/README.md` |

## Residual risk for Phases 7 and 8, recorded rather than hidden

| # | Risk | Why it is not closed here |
|---|---|---|
| R8 | **The `dind` sidecar is the one privileged container on the platform, and it is untested.** `privileged: true` is root on the node host with every capability, inside a pod that runs arbitrary build steps. The alternative the roadmap names (kaniko, userspace builds) is not installed and would need its own pin. | no cluster |
| R9 | **The agent pod's own spec lives inside a ConfigMap the Kubernetes plugin renders, so `conftest` never sees it.** The controller's resources are policy-checked; the agent's are not — the values are right today and nothing enforces that they stay right. | plugin behaviour |
| R10 | **The `ci` namespace has no manifest.** `cluster/policies/` references it (quota, LimitRange) but nothing creates it; `ci/jenkins/README.md` carries the `kubectl create namespace ci` step instead. | the phase did not extend `cluster/` |
| R11 | **A pinned tag is not a digest.** Every tool image in `pipelines/vars/toolImages.groovy` was checked against its registry's tag API (2026-10-14), and trivy is deliberately matched to the laptop's 0.69.3 — but a re-pointed tag or a new check bundle changes CI first and the laptop second. | inherent to tag pinning |
| R12 | **The backup job and the promotion path depend on things that do not exist yet** (the S3 bucket, a cosign key, an ECR repository). Both are written to fail loudly rather than to skip quietly; until those exist, the failure is the feature. | see the blockers table |

Move a task here only after its acceptance criteria and validation passed. Record skipped
validation and residual risk instead of marking incomplete work done.
