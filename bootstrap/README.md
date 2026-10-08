# bootstrap — the one-shot stack

Creates the things the rest of the repo needs before it can track anything:

| Resource | Why it exists |
|---|---|
| S3 bucket `boutique-platform-tfstate-<account>-us-east-1` | state for `platform/`, native `use_lockfile` locking, versioned, SSE-S3, noncurrent versions expired at 30 days |
| OIDC provider for `token.actions.githubusercontent.com` | lets GitHub Actions assume a role without a long-lived access key |
| Role `boutique-platform-plan` | read-only. The PR plan gate in `.github/workflows/plan.yml` assumes this |
| Role `boutique-platform-apply` | the post-merge apply on `main` |
| SNS topic `boutique-platform-alerts` + email subscription | Budget alerts now, cluster alarms from Phase 9 |
| AWS Budget `boutique-platform-monthly`, $30 | two alerts (50% and 80% forecast) on the SNS topic |

Nothing here runs a container, a database, or an instance. After this stack
exists, `platform/` can be applied and the cluster phases can begin.

## Run it once

> **This stack uses local state on purpose** — it creates the bucket the other
> stack stores state in, so it cannot store state there itself. Run it from one
> workstation, once, and keep `terraform.tfstate` where you ran it. Do not clone
> the repo onto a second machine and run `terraform apply` here: that run cannot
> see the resources the first run created, so it will plan to create them again
> and fail on the bucket name. Do not move this stack to the S3 backend.
>
> **Run it exactly once.** If the state file is lost, re-plan with
> `terraform plan` and reconcile by hand (or `import`) rather than re-applying.

```bash
cd bootstrap

terraform init                                    # local backend, no -backend-config
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars                          # alert_email is required

terraform plan -no-color                          # read the plan, then
terraform apply -no-color                         # once you have read it
terraform output                                  # feed these into platform/
export GITHUB_OIDC_THUMBPRINT="$(terraform output -raw oidc_provider_arn)"  # not needed, illustrative
```

`terraform validate` and `terraform fmt -check -recursive` are the CI-parity
checks; the plan is the real gate.

After it succeeds, copy the values into the GitHub repository secrets:

| Secret | Output |
|---|---|
| `AWS_PLAN_ROLE_ARN` | `plan_role_arn` |
| `AWS_APPLY_ROLE_ARN` | `apply_role_arn` |

And set up the two GitHub Actions environments, `preview` and `production`,
because both roles trust `repo:arkhiVd/boutique-platform:environment:*` — the
environment name is the only thing separating a plan from an apply.

## Blast radius

- `boutique-platform-plan` — describes and reads. It cannot change anything,
  including the state bucket. It exists so the plan gate can read the state it
  is diffing.
- `boutique-platform-apply` — writes: EC2, ELB, ECR, S3 state, and IAM **only**
  on the platform's own node role and instance profile. Everything in IAM that
  is not tagged `Project=boutique-platform` is denied explicitly, so this role
  cannot edit humans, policies, or the roles in this stack.
- Neither role can touch `bootstrap/`. This stack is applied by a human with
  the account's admin user, which is the point: the state bucket, the Budget and
  the roles themselves are the trust anchor and are not delegated to CI.

## `terraform destroy` here deletes the state bucket

`aws_s3_bucket` versioning does not stop a destroy: destroying this stack empties
the bucket that holds every other stack's state, and the SNS topic the alerts
ride on. After a destroy here you must re-run `terraform init` in `platform/`
against the *new* bucket name, or point it back at the old one if you restore it.

Do not destroy this stack while `platform/` holds live infrastructure. The
platform teardown path is Phase 14's `destroy.yml`.
