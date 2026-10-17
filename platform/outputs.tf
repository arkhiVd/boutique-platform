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
    topic_arn = local.alerts_topic_arn
  }
}

# ---------------------------------------------------------------------------
# Phase 3 outputs.
# ---------------------------------------------------------------------------

output "k3s_version" {
  description = "The exact k3s build the nodes install. Pinned in nodes.tf because the stable channel is a moving target and a node rejoining later must join the same build it left."
  value       = local.k3s_version
}

output "leader_instance_id" {
  description = "The designated k3s leader -- the instance whose AZ is local.leader_az. This is the target scripts/bootstrap-cluster.sh opens an SSM session to, and the node that runs the etcd snapshot timer."
  value       = aws_instance.k3s_server[local.leader_az].id
}

output "leader_private_ip" {
  # Taken from the instance rather than from the SSM parameter: the provider
  # marks every aws_ssm_parameter `value` sensitive (it has no way to know a
  # String parameter from a SecureString one), and a private address is not a
  # secret while an output marked sensitive hides it from the plan for no reason.
  description = "Private address the two followers and the workload node join on, read from SSM at boot."
  value       = aws_instance.k3s_server[local.leader_az].private_ip
}

output "node_instance_ids" {
  description = "Every instance this stack creates, by role. Used by scripts/doctor.sh's SSM path and by the Phase 14 teardown check."
  value = {
    servers = { for az, inst in aws_instance.k3s_server : az => inst.id }
    worker  = aws_instance.k3s_worker.id
  }
}

output "schedulable_nodes" {
  description = "The four nodes and the AZ each lands in. Read this against `kubectl get nodes -o wide` after the apply: the SPEC's scheduling model is that all four are schedulable, with no control-plane taint."
  value = merge(
    { for az, inst in aws_instance.k3s_server : inst.private_ip => "server-${az}" },
    { (aws_instance.k3s_worker.private_ip) = "worker-${local.worker_az}" }
  )
}

output "k3s_node_names" {
  description = "The Kubernetes node names cloud-init registers, so `kubectl get nodes` output can be checked against something planned rather than interpreted afterwards."
  value = merge(
    { for az, inst in aws_instance.k3s_server : "server-${az}" => "boutique-leader-${inst.id}" if az == local.leader_az },
    { for az, inst in aws_instance.k3s_server : "server-${az}" => "boutique-follower-${inst.id}" if az != local.leader_az },
    { "worker-${local.worker_az}" = "boutique-agent-${aws_instance.k3s_worker.id}" }
  )
}

output "kms_key_arn" {
  description = "The CMK encrypting the root volumes and the k3s join token. The documented token-rotation command names this ARN."
  value       = aws_kms_key.platform.arn
}

output "etcd_snapshot_bucket" {
  description = "Where the Phase 4 etcd snapshot timer writes, and the only bucket the node role can write to."
  value       = aws_s3_bucket.etcd_snapshots.id
}

output "etcd_snapshot_prefix" {
  description = "The S3 prefix under etcd_snapshot_bucket that the timer uploads into. Matches the s3:PutObject/DeleteObject grants in iam-nodes.tf exactly."
  value       = "s3://${aws_s3_bucket.etcd_snapshots.id}/${local.etcd_snapshot_folder}/"
}

output "ami_id" {
  # nonsensitive because an AMI ID is published by AWS in every AMI console and
  # query; the provider marks every parameter `value` sensitive without
  # distinguishing a public one from a SecureString. The only value in this stack
  # that must stay unsurfaced is the k3s token, and that one never reaches a
  # `value` attribute at all -- see the header of nodes.tf.
  description = "The Amazon Linux 2023 AMI every node boots, read from SSM's public parameter at plan time."
  value       = nonsensitive(data.aws_ssm_parameter.amazon_linux_2023.value)
}

output "instance_profile_arn" {
  description = "The instance profile the launch templates pass to every node. Narrowed in iam-nodes.tf to SSM, ECR pull, CloudWatch, KMS, and the etcd snapshot prefix."
  value       = aws_iam_instance_profile.boutique_node.arn
}

output "k3s_join_token_parameter" {
  description = "The SSM parameter holding the join token. This is the whole point of the write-only design: the plan shows the name and never the value."
  value       = aws_ssm_parameter.k3s_token.name
}

# Phase 5 outputs. The ALB DNS and the hostnames built from it are the only
# public entry points, and both are outputs rather than hardcoded because
# neither exists until apply.

output "alb_dns_name" {
  description = "The edge ALB's public DNS name. The root hostname everything else is built from."
  value       = aws_lb.edge.dns_name
}

output "alb_arn" {
  description = "The edge ALB ARN, for the Web ACL association and the teardown script."
  value       = aws_lb.edge.arn
}

output "edge_security_group_id" {
  description = "The edge security group, for the runbook's allow-in check."
  value       = aws_security_group.boutique_edge.id
}

output "traefik_target_group_arn" {
  description = "The http target group. `aws elbv2 describe-target-health` against this is the first diagnostic for a total outage."
  value       = aws_lb_target_group.traefik_http.arn
}

output "edge_certificate_arn" {
  description = "The ACM certificate ARN. Null in http01 cert mode, where the certificate terminates at Traefik. Drops the sensitive taint it inherits from the imported cert's inputs: an ARN is a public identifier, not a secret, and marking it sensitive would hide the one value the runbook prints."
  value       = var.cert_mode == "http01" ? null : nonsensitive(local.acm_certificate_arn)
}

output "frontend_url" {
  description = "The storefront HTTPS URL. In self-signed cert mode the certificate is one we generated, so a browser warns — SPEC non-goal 7."
  value       = "https://boutique.<your-sslip-domain>/"
}

output "web_acl_arn" {
  description = "The Web ACL ARN, for the runbook's metric queries and the teardown."
  value       = aws_wafv2_web_acl.edge.arn
}

output "waf_action" {
  description = "`count` or `block`. Surfaced so the teardown-cost report and doctor.sh can state whether the edge is actually enforcing, without reading the tfvars."
  value       = var.waf_action
}
