# Evidence index

Where the proof for each ROADMAP exit criterion lives, and which criteria are **not**
proven. Absence is listed on purpose: a criterion missing from this page would read
as done.

- `live/<date>/` — captured by `scripts/evidence-capture.sh` from the running system:
  every file starts with the command that produced it. Re-run it to refresh.
- `phase-13/` — the drain, restore and runbook runs.
- `screenshots/` — the shop through the real ALB, Alertmanager.
- `PROGRESS.md` — dated, narrated results of each wave, with pasted output.
- `raw/` — gitignored scratch output; never committed.

Status: **proven** (the file shows it), **partial** (shows part of it), **open**
(not proven; the reason is given).

## Phase 0–2 — guardrails, cost, network

| criterion | status | proof |
|---|---|---|
| fmt, validate, tflint, checkov, gitleaks, shellcheck, kubeconform, conftest pass | proven | `scripts/check.sh` (154 PASS), CI `plan.yml` green on PR #3 |
| a second plan is empty after apply (bootstrap, platform) | proven | `live/*/01-plans.txt` |
| the Budget exists with its limit | proven | `live/*/02-cost.txt` |
| `cost-estimate.sh` total within 10% of SPEC | proven | `live/*/02-cost.txt`; PROGRESS "Cost ledger" |
| no SG opens 22/tcp or the API to the world (only the ALB's 80/443) | proven | `live/*/03-nodes.txt` |
| the plan gate fails on a malformed `.tf` | partial | the gate runs `terraform validate` (PR #3); a deliberate break commit was not made |

## Phase 3–4 — cluster and policy

| criterion | status | proof |
|---|---|---|
| nodes Ready across three AZs | proven | `live/*/03-nodes.txt` |
| access is SSM-only: no platform node has a key pair | proven | `live/*/03-nodes.txt` (the account's two other key pairs belong to the homelab project) |
| the join token is in neither state nor git | proven, with a correction | the token was in neither, but nodes had joined with its KMS **ciphertext**; rotated 2026-10-17 (PROGRESS) |
| a privileged pod is rejected | proven | `live/*/04-policy.txt` (Pod Security `restricted`) |
| a pod with no requests is rejected | partial | the LimitRange **defaults** it rather than rejecting; an over-limit pod IS rejected (`04-policy.txt`) |
| etcd snapshots in S3 | proven | `live/*/04-policy.txt` |
| an etcd restore serves the app | proven | `phase-13/etcd-restore-local.txt` (555 s) |

## Phase 5 — edge

| criterion | status | proof |
|---|---|---|
| https 200, http 301 | proven | `live/*/05-edge.txt` |
| Grafana and Jenkins host routes through the same ALB | proven | `live/*/05-edge.txt` (Grafana fixed 2026-10-17: it answered 404) |
| ALB access logs land in S3 | proven | `live/*/05-edge.txt` |
| a SQL-injection probe returns 403 | open | the Web ACL is deliberately in **count** mode (`waf_action = count`); the probe returns 200 and is logged |

## Phase 6 — the shop

| criterion | status | proof |
|---|---|---|
| all workloads Available, spread across nodes | proven | `live/*/06-boutique.txt`, `screenshots/shop-*.png` |
| every container read-only root and non-root | proven | `live/*/06-boutique.txt` (no offenders listed) |
| a drain loses zero loadgenerator requests | open | drains were run (`phase-13/drain.txt`) with the load generator scaled down during a memory incident; the zero-loss run was not repeated |

## Phase 7–8 — CI/CD

| criterion | status | proof |
|---|---|---|
| Jenkins reachable through the edge, configured as code | proven | `live/*/05-edge.txt`; JCasC in `ci/jenkins/values.yaml` |
| a build runs on an ephemeral agent | open | no pipeline run was recorded |
| PR build, trivy break, canary auto-rollback, approval gate | open | the pipeline library exists (`ci/`); none of its runs was recorded |
| Jenkins restarts with config intact | partial | it was restarted by `helm upgrade` on 2026-10-17 and came back Ready with its volume; job history was not compared |

## Phase 9–12 — observability and SLOs

| criterion | status | proof |
|---|---|---|
| request rate for the services, from span metrics | proven | `live/*/09-metrics.txt` |
| every scrape target up | proven | `live/*/09-metrics.txt`, `live/*/13-doctor.txt` |
| an alert fires and the email arrives | proven | `live/*/09-metrics.txt` (SNS sent, 0 new failures, 1 confirmed subscriber); the test email was received 2026-10-17 |
| a productcatalogservice line is retrievable | proven | `live/*/10-logs.txt` (it logs only at startup, hence a 24h window) |
| a request ID traced across three services with logcli | open | not recorded |
| log retention enforced | open | configured (168h, compactor); not proven with two timestamped queries |
| a checkout trace spans frontend → checkout → payment | proven | `live/*/11-traces.txt` |
| span metrics in Prometheus | proven | `live/*/11-traces.txt` |
| service-graph and latency-outlier screenshots | open | Grafana needs a login session the headless capture does not have |
| SLO burn-rate pages under injected errors, and not under noise | open | the rules are tested with `promtool test rules` (`check.sh`); no live injection was run |

## Phase 13 — operations

| criterion | status | proof |
|---|---|---|
| `doctor.sh` exit 0 healthy, non-zero with the reason when a node is drained | proven | `phase-13/doctor-1-healthy.txt`, `doctor-2-drained.txt`, `doctor-3-recovered.txt` |
| a timed etcd restore that serves the app | proven | `phase-13/etcd-restore-local.txt` |
| every runbook has Last verified and its commands run | proven | `phase-13/runbook-check.txt` (`scripts/check-runbooks.py`, live) |
| this index | proven | this file |

## Phase 14 — release and teardown

| criterion | status | proof |
|---|---|---|
| CI green, plan empty, Dependabot current, docs match | proven | PRs #2–#10; PROGRESS "Phase 14" |
| teardown executed | proven | `phase-14/teardown-*.txt`, `final/terminal/18–20` |
| `aws ce get-cost-and-usage` shows $0.00 for the following week | open until 2026-10-26 | the bill settles a week after teardown; the command is at the end of `phase-14/teardown-4-rerun.txt` |
