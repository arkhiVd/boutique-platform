variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Region for the state bucket, the Budget and the OIDC provider. The account's only provisioned region; do not change without changing every ARN in this stack."
}

variable "alert_email" {
  type        = string
  description = "Where the Budget alerts and the cluster alarms go. Kept out of git: copy terraform.tfvars.example to terraform.tfvars and set it there."
  nullable    = false

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a single email address. It is subscribed to the boutique-platform-alerts SNS topic and must be confirmed before the first alert arrives."
  }
}

variable "monthly_budget_limit_usd" {
  type        = number
  default     = 30
  description = "Monthly Budget ceiling. SPEC prices the whole platform at ~$124/mo and the credit budget is $200, so 30 is a loud, early threshold rather than a ceiling the plan is meant to reach."
}

variable "existing_oidc_provider_arn" {
  type        = string
  default     = ""
  description = "ARN of an already-present OIDC provider for token.actions.githubusercontent.com. Only read when create_oidc_provider is false."
}

variable "create_oidc_provider" {
  type        = bool
  default     = true
  description = "Create the AWS-side OIDC provider for GitHub Actions. Set false only when the account already has one, checked with `aws iam list-open-id-connect-providers`. On 2026-10-09 that command returned an empty list, so the default is true."

  validation {
    condition     = var.create_oidc_provider || var.existing_oidc_provider_arn != ""
    error_message = "create_oidc_provider = false requires existing_oidc_provider_arn, otherwise the trust policy below has no provider to name."
  }
}
