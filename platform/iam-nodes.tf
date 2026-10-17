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

  # And the read, which the design originally left out and the restore drill
  # measured on 2026-10-15: `scripts/etcd-restore-drill.sh` runs on the leader
  # with the node role and downloads the newest object to restore it into
  # scratch, so a node that cannot read the bucket cannot prove a backup
  # restores. The `TARGET=cluster-live` restore path needs the same GetObject.
  # Scoped to the snapshot prefix: it is the node's ONE readable S3 location,
  # and it holds etcd snapshots of this cluster and nothing else.
  statement {
    sid       = "EtcdSnapshotRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
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

  # And the key the snapshot bucket encrypts WITH, which is the statement that
  # was missing on 2026-10-15 when the end-to-end drill ran. The bucket is
  # SSE-KMS (`kms_master_key_id = aws_kms_key.platform` in etcd-backup.tf), and
  # an SSE-KMS PutObject calls GenerateDataKey on the CMK. The node role had
  # s3:PutObject and kms:Decrypt but not GenerateDataKey, so every run failed
  # with   "is not authorized to perform: kms:GenerateDataKey on resource:
  #   arn:aws:kms:...:key/<platform CMK>"  and the bucket stayed empty while
  # the snapshot service reported a successful save and a failing list. k3s
  # logs it as "Error received during snapshot upload to S3".
  #
  # Narrow on purpose: GenerateDataKey (not WithoutPlaintext) is what a
  # server-side encryption upload needs, and the resource is the one CMK, not a
  # wildcard. Decrypt is here for the restore drill's download, and DescribeKey
  # is what the S3 client consults before it will use the key.
  statement {
    sid    = "EtcdSnapshotKms"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.platform.arn]
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

  # The EBS CSI driver (cluster/ebs-csi) reads the node role's credentials
  # because k3s mints no usable OIDC issuer: its service-account tokens are
  # signed for https://kubernetes.default.svc, which no IAM trust policy can
  # reach, so the IRSA pattern of a per-workload role does not apply here. The
  # consequence is written out rather than worked around: every node in this
  # cluster can create and attach volumes inside this account, in this region.
  # That is the price of persistent storage on a cluster with no federation,
  # and it is bounded below by the three conditions on the mutating statements.
  #
  # Describe* calls take no resource-level permission in the EC2 API -- verified
  # against this account, where scoping them produces AccessDenied at runtime.
  # They are therefore scoped by region alone, which still stops the driver from
  # being talked into describing volumes in someone else's region.
  statement {
    sid    = "EbsCsiDescribe"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeSnapshots",
      "ec2:DescribeTags",
      "ec2:DescribeVolumeStatus",
      "ec2:DescribeVolumeTypes",
      "ec2:DescribeVolumes",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [data.aws_region.current.region]
    }
  }

  # CreateVolume is split out for one condition: a volume this driver creates
  # is a volume SPEC says must be encrypted, and `ec2:Encrypted` is only
  # populated for this action. Enforcing it here means the StorageClass's
  # `encrypted: true` is a fact about the account rather than a setting someone
  # can edit without consequence. Without it, an unencrypted CreateVolume
  # succeeds and nothing anywhere objects.
  statement {
    sid       = "EbsCsiCreateVolume"
    effect    = "Allow"
    actions   = ["ec2:CreateVolume"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:volume/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [data.aws_region.current.region]
    }

    condition {
      test     = "Bool"
      variable = "ec2:Encrypted"
      values   = ["true"]
    }
  }

  # Everything else the driver does to a volume. AttachVolume names two
  # resources, so the instance ARN is listed alongside the volume one rather
  # than left to a wildcard; ModifyVolume is here because the chart enables
  # volume resizing, which SPEC uses to grow a full Prometheus TSDB.
  statement {
    sid    = "EbsCsiVolumeLifecycle"
    effect = "Allow"
    actions = [
      "ec2:AttachVolume",
      "ec2:DeleteVolume",
      "ec2:DetachVolume",
      "ec2:ModifyVolume",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:volume/*",
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [data.aws_region.current.region]
    }
  }

  # Snapshots, for the VolumeSnapshotClass the runbooks restore from. Left
  # unencrypted-by-policy for now because a snapshot of a CMK-encrypted volume
  # is itself encrypted, and CreateSnapshot's ec2:Encrypted condition would
  # reject the driver's own default behaviour of inheriting the volume's key.
  statement {
    sid       = "EbsCsiSnapshotLifecycle"
    effect    = "Allow"
    actions   = ["ec2:CreateSnapshot", "ec2:DeleteSnapshot", "ec2:CopySnapshot"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:snapshot/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [data.aws_region.current.region]
    }
  }

  # Tagging. CreateTags is scoped to volumes and snapshots in this region, and
  # the ec2:CreateAction condition stops the driver from using tags to alter an
  # action it was not granted -- the same trick that makes an untagged volume
  # unattributable after the fact.
  statement {
    sid     = "EbsCsiTagging"
    effect  = "Allow"
    actions = ["ec2:CreateTags", "ec2:DeleteTags", "ec2:ListTagsForResource"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:volume/*",
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:snapshot/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [data.aws_region.current.region]
    }
  }

  # Alertmanager signs its SNS calls with the node's instance profile (SigV4,
  # no stored credential), so this grant is what lets a page leave the cluster.
  # Without it every notification failed with a 403 that only the alertmanager
  # log recorded. One action, one topic: the topic bootstrap/ owns.
  statement {
    sid       = "AlertPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [local.alerts_topic_arn]
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
