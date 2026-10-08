# Everything here is a read against the account at plan time. Nothing in this
# file creates anything.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Used to fail the plan, not to pick AZs: the subnets are pinned to
# us-east-1a/b/c by var.azs because the SPEC's "one node per AZ" contract
# depends on those specific three, and an account's AZ name-to-id mapping is
# not stable across accounts.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # The evidence bucket is created in Phase 4 with the etcd snapshot schedule.
  # The node policy grants PutObject under its etcd-snapshots/ prefix so the
  # grant is already in place when the schedule exists.
  etcd_snapshot_bucket_name = "boutique-platform-etcd-snapshots-${data.aws_caller_identity.current.account_id}"

  # Phase 3 writes this and the nodes read it at boot, so the k3s channel has
  # one source of truth that is not a cloud-init string. SSM ARNs do not carry
  # the leading slash the API name has, hence the trimprefix.
  k3s_channel_parameter_arn = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${trimprefix(var.k3s_channel_parameter_name, "/")}"

  # Only the three AZs the SPEC names, in a deterministic order.
  azs = [for az in data.aws_availability_zones.available.names : az if contains(var.azs, az)]

  # Every node uses the same egress policy: TLS/443 out to anything (package
  # mirrors, ECR, S3), DNS to the VPC resolver only. One rule set, four SGs,
  # stated once.
  #
  # 10.90.0.2 is the Route 53 Resolver address AWS always places at the base of
  # a VPC's primary CIDR. Scoped to /32, so a node can resolve names and cannot
  # reach anything else in the subnet on 53.
  vpc_dns_cidr = "${cidrhost(var.vpc_cidr, 2)}/32"
}

data "aws_partition" "current" {}

data "aws_ec2_instance_type" "server" {
  instance_type = var.instance_type_servers
}

data "aws_ec2_instance_type" "worker" {
  instance_type = var.instance_type_worker
}

# The quota the SPEC's whole node shape leans on: 8 vCPU of running on-demand
# standard instances, verified live as 8.0 on 2026-10-09 with
# `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A`.
# Phase 3 adds the instances; this asserts the shape that will be launched fits
# before anything is launched.
#
# What this is and is not: a Terraform check block is the one validation form
# that does not block an operation. It warns on plan and apply and lets both
# continue (https://developer.hashicorp.com/terraform/language/block/check).
# The blocking version of the same rule is scripts/cost-estimate.sh, which exits
# 8 on a shape over quota. This one exists so the number is visible in the plan,
# not only in the cost gate's arithmetic.
data "aws_servicequotas_service_quota" "running_on_demand" {
  service_code = "ec2"
  quota_code   = "L-1216C47A"
}

check "node_shape_within_vcpu_quota" {
  assert {
    condition = (
      (3 * data.aws_ec2_instance_type.server.default_vcpus) +
      (1 * data.aws_ec2_instance_type.worker.default_vcpus) <=
      data.aws_servicequotas_service_quota.running_on_demand.value
    )
    error_message = "The SPEC's shape (3 servers + 1 worker) does not fit the ${data.aws_servicequotas_service_quota.running_on_demand.value} vCPU running-on-demand quota: 3 x ${var.instance_type_servers} (${data.aws_ec2_instance_type.server.default_vcpus} vCPU) + 1 x ${var.instance_type_worker} (${data.aws_ec2_instance_type.worker.default_vcpus} vCPU). Reduce the node count or the type; a 5th instance cannot launch here."
  }
}
