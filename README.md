# Boutique platform

A production-grade Kubernetes platform for the **Google Online Boutique** sample application,
built on one AWS Free-plan account: **k3s HA across three AZs**, a **two-layer edge** (AWS ALB
with TLS, a Web ACL and access logs → in-cluster Traefik), **Jenkins CI/CD** with ephemeral
Kubernetes agents and canary auto-rollback, and **metrics / logs / traces / SLOs**.

The point of this repo is a specific, checkable claim: Google's own Online Boutique deployment
is a *minimal, kind-deployable baseline by design* — its product requirements mandate
"preserve the golden user journey taken by Kubernetes beginners" — so every hardening control
that makes a deployment survivable (PodDisruptionBudget, HPA, topology spread, ResourceQuota,
egress DNS carve-outs, SLOs) is deliberately absent from the manifests it ships. This platform
runs the same application with those controls present and **proven with command output**, not
asserted.

## Read in this order

1. [`PROGRESS.md`](PROGRESS.md) — the live page: where the build is, what blocks it, what is proven
2. [`SPEC.md`](SPEC.md) — the contract: behavior, security, pinned versions, cost, acceptance criteria
3. [`ROADMAP.md`](ROADMAP.md) — the phases, their exit criteria, and the three approval gates
4. [`docs/adr/`](docs/adr) — the decisions and what was rejected
5. [`docs/evidence/`](docs/evidence) — the proof index for every acceptance criterion
6. [`docs/runbooks/`](docs/runbooks) — operational procedures

## Architecture

```
                       AWS us-east-1
 internet ──► ALB ──(TLS · Web ACL · access logs)──► Traefik ──► frontend ──► 10 gRPC services + redis
                                                        │
   ┌────────────────── namespace: observability ────────┼──────────────── namespace: ci ──────────────┐
   │ Prometheus · Grafana · Alertmanager · Loki ·      │               Jenkins controller          │
   │ Tempo · OTel Collector gateway                    │               + ephemeral agent pods      │
   └───────────────────────────────────────────────────┴────────────────────────────────────────────┘
                      k3s HA: 3 servers, 3 AZs, etcd quorum of 3
                      nodes: SSM-only access, no SSH, no key pairs, encrypted gp3
```

## What it deliberately is not

- **Not EKS** — the $73/mo control plane is 3.5× the remaining budget. See
  [`docs/adr/0001-k3s-not-eks.md`](docs/adr/0001-k3s-not-eks.md).
- **Not multi-region** — no second region exists and no multi-region failover is claimed.
- **Not a service mesh** — a sidecar per pod does not fit 4 GiB nodes next to Jenkins and
  Prometheus; the mTLS gap is named, with the reason.
- **Not the synthetic fault flags** — `adServiceFailure` / `recommendationCacheFailure` do not
  exist upstream (checked across v0.1.4–v0.10.7). Chaos is `EXTRA_LATENCY` plus pod/node
  deletion.

## Local gate

```bash
scripts/check.sh          # the single command an agent runs before reporting done
```

Per tool: `terraform fmt -recursive -check` · `terraform validate` · `checkov -d .` ·
`kubeconform` · `conftest test` · `shellcheck` · `gitleaks detect --no-git` · `actionlint`.
Missing tools are reported by the script, never silently skipped.

## Cost and teardown

The running cluster is a validation target, not a pet. It is destroyed at Phase 14 and the
account returns to $0.

```bash
scripts/cost-estimate.sh
```

Every destructive and cost-bearing action has a tested rollback path, and `destroy.yml` requires
a typed confirmation plus a GitHub environment approval.

## Status

Wave A, Phase 0. See [`PROGRESS.md`](PROGRESS.md).
