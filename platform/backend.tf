# Remote state with native S3 locking.
#
#   use_lockfile = true   (Terraform >= 1.10.0) — the lock is an S3 object
#                         next to the state file. No DynamoDB table, so there is
#                         no second billed resource and nothing to keep in sync
#                         with the bucket.
#   encrypt      = true   — SSE-S3 at rest, matching the state bucket.
#
# `bucket` is supplied at init with -backend-config. A backend block accepts
# constant strings only, so the account-scoped bucket name from bootstrap/ cannot
# be interpolated here — and it is deliberately not written into a tracked file.
# The one-liner is in README.md.
terraform {
  backend "s3" {
    key          = "boutique-platform/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
