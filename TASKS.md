# boutique-platform — tasks

## Current phase: 0 — guardrails and validation harness

- [ ] Write `AGENTS.md`, `CLAUDE.md`, `SPEC.md`, `ROADMAP.md`, `TASKS.md`, `.gitignore`,
      `.gitattributes`, `.gitleaksignore`
  - Scope: repo scaffolding only, no infrastructure
  - Acceptance criteria: every file present and free of placeholder text; `SPEC.md`
    unresolved questions answered or explicitly left open
  - Automated validation: `terraform fmt -recursive -check`, `gitleaks detect --no-git`
  - Manual validation: Aravind reads SPEC.md and answers Q1 (node size) and Q3 (ALB)
  - Blockers: **SPEC unresolved Q1 and Q3 — sizing/cost decision needed before Phase 2**

- [ ] Create the GitHub repo `arkhiVd/boutique-platform` and push Phase 0
  - Scope: repo creation, `main` as default branch, no CI secrets yet
  - Acceptance criteria: `git push` succeeds; GitHub shows the guardrail files
  - Automated validation: `git diff --check` clean
  - Manual validation: the repo is visible to Aravind
  - Blockers: none (needs Aravind's go-ahead to create a public repo)

- [ ] Wire `scripts/check.sh` as the single local gate
  - Scope: wrappers for fmt / validate / kubeconform / conftest / shellcheck / gitleaks
  - Acceptance criteria: `scripts/check.sh` runs and reports pass/fail per tool with real
    output; a deliberately broken `.tf` makes it exit non-zero
  - Automated validation: the deliberate break
  - Manual validation: none
  - Blockers: `tflint`, `trivy`, `kubeconform`, `checkov`, `shellcheck` are not all on PATH —
    install them or record the gap explicitly rather than skipping silently

- [ ] Add `.github/workflows/plan.yml` (PR plan gate) and `dependabot.yml`
  - Scope: SHA-pinned actions, gitleaks → fmt → validate → checkov → plan → PR comment;
    plan uses a read-only OIDC role from Phase 1
  - Acceptance criteria: `actionlint` clean; a PR run posts a plan
  - Automated validation: `actionlint .github/workflows/plan.yml`
  - Manual validation: one real PR run
  - Blockers: Phase 1 OIDC role must exist first; the workflow can be merged in a
    non-actionable state until then

## Blocked / deferred by decision

| Item | Waiting on |
|---|---|
| Phase 1 AWS Budget + OIDC roles | Aravind approves the IAM change (Risky class) |
| Phase 2 VPC provisioning | SPEC Q1 (node size) — changes nothing structural but changes the cost story |
| Phase 5 ALB + Web ACL | SPEC Q3 (ALB vs node-IP entry) |
| Phase 3 first apply | Aravind approves the first cost-bearing apply |
| Phase 6 drain test (`zero failed requests`) | Needs a schedulable node to drain to. On the SPEC's one-workload-node topology the pods go **Pending**, not running. Same root cause as the CPU over-commit below — SPEC Q1. |
| Phase 6 collector `debug` → Tempo exporter | Phase 11 (Tempo does not exist yet) |
| adservice / shippingservice tracing | `docs/adr/0004-adservice-tracing-gap.md` — a pinned OTel Java agent and a live-pod answer on where its temp dir lives under `readOnlyRootFilesystem: true` |

## Unknowns recorded rather than guessed

Nothing below is filled with a fabricated value. Each is a decision with a runtime consequence,
not a task that can be closed by writing something plausible.

| # | Unknown | Measured value | What it blocks |
|---|---|---|---|
| U1 | **`boutique` CPU requests vs one t3.medium.** | `2820m` of requests against a node's `2000m` | Phase 6 "all 13 workloads Available". A node-sized `requests.cpu: "2000m"` quota turns this into `FailedCreate`, so `quota.yaml` caps at `3` instead and documents the three ways to close it. Preference is option 2 (relax the workload-node taint so `boutique` can use the 3 servers: 6 vCPU), which is what SPEC's own 10GiB/8vCPU diagram already assumes |
| U2 | **Shippingservice / adservice tracing gap.** | Both `initTracing()` bodies are TODOs upstream (issue #422) | Phase 11 trace completeness |
| U3 | **cartservice has no instrumentation at all upstream** — not a stub, never built | `grep -r otel src/cartservice/` → nothing | a `shipping` span on the checkout trace |
| U4 | **`OTEL_TRACES_SAMPLER*` is inert for the six instrumented v0.10.7 images** | they hard-code `AlwaysSample()` and read only `COLLECTOR_SERVICE_ADDR` | nothing — the real sampling decision is the collector's `tail_sampling`. Set so a successor image picks it up |
| U5 | **OTel Collector `runAsUser`** | resolved from the registry API, not guessed: `sha256:5f92255513d9…` declares `USER 10001:10001` | nothing; upstream's `1000` is followed by the image's own declaration instead |
| U6 | **`redis:alpine` tag is not pinned by SPEC** | resolved to `sha256:3811787313eb…` on 2026-10-08 | nothing, but the digest ages; re-resolve when the image is rebuilt |
| U7 | **Startup-probe budgets** | 60s (Go/Python/JS), 90s (adservice JVM, cartservice .NET), chosen not measured — no cluster yet | nothing, but the first real run should confirm 90s is enough and not more |

## Completed

Move a task here only after its acceptance criteria and validation passed. Record skipped
validation and residual risk instead of marking incomplete work done.

- 2026-10-08 SPEC/ROADMAP/AGENTS/TASKS scaffold written from live account evidence
  (`aws sts get-caller-identity`, `describe-vpcs`, `describe-security-groups`,
  `describe-instance-types`, quota checks, `ce get-cost-and-usage`) and from the real
  `GoogleCloudPlatform/microservices-demo` repo at `v0.10.7` — validated by inspection, no
  infrastructure touched
- 2026-10-08 **Phase 6, manifest layer** (branch `feat/app-hardening`, no cluster and no
  `kubectl apply` anywhere): `apps/boutique/upstream-kubernetes-manifests.yaml` vendored verbatim
  with provenance (URL, tag, fetch date, sha256 of the upstream body, Apache-2.0);
  `apps/boutique/base/` rewritten for all 13 workloads with PDB, HPA (10 — redis-cart and
  loadgenerator exempt with a checked reason), topology spread, preferred anti-affinity,
  priority classes, `seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false` on
  pod and ServiceAccount, dedicated ServiceAccounts including one for `redis-cart` which had
  none, `RollingUpdate maxSurge: 1 / maxUnavailable: 0`, `revisionHistoryLimit: 5`,
  `progressDeadlineSeconds: 600`, `startupProbe` on every service with a 90s budget for the JVM
  (.NET) cold-start pair, CPU requests == limits for Guaranteed QoS with upstream memory kept,
  and OTel env wiring with both the spec-standard and upstream-native forms;
  `apps/boutique/netpol/` default-deny plus one allow policy per service with an explicit
  `kube-dns` egress carve-out on every one; `policy/security.rego` + `policy/resources.rego`
  with three deliberately-failing fixtures; `apps/boutique/observability/` collector with real
  processors (`memory_limiter`, `tail_sampling`, `batch`) replacing upstream's empty
  `processors:`; `apps/boutique/quota.yaml` with the measured arithmetic; `docs/chaos-experiments.md`
  and `scripts/chaos/inject-latency.sh`. Validated by `kustomize build`, `kubeconform -strict
  -kubernetes-version 1.36.3`, `conftest` in both per-document and `--combine` modes, `gitleaks`
  and `scripts/check.sh` (PASS 50 / FAIL 0 / MISSING 0). Cluster-dependent exit criteria are
  named in the blockers table above, not silently marked done.
