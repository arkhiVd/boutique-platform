output "vpc_id" {
  description = "The VPC every cluster resource lives in. Paired with subnet_ids, this is what a security group or ALB in a later phase attaches to."
  value       = aws_vpc.boutique.id
}

output "vpc_cidr" {
  description = "The VPC's CIDR, for checking overlap before anything new is carved out of it."
  value       = aws_vpc.boutique.cidr_block
}

output "subnet_ids" {
  description = "The three public subnet IDs, one per AZ. Phase 3's launch template and the Phase 5 ALB target group use these."
  value       = [for subnet in aws_subnet.boutique : subnet.id]
}

output "availability_zones" {
  description = "The AZs actually resolved for this account, in order, so the one-node-per-AZ claim can be checked against the plan."
  value       = local.azs
}

output "security_group_ids" {
  description = "Every security group this stack creates, by name, so a caller does not have to hardcode an ID."
  value = {
    node_admin    = aws_security_group.boutique_node_admin.id
    node_api      = aws_security_group.boutique_node_api.id
    node_internal = aws_security_group.boutique_node_internal.id
    edge          = aws_security_group.boutique_edge.id
  }
}

output "instance_profile_name" {
  description = "The instance profile Phase 3's launch template passes to RunInstances, and the only role the bootstrap apply role may pass."
  value       = aws_iam_instance_profile.boutique_node.name
}

output "node_role_arn" {
  description = "ARN of the node role, for the policy statements outside this stack."
  value       = aws_iam_role.boutique_node.arn
}

output "state_backend_init_command" {
  # Terraform backend blocks accept constant strings only, so var.bootstrap_state_bucket
  # cannot reach backend.tf. This is the seam: it prints the init command with the
  # bucket already in it, so the operator does not have to remember that part of
  # the bootstrap hand-off.
  description = "The init command that wires the S3 backend, with the bucket from tfvars already substituted."
  value       = "terraform init -backend-config=\"bucket=${var.bootstrap_state_bucket}\""
}

output "region" {
  description = "Region the operator's kubectl context points at."
  value       = data.aws_region.current.region
}
output "account_id" {
  description = "Account the stack is bound to. Used by the CI secrets, never hardcoded in a tracked file."
  value       = data.aws_caller_identity.current.account_id
}

output "k3s_channel_parameter" {
  description = "The SSM parameter the nodes read at boot. Its ARN is the only parameter the node role can read."
  value       = aws_ssm_parameter.k3s_channel.name
}

output "alert_email" {
  description = "Where the Phase 9 cluster alarms will point. Stated here so the operator can confirm it matches the bootstrap SNS subscription."
  value = {
    email     = var.alert_email
    topic_arn = "arn:aws:sns:us-east-1:${data.aws_caller_identity.current.account_id}:boutique-platform-alerts"
  }
}
