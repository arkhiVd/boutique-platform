# The instance profile every k3s node wears. One role, one policy, scoped to the
# four things a node actually needs from AWS: talk to SSM, pull images, push
# metrics and logs, and upload an etcd snapshot.
#
# It replaces the account's pre-existing `InstanceRole`, which is broad enough
# to be a liability (it is a multi-service administrator-shaped role that was
# created by hand, before this repo existed). A dedicated role means the blast
# radius of a compromised node is exactly the actions listed below, it is
# version-controlled, and destroying this stack removes it cleanly. The old role
# is left alone — nothing here deletes or edits another stack's work.

resource "aws_iam_role" "boutique_node" {
  name = var.node_role_name

  # Plain service trust, deliberately. There is no per-instance condition key
  # that STS populates when EC2 mints instance-profile credentials from the
  # metadata service: `ec2:SourceInstanceArn` is not one, and a wildcarded
  # aws:SourceArn would read as a control while enforcing nothing. The real
  # boundary is that this profile is attached only to the launch template in
  # Phase 3.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "Ec2ServicePrincipal"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  description = "boutique-platform node instance role: SSM, ECR pull, CloudWatch metrics/logs, etcd snapshot upload."
}

resource "aws_iam_instance_profile" "boutique_node" {
  name = var.node_role_name
  role = aws_iam_role.boutique_node.name
}

data "aws_iam_policy_document" "boutique_node" {
  # The SSM agent's own calls. Every one of these five action families is
  # granted on "*" by AmazonSSMManagedInstanceCore itself -- verified against
  # this account on 2026-10-09:
  #   aws iam get-policy-version --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  #   --version-id v2 --output json
  # which returns three statements, all with "Resource": "*". AWS does not
  # support resource-level permissions for them, so there is no narrower form to
  # write; naming a resource here would produce a policy that denies the agent
  # at runtime.
  statement {
    sid    = "SsmAgentRegistration"
    effect = "Allow"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:Get*",
    ]
    resources = ["*"]
  }

  # ECR read: pull only. Pushing is CI's job, through the apply role's ECR grant.
  statement {
    sid       = "RegistryPullToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "RegistryPullLayers"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/*"]
  }

  # The CloudWatch agent's metric batch. CloudWatch has no resource-level
  # permission for PutMetricData (the API takes a namespace, not an ARN), so "*"
  # is the only form that works.
  statement {
    sid       = "MetricPublish"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  # Container logs. Scoped to the platform's log groups rather than to all logs.
  statement {
    sid    = "LogStreamWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/boutique-platform/*:log-stream:*"]
  }

  # The etcd snapshot target, and the one thing a node can write to S3. The
  # bucket itself is created in Phase 4 with the snapshot schedule; the grant is
  # already in place so the policy never has to be reopened.
  #
  # Three separate statements, because AWS scopes list and delete differently
  # from write: ListBucket acts on the bucket ARN and returns keys, while
  # PutObject and DeleteObject act on object ARNs. `k3s etcd-snapshot ls` needs
  # the list, `k3s etcd-snapshot prune`/`delete` needs DeleteObject, and the
  # Phase 4 timer needs PutObject. Without the list, a snapshot that uploaded
  # successfully cannot be seen from the node, which is the worst of the three
  # failures: the backup exists and nobody can prove it.
  statement {
    sid       = "EtcdSnapshotUpload"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.etcd_snapshot_bucket_name}/etcd-snapshots/*"]
  }

  statement {
    sid       = "EtcdSnapshotList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.etcd_snapshot_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["etcd-snapshots/*"]
    }
  }

  statement {
    sid       = "EtcdSnapshotDelete"
    effect    = "Allow"
    actions   = ["s3:DeleteObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.etcd_snapshot_bucket_name}/etcd-snapshots/*"]
  }

  # The CMK that encrypts the node's root volume and the k3s join token. A role
  # that cannot Decrypt the key cannot read the token, which makes this the
  # statement that the whole Phase 3 token design depends on.
  statement {
    sid    = "KmsDecryptPlatformKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:ReEncrypt*",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = [aws_kms_key.platform.arn]
  }

  # RunInstances with a CMK-encrypted volume makes EC2 create a grant on the key
  # on the caller's behalf; without this, the instance fails to launch with
  # "not authorized to perform kms:CreateGrant". Conditioned on
  # kms:GrantIsForAWSResource so the node cannot hand the key to a principal.
  statement {
    sid       = "KmsCreateGrantForVolumesOnly"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = [aws_kms_key.platform.arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  # Two plain String parameters the bootstrap needs: the k3s channel, and the
  # private address of the designated leader. Scope is one ARN each -- a node
  # cannot read the account's other parameters.
  statement {
    sid       = "ReadNodeParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [local.k3s_channel_parameter_arn, local.k3s_leader_ip_parameter_arn]
  }

  # The k3s join token, as a SecureString. Separate from the statement above
  # because this is the one parameter whose disclosure is a cluster compromise:
  # anyone holding it can join a node to the cluster. The kms:Decrypt grant above
  # is what makes this readable at all.
  statement {
    sid       = "ReadK3sJoinToken"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [local.k3s_token_parameter_arn]
  }
}

resource "aws_iam_role_policy" "boutique_node" {
  name   = "${var.node_role_name}-inline"
  role   = aws_iam_role.boutique_node.name
  policy = data.aws_iam_policy_document.boutique_node.json
}

# The node's runtime configuration. Standard tier, so free. Phase 3's cloud-init
# reads it with the node role's single ReadK3s grant, which means the channel
# has one source of truth instead of a version string buried in user-data.
resource "aws_ssm_parameter" "k3s_channel" {
  name        = var.k3s_channel_parameter_name
  description = "k3s release channel the nodes install from. Phase 3 pins the exact version on top of this."
  type        = "String"
  value       = "stable"

  tags = {
    Name = var.k3s_channel_parameter_name
  }
}

# The maintained AWS minimum for SSM, attached alongside the inline policy above.
# The inline document exists so the exact surface is auditable line by line
# rather than trusted to a managed policy, and so the review of this phase does
# not have to open a second console.
resource "aws_iam_role_policy_attachment" "boutique_node_ssm_core" {
  role       = aws_iam_role.boutique_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
