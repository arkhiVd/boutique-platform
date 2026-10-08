output "state_bucket_name" {
  description = "The S3 bucket the platform stack uses for state. Feed it to platform/ as bootstrap_state_bucket."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket, for policy statements outside this stack."
  value       = aws_s3_bucket.tfstate.arn
}

output "plan_role_arn" {
  description = "Read-only role the PR plan gate assumes: AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role the post-merge apply on main assumes: AWS_APPLY_ROLE_ARN."
  value       = aws_iam_role.apply.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider. Empty when the account already had one and create_oidc_provider is false."
  value       = local.github_oidc_provider_arn
}

output "budget_name" {
  description = "The AWS Budget the account-side cost guardrail lives in."
  value       = aws_budgets_budget.monthly.name
}

output "budget_limit_usd" {
  description = "Monthly Budget ceiling, for scripts/cost-estimate.sh to reason about."
  value       = aws_budgets_budget.monthly.limit_amount
}

output "alerts_topic_arn" {
  description = "SNS topic that carries Budget and cluster alerts to var.alert_email."
  value       = aws_sns_topic.alerts.arn
}
