# boutique-platform — tasks

## Current phase: 3 — cluster bootstrap (blocked on the apply approval)

Built and validated with **no cluster and no live infrastructure**: everything below is proven by
`terraform plan`, `helm template`, `kustomize build`, `kubeconform`, `conftest`, `promtool`, and
the Fluent Bit binary. Nothing is deployed. Cluster-dependent exit criteria are named in the
blockers table rather than marked done.

## What is proven, and by what

| Phase | What landed | Proven by |
|---|---|---|
| 0 | SPEC / ROADMAP / AGENTS / TASKS, `scripts/check.sh`, `scripts/cost-estimate.sh`, ADRs 0001–0003, CI plan gate | `check.sh` PASS 0 FAIL 0; gitleaks clean; actionlint clean |
| 1 | `bootstrap/` — state bucket, split plan/apply OIDC roles, AWS Budget, SNS alerts | `terraform validate`, `plan: 14 to add, 0 to change, 0 to destroy`, `checkov 70 passed 0 failed 6 skipped` |
| 2 | `platform/` — VPC `10.90.0.0/16`, 3 public subnets, 4 security groups, narrow node instance profile | `plan: 42 to add, 0 to change, 0 to destroy`, `checkov 103 passed 0 failed`, `tflint` clean |
| 6 | `apps/boutique/` — upstream v0.10.7 vendored verbatim with provenance; all 13 workloads hardened (PDB, HPA, topology spread, anti-affinity, `seccompProfile`, `automountServiceAccountToken: false`, CPU requests == limits, `startupProbe`); `netpol/` with the kube-dns carve-out upstream omits; `policy/` rego + 3 failing fixtures; OTel collector with real processors | `kustomize build` 3033 lines; `kubeconform` 136/136 valid; `conftest` 1044/1044 pass, 22/22 fixtures rejected; `gitleaks` clean |
| 9 | `observability/kube-prometheus-stack/` on chart `92.1.1`; golden-signal recording rules; alerts; 4 dashboards; ServiceMonitors | `helm lint --strict` 0 failed; `promtool check rules` 9 rules |
| 10 | Loki `SingleBinary` with **enforced** 168h retention; Fluent Bit parsers for all six real log formats and a Loki output with exactly 3 labels | `promtool check rules` 4 rules; `scripts/check-fluentbit-config.py` runs the render through `fluent-bit --dry-run` in the pinned image |
| 12 | SLOs 99.9% / 99% with multiwindow multi-burn-rate (14.4x / 6x / 1x); `docs/slo.md`; burn-rate fixtures | `promtool test rules` → **SUCCESS**: the 14.4x page fires, the 6x and 1x do not, and a 1-in-20-for-10-min blip does not page |

## Blockers

| Item | Waiting on |
|---|---|
| Phase 3 first apply | Aravind's approval — it is the first cost-bearing apply (~$61/mo) |
| Phase 1 apply | Aravind's approval — an IAM change (Risky class) |
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
- 2026-10-08 Phase 1 — `bootstrap/` plans clean (14 add / 0 change / 0 destroy). Account verified
  back to its pre-session state afterwards by independent read-only calls.
- 2026-10-08 Phase 2 — `platform/` plans clean (42 add / 0 change / 0 destroy). Adds $0.00.
- 2026-10-08 Phase 6 — manifest layer on `feat/app-hardening`. See the table above.
- 2026-10-08 Phases 9, 10, 12 — observability config, rules, SLOs and burn-rate fixtures.
