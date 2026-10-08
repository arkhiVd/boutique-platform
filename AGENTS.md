# boutique-platform — agent instructions

## Purpose

A production-grade Kubernetes platform for the Google Online Boutique sample app, on one AWS
Free-plan account: k3s HA on three AZs, a two-layer edge (AWS ALB + WAF + Traefik), Jenkins
CI/CD with ephemeral agents and canary rollback, and a full metrics/logs/traces/SLO
observability stack. `SPEC.md` holds the contract; `ROADMAP.md` holds the phases.

## Architecture

- `bootstrap/` — one-shot, **local state**: S3 state bucket, split OIDC plan/apply roles, Budget
- `platform/vpc/` — VPC, 3 public subnets in 3 AZs, IGW, no NAT (cost)
- `platform/nodes/` — k3s server nodes, security groups, encrypted gp3, SSM only
- `platform/edge/` — ALB, Web ACL, ACM cert, access-log bucket, Traefik host routes
- `apps/boutique/` — vendored upstream `v0.10.7` baseline + hardening overlays
- `ci/` — Jenkins Helm values, JCasC, shared library, `Jenkinsfile`
- `observability/` — kube-prometheus-stack, Loki, Tempo, OTel Collector, SLOs, dashboards
- `scripts/` — `doctor.sh`, `cost-estimate.sh`, `security-audit.sh`, runbook command runner
- `docs/adr/` — decisions; `docs/evidence/` — proof per phase
- `PROGRESS.md` — the live page Aravind watches; update it as work moves, not at the end

**Generated / never hand-edit:** `*.tfstate`, `.terraform/`, `charts/*/charts/`,
`docs/evidence/raw/*` (copied from tool output).

**Generated but tracked:** `docs/progress.html` — rendered from `PROGRESS.md` by
`scripts/render-progress.py`, committed so it renders in the repo. After editing
`PROGRESS.md`, run that script and commit both.

**External interfaces:** AWS account `348032171026` (region `us-east-1`), ECR registry, S3 state
bucket, GitHub `arkhiVd/boutique-platform`.

**Toolchain (must match SPEC.md):** Terraform `1.15.9`, AWS provider `~> 6.68`, Helm `3.16.3`,
kubectl `v1.36.3`, k3s `v1.36.5+k3s1`, OTel Collector `0.160.0`, Boutique `v0.10.7`.

**Environments:** one cluster, `boutique-prod`. PR previews are ephemeral namespaces `pr-<n>`.

## Commands

```bash
# setup
git clone https://github.com/arkhiVd/boutique-platform && cd boutique-platform
helm version --short                      # v3.16.3
terraform version                         # 1.15.9

# format
terraform fmt -recursive
helm lint --strict ci jenkins observability

# local gate — run the whole thing before reporting done
scripts/check.sh

# focused checks
terraform -chdir=platform/vpc fmt -check && terraform -chdir=platform/vpc validate
kubeconform -strict -summary apps/boutique/base
conftest test apps/ ci/ observability/ -p policy/
shellcheck scripts/*.sh
gitleaks detect --no-git

# kubernetes, against the real cluster
aws ssm start-session --target "$(terraform -chdir=platform/nodes output -raw leader_instance_id)"
export KUBECONFIG=~/.kube/boutique-prod.yaml      # fetched by scripts/bootstrap-cluster.sh
scripts/doctor.sh

# deploy (needs Phase 3-6 done)
helm upgrade --install ci ci/ -n ci --create-namespace -f ci/jenkins-values.yaml
helm upgrade --install boutique apps/boutique -n boutique -f apps/boutique/values-prod.yaml

# cost
scripts/cost-estimate.sh      # prints the SPEC cost table recomputed from the plan
```

## Working boundaries

- Branch first; never commit to `main`.
- Never commit `.tfvars`, `.env`, kubeconfigs, k3s tokens, SSM output, state, or `docs/evidence/raw/*`.
- Never `terraform apply`, `terraform destroy`, `helm upgrade`, `kubectl apply` to the live
  cluster, merge, or push to `main` without an explicit instruction **in this session**.
- Ask before anything cost-bearing, account-wide, or destructive. Every time. The three gates
  are listed in `ROADMAP.md`.
- The running cluster is a validation target, not a pet. It is destroyed at Phase 14.
- Touch only what the task requires. No drive-by refactors. The working tree may hold changes
  from other devices — preserve them.
- Commits: conventional style with scope (`feat(edge):`, `fix(ci):`), author `arkhiVd`.
  **No AI attribution of any kind.** This repo is hiring evidence.

## Validation

- Run focused checks while implementing; run `scripts/check.sh` before reporting done.
- Paste real command output. **An implementation report is not evidence.** No check that was
  skipped may be silently omitted — name it and give the residual risk.
- IaC: read `terraform plan` line by line and state creates / changes / destroys / replaces.
  The plan is the test harness.
- Visible changes: screenshot. App changes: a rendered page. Alert changes: a pasted firing.
- Negative tests are first-class: if the phase claims a pod is rejected, show the rejection.

## Documentation routing

- `SPEC.md` — problem, behavior, security, pinned versions, cost, non-goals, acceptance criteria
- `ROADMAP.md` — phases, approval gates, dependency graph
- `TASKS.md` — the current phase and its validation status
- `docs/adr/` — decisions and their alternatives
- `docs/runbooks/` — operational procedures
- `docs/evidence/` — the proof index for every acceptance criterion
- Vault knowledge layer: `~/Documents/myvault/Projects/boutique-platform.md`
- Workflow contract: `~/Documents/myvault/Systems/workflows/project-dev.md`

## Maintenance

Keep this file short enough to follow. Add a rule only when it prevents a real repeat mistake.
When corrected, tighten the existing rule instead of appending a warning.
