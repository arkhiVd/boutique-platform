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

## Completed

Move a task here only after its acceptance criteria and validation passed. Record skipped
validation and residual risk instead of marking incomplete work done.

- 2026-10-08 SPEC/ROADMAP/AGENTS/TASKS scaffold written from live account evidence
  (`aws sts get-caller-identity`, `describe-vpcs`, `describe-security-groups`,
  `describe-instance-types`, quota checks, `ce get-cost-and-usage`) and from the real
  `GoogleCloudPlatform/microservices-demo` repo at `v0.10.7` — validated by inspection, no
  infrastructure touched
