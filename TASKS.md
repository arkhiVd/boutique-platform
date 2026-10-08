# boutique-platform — tasks

## Current phase: 2 — network and node identity (built on this branch; Phase 3 next)

Phases 1 and 2 are on this branch and are listed under Completed. Phase 0 remains open: the
scaffolding and the local gate exist and pass, but the GitHub repo's checks and a real PR run
are still outstanding.

### Phase 0 — guardrails and validation harness

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

### Phase 2 — network and node identity

- [x] `platform/` on the S3 backend with native locking (`use_lockfile`, no DynamoDB table)
- [x] VPC `10.90.0.0/16`, IGW, `0.0.0.0/0` route, three public subnets in `us-east-1a/b/c`
  with the `kubernetes.io/cluster/boutique-platform` and `kubernetes.io/role/elb` tags,
  `AmazonProvidedDNS` DHCP options
- [x] Four security groups with restricted egress and no 22/tcp rule anywhere; 21 standalone
  `aws_security_group_rule` resources so the policy audits as a list
- [x] `boutique-platform-node` instance profile with an SSM / ECR-pull / CloudWatch / one S3
  prefix / one SSM parameter inline policy, and `AmazonSSMManagedInstanceCore` attached
- [x] The account's existing broad `InstanceRole` left untouched; nothing else was modified
  - Acceptance criteria proven in this branch: `describe-security-groups` on
    `boutique-node-admin` has an empty `IpPermissions` list in the plan, and the node policy
    contains no resource wider than `"*"` for anything AWS can scope at all
  - Automated validation: `terraform plan` (42 to add, 0 to change, 0 to destroy),
    `terraform validate`, `fmt -check -recursive`, `checkov -d platform` (0 failed),
    `tflint --recursive`, `scripts/check.sh` (FAIL 0), `gitleaks detect --no-git`
  - Not yet run: `terraform apply`. That is Aravind's gate, and it is the first thing to do
    with a live state bucket, because `describe-security-groups` on the applied result is the
    SPEC's own acceptance check and a plan can only assert it syntactically

## Blocked / deferred by decision

| Item | Waiting on |
|---|---|
| Phase 1 bootstrap apply | Built and planned on `feat/infra-bootstrap-vpc`; waiting on Aravind to run the one-time local-state apply |
| Phase 2 apply | Same: the stack is built and planned, the apply is the gate |
| Phase 5 ALB + Web ACL | SPEC Q3 (ALB vs node-IP entry) |
| Phase 3 first apply | Aravind approves the first cost-bearing apply |

## Completed

- 2026-10-09 **Phase 1, `bootstrap/` on local state** (branch `feat/infra-bootstrap-vpc`): the
  S3 state bucket `boutique-platform-tfstate-<account>-us-east-1` (versioning, SSE-S3, all four
  public-access-block flags, noncurrent versions expired at 30 days), a GitHub Actions OIDC
  provider for `token.actions.githubusercontent.com` with the thumbprint read at plan time from
  the endpoint itself, the split `boutique-platform-plan` (read-only) and
  `boutique-platform-apply` roles sharing one trust policy (`StringEquals` on `aud`,
  `StringLike` on `repo:arkhiVd/boutique-platform:environment:*`), the AWS Budget
  `boutique-platform-monthly` at $30 with 50% and 80% forecast alerts, and the
  `boutique-platform-alerts` SNS topic with its email subscription. Validated by
  `terraform plan` (14 to add), `terraform validate`, `terraform fmt -check -recursive`,
  `checkov -d bootstrap` (69 passed, 0 failed, 6 skipped with reasons), `tflint --recursive`,
  and `gitleaks detect --no-git`.
- 2026-10-09 **Phase 2, `platform/` on the S3 backend with `use_lockfile`**: VPC `10.90.0.0/16`,
  three public subnets in `us-east-1a/b/c` with the Cloud Controller Manager and ELB subnet tags,
  IGW plus a `0.0.0.0/0` route, `AmazonProvidedDNS` DHCP options, four security groups and 21
  standalone `aws_security_group_rule` resources, and the `boutique-platform-node` instance
  profile whose inline policy is SSM, ECR-pull, CloudWatch, one S3 prefix and one SSM parameter.
  Validated by `terraform plan` (42 to add), `validate`, `fmt -check -recursive`,
  `checkov -d platform` (103 passed, 0 failed), `tflint --recursive`, `scripts/check.sh`
  (PASS 17 / FAIL 0 / MISSING 0), and `gitleaks detect --no-git` (no leaks).
  Residual risk, all recorded in the stack README rather than hidden: no `terraform apply` has
  been run for either stack (there is no state bucket yet, and the apply is Aravind's gate), so
  the plan line is the proof and not the applied result; VPC flow logs are off for cost; the
  ALB-to-NodePort rule lands in Phase 5; the etcd snapshot bucket is created in Phase 4.

Move a task here only after its acceptance criteria and validation passed. Record skipped
validation and residual risk instead of marking incomplete work done.

- 2026-10-08 SPEC/ROADMAP/AGENTS/TASKS scaffold written from live account evidence
  (`aws sts get-caller-identity`, `describe-vpcs`, `describe-security-groups`,
  `describe-instance-types`, quota checks, `ce get-cost-and-usage`) and from the real
  `GoogleCloudPlatform/microservices-demo` repo at `v0.10.7` — validated by inspection, no
  infrastructure touched
