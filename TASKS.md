# boutique-platform — tasks

## Current phase: 3 — cluster bootstrap (being built on this branch)

Phases 0, 1 and 2 are built and planned but **not applied**: the apply is Aravind's gate, and the
state bucket the `platform/` stack stores state in does not exist until that one-time bootstrap
apply runs. Everything in this file is proven by `terraform plan`, `kustomize build`,
`helm template`, `promtool`, `kubeconform`, `conftest` and `shellcheck`. Nothing is deployed, and
no `kubectl apply` has been run anywhere. Cluster-dependent exit criteria are named in the
blockers table rather than marked done.

## What is proven, and by what

| Phase | What landed | Proven by |
|---|---|---|
| 0 | SPEC / ROADMAP / AGENTS / TASKS, `scripts/check.sh`, `scripts/cost-estimate.sh`, ADRs 0001–0003, CI plan gate | `check.sh` 0 FAIL; gitleaks clean; actionlint clean |
| 1 | `bootstrap/` — state bucket, split OIDC plan/apply roles, AWS Budget, SNS alerts | `terraform validate`, `plan: 14 to add, 0 to change, 0 to destroy`, `checkov 70 passed 0 failed 6 skipped` |
| 2 | `platform/` — VPC `10.90.0.0/16`, 3 public subnets, 4 security groups, narrow node instance profile | `plan: 42 to add, 0 to change, 0 to destroy`, `checkov 103 passed 0 failed`, `tflint` clean |
| 6 | `apps/boutique/` — upstream v0.10.7 vendored verbatim with provenance; all 13 workloads hardened (PDB, HPA, topology spread, anti-affinity, `seccompProfile`, `automountServiceAccountToken: false`, CPU requests == limits, `startupProbe`); `netpol/` with the kube-dns carve-out upstream omits; `policy/` rego + 3 failing fixtures; OTel collector with real processors | `kustomize build` 3033 lines; `kubeconform` 136/136 valid; `conftest` 1044/1044 pass, 22/22 fixtures rejected; `gitleaks` clean |
| 9 | `observability/kube-prometheus-stack/` on chart `92.1.1`; golden-signal recording rules; alerts; 4 dashboards; ServiceMonitors | `helm lint --strict` 0 failed; `promtool check rules` 9 rules |
| 10 | Loki `SingleBinary` with **enforced** 168h retention; Fluent Bit parsers for all six real log formats and a Loki output with exactly 3 labels | `promtool check rules` 4 rules; `scripts/check-fluentbit-config.py` runs the render through `fluent-bit --dry-run` in the pinned image |
| 12 | SLOs 99.9% / 99% with multiwindow multi-burn-rate (14.4x / 6x / 1x); `docs/slo.md`; burn-rate fixtures | `promtool test rules` → **SUCCESS**: the 14.4x page fires, the 6x and 1x do not, and a 1-in-20-for-10-min blip does not page |

## Blockers

| Item | Waiting on |
|---|---|
| Phase 3 first apply | Aravind's approval — it is the first cost-bearing apply (~$61/mo) |
| Phase 1/2 apply | Aravind's approval — the state bucket does not exist yet, and the Phase 2 apply is an IAM change (Risky class) |
| Phase 5 ALB + Web ACL | SPEC Q3 — the ALB decision |
| Phase 6 drain test (`zero failed requests`) | A schedulable node to drain to. **Root cause now identified and fixed: the workload-node taint.** See U1 |
| Phase 6 collector `debug` → Tempo | Phase 11 (Tempo does not exist yet) |
| adservice / shippingservice tracing | `docs/adr/0004-adservice-tracing-gap.md` — a pinned OTel Java agent, and where its temp dir lives under `readOnlyRootFilesystem: true` |
| k3s Traefik histogram buckets | Phase 5 — Traefik's defaults (0.1/0.3/1.2/5.0) make the p95 latency SLI resolve to one of four values |
| External probe target | Phase 5 Terraform output |

## Decisions taken in-session (SPEC unresolved questions, now resolved)

| # | Was | Now | Consequence |
|---|---|---|---|
| Q1 | node shape | **3 × t3.small servers + 1 × t3.medium workload node**, and **all four nodes schedulable** | the only shape that fits; see U1 |
| Q2 | TLS path | `<host>.ip.sslip.io` + cert-manager HTTP-01 | no Route 53 zone exists; gives a real public CA chain |
| Q3 | ALB | ALB + WAF, then full teardown at Phase 14 | two-layer edge, $28/mo of the budget |
| Q4 | Jenkins placement | in-cluster, on the schedulable pool | a separate node would be the 5th instance and the 9th vCPU — impossible |

## Unknowns recorded rather than guessed

| # | Unknown | Measured value | What it blocks |
|---|---|---|---|
| U1 | **Node budget: 3600m CPU / 4048Mi of requests against one workload node's 1830m / 3741Mi schedulable = 196.7% CPU, 108.2% RAM.** 2820m of it is `boutique`. | `docs/resource-budget.md` | nothing any more — resolved by making all four nodes schedulable (4 × 1830m = 7320m, ~9042Mi). Recorded here because it is the reason Phase 3 must **not** taint the k3s servers. |
| U2 | **A t3 instance is burstable at a 20% baseline ≈ 400m sustained**, not 2000m. Requests are not the binding limit — sustained CPU is. | `docs/resource-budget.md` | modelled in `scripts/cost-estimate.sh` as a CPU-credit surcharge guard. Light demo traffic should stay under baseline; sustained load is the risk. |
| U3 | Shippingservice / adservice tracing | both `initTracing()` bodies are upstream TODOs (issue #422) | Phase 11 trace completeness |
| U4 | cartservice instrumentation | none upstream, not a stub, never built | the checkout trace has a hole |
| U5 | `OTEL_TRACES_SAMPLER*` | inert for the six instrumented images; they hard-code `AlwaysSample()` | nothing — real sampling is the collector's `tail_sampling` |
| U6 | `redis:alpine` digest | `sha256:3811787313eb…` resolved from the registry, not guessed | re-resolve when the image is rebuilt |
| U7 | Startup-probe budgets | 60s Go/Python/JS, 90s JVM/.NET — chosen, not measured | the first real run should confirm 90s is enough and not more |

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

Move a task here only after its acceptance criteria and validation passed. Record skipped
validation and residual risk instead of marking incomplete work done.
