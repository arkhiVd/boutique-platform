# ===========================================================================
# Phase 3 -- the cluster. Everything above this file in the stack plans clean and
# costs $0.00; this file is where the account starts billing, so the plan has to
# be read line by line before the apply.
#
# THE SHAPE (SPEC.md, "Scheduling model"):
#   4 x t3.small -- three as k3s servers (one per AZ, HA etcd), one as the
#   workload node. ALL FOUR NODES SCHEDULABLE -- no control-plane taint anywhere.
#
# The shape was originally 3 x t3.small + 1 x t3.medium. The apply measured what
# the spec could not: this account rejects RunInstances for t3.medium with
# `InvalidParameterCombination: The specified instance type is not eligible for
# Free Tier` (t3.medium FreeTierEligible=false in us-east-1). Four equal
# t3.small nodes are both launchable and cheaper -- $82.56/mo vs $97.74/mo.
#
# The measured workload is 3850m / 4688Mi of requests. The cluster has 7320m /
# ~6960Mi schedulable across four nodes -- 53% CPU and 67% RAM -- so the layout
# of dedicated servers plus one worker that carries everything would leave
# `boutique` Pending forever and leave the Phase 6 drain test nowhere to drain
# to. With all four nodes schedulable there is roughly half the cluster free on
# both axes. k3s is on the SPEC's side of this decision: it
# labels server nodes node-role.kubernetes.io/control-plane=true and taints
# nothing, which is what kubeadm does too. EKS taints because it pairs its
# control plane with a separate autoscaled worker fleet, and this account has an
# 8.0 vCPU quota and therefore no second fleet.
#
# HOW THE k3s JOIN TOKEN IS HANDLED -- read this before reviewing anything else
# ---------------------------------------------------------------------------
# `aws_ssm_parameter.k3s_token` is created from `value_wo`, a WRITE-ONLY
# attribute, fed by an EPHEMERAL variable. Two verified facts make that airtight:
#
#   1. Terraform refuses to move an ephemeral value into any attribute that is
#      not write-only. Run directly against this Terraform version:
#        "Invalid use of ephemeral value ... Ephemeral values are not valid for
#         "input", because it is not a write-only attribute and must be persisted
#         to state."
#      so getting this wrong fails loudly instead of leaking quietly.
#
#   2. The AWS provider's read path for this resource:
#          if hasWriteOnly { d.Set("value", nil) }   // value never stored
#          else             { d.Set("value", param.Value) }
#      (hashicorp/terraform-provider-aws@v6.68.0, internal/service/ssm/parameter.go,
#      resourceParameterRead). With `value_wo` in play the parameter's value is
#      never written into the state.
#
# Measured on the scratch configuration this design was validated against:
#   terraform plan -out=tfplan ; terraform show -json tfplan | grep -c <token>  -> 0
#   grep -c <token> tfplan                                                     -> 0
# so the token is in neither the plan, the saved plan file, the state, nor git.
# The node reads it from SSM at boot; nothing else ever holds it in cleartext
# except /etc/systemd/system/k3s.service.env on the node, which the k3s installer
# itself creates with mode 0600.
#
# WHAT THIS COSTS IN CEREMONY -- the honest downside
#   An ephemeral variable cannot have a default, so every Terraform command must
#   be given a value:
#       TF_VAR_k3s_token="$(openssl rand -hex 32)" terraform plan
#       TF_VAR_k3s_token="..."                       terraform apply
#   A sensitive variable with no default cannot be prompted for in a
#   non-interactive shell, so the value comes from the environment or from a
#   gitignored tfvars file. It must never be typed into a tracked file. This is
#   recorded in TASKS.md as the operational cost of the decision.
#
#   THE REJECTED ALTERNATIVE, and why. `random_password` + `value` puts the token
#   in the state file in cleartext, where anyone with s3:GetObject on the state
#   bucket plus `terraform show` has it -- and the state bucket is precisely the
#   asset this account cannot afford to lose. SPEC.md's exit criterion for this
#   phase is "no k3s token in terraform.tfstate or in git, proven by
#   `terraform show -json | grep -c token`", and only the write-only path
#   satisfies it.
#
# ROTATION
#   aws ssm put-parameter --name /boutique-platform/k3s/token --type SecureString \
#     --key-id "$(terraform -chdir=platform output -raw kms_key_arn)" \
#     --value "$(openssl rand -hex 32)" --overwrite
#   and then re-join any node that must accept the new token: kubelet reads the
#   token only at node registration, so the next instance to (re)join uses it and
#   the previous one stops working for new nodes at that point. The Terraform
#   path is `terraform apply -var k3s_token=<new> -var k3s_token_version=2`,
#   where the version integer is what makes the provider re-issue the parameter.
# ===========================================================================

locals {
  # Verified live on 2026-10-09: `curl -s
  # https://update.k3s.io/v1-release/channels/stable` resolves to exactly this
  # build. The SPEC's pinned-versions table carries the same string.
  k3s_version = "v1.36.5+k3s1"

  # Traefik and klipper-lb are removed: Phase 5 installs Traefik from a Helm
  # chart, which is the only way to get real host routes, the p99 histogram
  # buckets the latency SLO needs, and a Service that matches the Phase 5 ALB
  # target group; and NLB capacity in this account is 0, so a Service of type
  # LoadBalancer is never going to be satisfied. coredns, local-storage and
  # metrics-server are deliberately left enabled -- every HPA in
  # apps/boutique/ is CPU-utilisation based and has no second metrics source.
  k3s_extra_flags = "--disable traefik --disable servicelb"

  # The agent gets NONE of those flags. `--disable` and `--servicelb` are
  # server-only options; passing them to `k3s agent` is rejected outright
  # (`Incorrect Usage: flag provided but not defined: -disable`) and the agent
  # crash-loops forever. Measured on 2026-10-14: the worker had 425 restarts
  # because bootstrap_conf_worker reused k3s_extra_flags above.
  k3s_extra_flags_worker = ""

  # A plain String, not a secret: the private address of the leader node, which
  # the followers read at boot to know what to join. Keeping it in SSM instead of
  # baking a join URL into each node's user_data is what makes a leader
  # replacement non-destructive -- the parameter follows the new address and no
  # follower has to be replaced.
  # The Phase 2 node policy already grants s3:PutObject under this prefix; the
  # bucket itself is created in Phase 4 (etcd-backup.tf), and its name is the
  # local already defined in data.tf so the two cannot drift apart on a literal.
  etcd_snapshot_folder = "etcd-snapshots"

  # The SPEC pins one server per AZ, so the AZ is the one identity a node can
  # establish for itself from instance metadata -- no ec2:Describe* grant, no
  # cloud controller manager, no extra IAM to widen. An instance's AZ does not
  # change when it is replaced, so a replaced leader is discovered as the leader
  # by its replacement.
  leader_az = local.azs[0]

  # The workload node lands in the third AZ so the cluster keeps at least one
  # node in each of the three AZs, and losing any single AZ still leaves three
  # schedulable nodes (two servers plus the worker).
  worker_az = local.azs[2]

  # The config block rendered into cluster-bootstrap.sh, and into the etcd
  # snapshot script that cluster-bootstrap.sh writes out. Two blocks, differing
  # only in the node role, because the role a node takes (leader / follower /
  # agent) is decided at boot from its AZ and not at plan time -- which is also
  # why the launch template content is identical for all three servers.
  bootstrap_conf_server = join("\n", [
    "K3S_VERSION='${local.k3s_version}'",
    "K3S_NODE_ROLE='server'",
    "K3S_LEADER_AZ='${local.leader_az}'",
    "K3S_EXTRA_FLAGS='${local.k3s_extra_flags}'",
    "K3S_TOKEN_PARAMETER='${local.k3s_token_parameter_name}'",
    "K3S_LEADER_IP_PARAMETER='${local.k3s_leader_ip_parameter_name}'",
    "K3S_SNAPSHOT_BUCKET='${local.etcd_snapshot_bucket_name}'",
    "K3S_SNAPSHOT_FOLDER='${local.etcd_snapshot_folder}'",
    "AWS_REGION='${data.aws_region.current.region}'",
    "K3S_SSM_WAIT_SECONDS='${var.ssm_parameter_wait_seconds}'",
    "K3S_API_WAIT_SECONDS='${var.api_ready_wait_seconds}'",
  ])

  bootstrap_conf_worker = join("\n", [
    "K3S_VERSION='${local.k3s_version}'",
    "K3S_NODE_ROLE='worker'",
    "K3S_LEADER_AZ='${local.leader_az}'",
    "K3S_EXTRA_FLAGS='${local.k3s_extra_flags_worker}'",
    "K3S_TOKEN_PARAMETER='${local.k3s_token_parameter_name}'",
    "K3S_LEADER_IP_PARAMETER='${local.k3s_leader_ip_parameter_name}'",
    "K3S_SNAPSHOT_BUCKET='${local.etcd_snapshot_bucket_name}'",
    "K3S_SNAPSHOT_FOLDER='${local.etcd_snapshot_folder}'",
    "AWS_REGION='${data.aws_region.current.region}'",
    "K3S_SSM_WAIT_SECONDS='${var.ssm_parameter_wait_seconds}'",
    "K3S_API_WAIT_SECONDS='${var.api_ready_wait_seconds}'",
  ])
}

# ---------------------------------------------------------------------------
# KMS -- one customer managed key for the two things in this stack that are
# encrypted at rest: the nodes' gp3 root volumes and the k3s join token.
#
# It is a CMK rather than the default aws/ebs and aws/ssm managed keys because the
# key policy below is the only place the *node role* can be named as a principal
# for Decrypt. With the managed keys, every principal in the account that can
# call GetParameter can read any SecureString, which is exactly the shape
# SPEC.md's least-privilege section rules out. Cost: $1.00/month plus $0.03 per
# 10,000 requests -- a line the SPEC's cost table does not yet carry, recorded in
# TASKS.md rather than quietly absorbed.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "platform" {
  description             = "boutique-platform: gp3 root volumes and the k3s join token"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = data.aws_iam_policy_document.kms_platform.json

  tags = {
    Name = "boutique-platform"
  }
}

# `alias/boutique-platform` is the name the documented rotation command uses, so
# an operator never has to paste a key ARN into a shell.
resource "aws_kms_alias" "platform" {
  name          = "alias/boutique-platform"
  target_key_id = aws_kms_key.platform.key_id
}

# The key policy. Statements 2 and 3 are the two that do the work:
#
#   2. EC2, so the launch template can attach a CMK-encrypted volume. EC2 needs
#      Encrypt/Decrypt/ReEncrypt*/GenerateDataKey*/DescribeKey for the volume
#      itself ("Requirements for Amazon EBS encryption", docs.aws.amazon.com).
#   3. The node role: Decrypt for the SecureString, the volume set for launching
#      instances, and CreateGrant on its own statement below.
#
# Statement 1 is not optional: a CMK whose policy does not let the account root
# administer it cannot be managed through IAM at all. So the alternative to this
# statement is a key nobody can ever rotate, re-encrypt, or destroy.
#
# The skip below is on the line directly above the block because that is the only
# placement checkov parses for an inline skip. The reason it is a skip and not a
# rewrite: `kms:*` on `*` in a KEY policy is not a wildcard grant to the account,
# because the resource of a key policy is the key it is attached to. The two
# statements below that actually delegate use ARE narrowed -- EC2 with a
# kms:CallerAccount condition, the node role with kms:GrantIsForAWSResource.
data "aws_iam_policy_document" "kms_platform" {
  # checkov:skip=CKV_AWS_109:A key policy's resource is the key itself, so `kms:*` on `*` is not a wildcard grant to the account; AWS requires an account-root administration statement or the key cannot be managed through IAM at all, and the two statements that do delegate use are narrowed (EC2 with a kms:CallerAccount condition, the node role with kms:GrantIsForAWSResource).
  statement {
    sid       = "AccountRootAdministersTheKey"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "Ec2AttachesVolumesEncryptedWithThisKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "NodeRoleReadsTokenAndAttachesVolumes"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:ReEncrypt*",
      "kms:GenerateDataKeyWithoutPlaintext",
      # Added 2026-10-15, the other half of the etcd snapshot failure: the
      # node role's identity policy already allowed GenerateDataKey after the
      # `EtcdSnapshotKms` statement landed in iam-nodes.tf, but a customer-managed
      # key requires BOTH sides to allow, and the key policy only delegated the
      # WithoutPlaintext form (volume attachments never need the plaintext key).
      # Without this the upload still fails with
      #   "no identity-based policy allows the kms:GenerateDataKey action"
      # because the identity statement alone cannot override the key policy.
      "kms:GenerateDataKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.boutique_node.arn]
    }
  }

  statement {
    sid    = "NodeRoleCreatesGrantsForAwsResourcesOnly"
    effect = "Allow"
    # Deliberately separate from the statement above: a kms:GrantIsForAWSResource
    # condition would make the Decrypt permanently fail, because that condition key
    # is only present on grant requests. AWS's own guidance is that unrestricted
    # CreateGrant is the difference between "attach a volume" and "hand this key
    # to anything in the account".
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.boutique_node.arn]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    sid    = "CloudWatchLogsEncryptsTheWafLogGroup"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    # Needed, and the account root statement above does NOT cover it. CloudWatch
    # Logs does not encrypt as the caller: it encrypts as the service, so the
    # key must name the service principal. Probed on 2026-10-14 rather than
    # assumed — with only the root and EC2 statements in place,
    #   aws logs create-log-group --kms-key-id <this key>
    # returned `AccessDeniedException: The specified KMS key does not exist or
    # is not allowed to be used with Arn '...log-group:/aws/waf/...'`, while the
    # identical call without a KMS key succeeded. That is why the first apply
    # failed on aws_cloudwatch_log_group.waf.
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }

    # Scoped to this account's WAF log groups rather than to `*`. CloudWatch
    # Logs sends the log group ARN as an encryption context key, so this is what
    # stops the log-delivery principal from using the CMK against anything else.
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values = [
        "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:aws-waf-logs-*",
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# The k3s join token, as a SecureString under the CMK above.
#
# `value_wo` is write-only and `var.k3s_token` is ephemeral, so the value is
# passed to PutParameter and then dropped: it is not in the plan, not in the plan
# file, not in the state. See the file header for the two verified facts that
# make this true, and for the rejected random_password alternative.
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "k3s_token" {
  name        = local.k3s_token_parameter_name
  description = "k3s join token. Written by Terraform from a write-only attribute, read by every node's cloud-init at boot. Never in state or git; rotate with the command in platform/README.md."
  type        = "SecureString"
  key_id      = aws_kms_key.platform.arn
  tier        = "Standard"

  value_wo         = var.k3s_token
  value_wo_version = var.k3s_token_version

  # Deliberate: a rebuild after a destroy finds a leftover parameter and would
  # otherwise fail with ParameterAlreadyExists.
  overwrite = true

  tags = {
    Name = local.k3s_token_parameter_name
  }
}

# ---------------------------------------------------------------------------
# Where the leader is. A plain String: the followers read it at boot to build
# their `--server https://<ip>:6443` argument, which is why it has to be
# somewhere a node can read without holding an AWS key.
#
# The value is addressed through the for_each key rather than through a
# comprehension over the whole resource, so this parameter depends on the leader
# instance alone. Depending on the whole resource would serialise all three
# servers behind it; depending on the leader alone lets the two followers start
# in parallel with it, and their cloud-init polls for this value with a deadline
# instead (platform/cluster-bootstrap.sh, step 3).
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "k3s_leader_ip" {
  name        = local.k3s_leader_ip_parameter_name
  description = "Private address of the designated k3s leader node. Read by the two followers and by the workload node at boot to build their --server join argument."
  type        = "String"
  tier        = "Standard"

  value = aws_instance.k3s_server[local.leader_az].private_ip

  tags = {
    Name = local.k3s_leader_ip_parameter_name
  }
}

# The one AMI the whole cluster runs, read from SSM's public parameter rather
# than a pinned AMI ID, so the cluster is not silently running an image the
# operator never chose to freeze; `aws ssm get-parameter --name
# /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` is the
# value that lands in state and it is reviewable in the plan.
#
# Amazon Linux 2023 is the base because it ships the SSM agent, the AWS CLI and
# cloud-init already installed, and because the k3s install script handles it
# explicitly: setup_selinux() detects an rpm-based distro, installs
# container-selinux from the AL2023 repositories and then the k3s-selinux policy
# on top of it (k3s install.sh, the "setup selinux policy" block).
data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# Launch templates -- one per node role, exactly as the phase lists it.
#
# Both render the SAME bootstrap script with a different NODE_ROLE in the config
# block, because the role a node takes (leader / follower / agent) is decided at
# boot from its AZ, not at plan time. That is what keeps the template content
# identical across all three servers and makes a template edit one place in the
# plan to read.
#
# NOT in here: `key_name`. There is no key pair anywhere in this stack, no sshd
# rule on any security group, and no authorized_keys written by user_data.
# SPEC.md's trust boundary 3 is SSM Session Manager or nothing, and the
# acceptance criterion for it -- `aws ec2 describe-instances` showing
# `KeyName: null` -- is true precisely because this attribute is absent.
#
# A user_data change updates the template in place as a NEW VERSION that is not
# promoted to default, and it does NOT replace a running instance, because EC2
# reads the template at RunInstances time. Editing the bootstrap script is
# therefore a documented `terraform apply -replace` decision (platform/README.md),
# not a surprise -- and the instances below pin `version = "$Latest"` so that
# replace actually boots the edit. Measured 2026-10-14: server template
# LatestVersionNumber=3 / DefaultVersionNumber=1.
# ---------------------------------------------------------------------------
resource "aws_launch_template" "k3s_server" {
  # checkov:skip=CKV_AWS_341:Hop limit 2 is deliberate and load-bearing, not sloppy. The EBS CSI node plugin reads IMDS from a pod network namespace, which is one hop further out than the instance; at the default TTL of 1 the response expires before it reaches the pod and the driver fails to authenticate. Measured 2026-10-14: hop limit 1 broke the driver, hop limit 2 fixed it (this file's metadata_options block). IMDSv2 stays required; only the hop count moves.
  name_prefix = "boutique-k3s-server-"
  description = "boutique-platform k3s server: one c7i-flex.large leader + two t3.small followers, one per AZ, HA etcd. user_data renders platform/cluster-bootstrap.sh."
  image_id    = data.aws_ssm_parameter.amazon_linux_2023.value
  # No `instance_type` here: the shape differs by role (see
  # var.instance_type_servers) and RunInstances takes it from the instance
  # resource below, which is the only place the per-AZ choice is visible.

  iam_instance_profile {
    name = aws_iam_instance_profile.boutique_node.name
  }

  # The three groups from Phase 2. 6443/tcp reaches a node only from
  # var.admin_cidr (boutique-node-api); everything node-to-node -- flannel VXLAN
  # 8472/udp, kubelet 10250, etcd 2379-2380, and apiserver server-to-server --
  # is the self-referencing boutique-node-internal group; boutique-node-admin is
  # attached for completeness and carries no ingress rule at all.
  vpc_security_group_ids = [
    aws_security_group.boutique_node_admin.id,
    aws_security_group.boutique_node_api.id,
    aws_security_group.boutique_node_internal.id,
  ]

  # base64gzip, not base64encode. EC2 caps user data at 16384 bytes and counts
  # the DECODED size, and cluster-bootstrap.sh is 17223 bytes on its own before
  # either substitution -- CreateLaunchTemplate rejected both templates on the
  # first apply (2026-10-14) with `InvalidUserData.Malformed: User data is
  # limited to 16384 bytes.` gzip brings the same script well under the cap, and
  # cloud-init decompresses it: it tests for the gzip magic bytes before
  # parsing, so nothing in the script changes.
  user_data = base64gzip(replace(
    replace(
      file("${path.module}/cluster-bootstrap.sh"),
      "BOUTIQUE_BOOTSTRAP_CONF", local.bootstrap_conf_server,
    ),
    "BOUTIQUE_ETCD_SNAPSHOT_SCRIPT", file("${path.module}/etcd-snapshot.sh"),
  ))

  # Detailed monitoring is a real line on the bill -- $0.30 per instance per
  # month, $0.42 over the remaining window -- and it is paid on purpose: the
  # SPEC's U2 risk is that a t3 sustains 20% of a vCPU and the cluster quietly
  # spends CPU credits, and the only way to see that after the fact is
  # one-minute CloudWatch metrics on every node.
  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 only, not "optional": with http_tokens = "required", a token-less
    # request never gets an answer.
    #
    # Hop limit 2, not 1, and the reason is the EBS CSI driver. A container's
    # network namespace is one hop further out than the instance, so a response
    # with TTL 1 expires before it reaches the pod. The driver reads the node
    # instance profile for credentials and IMDS for region and availability
    # zone, so with hop limit 1 it fails at startup with three errors that look
    # unrelated and are one fault:
    #
    #   "Retrieving IMDS metadata failed" err="... context deadline exceeded"
    #   "Retrieving Kubernetes metadata failed" err="could not retrieve region
    #    from topology label"
    #   "Failed to initialize metadata when it is required" err="all specified
    #    --metadata-sources '[imds kubernetes]' are unavailable"
    #
    # Measured on all four nodes on 2026-10-14, after the first install of
    # cluster/ebs-csi left every node plugin in CrashLoopBackOff. Hop limit 2 is
    # the same setting EKS uses by default, and it is not a downgrade: IMDSv2
    # is still required, so an off-instance caller still cannot mint a token,
    # and hop limit 2 still does not make the endpoint reachable from outside
    # the instance. What it buys is that a pod on the node can.
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.platform.arn
      delete_on_termination = true
      # gp3 defaults, stated explicitly so a later provider or API change to
      # volume defaults cannot produce a phantom in-place update.
      iops       = 3000
      throughput = 125
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "boutique-k3s-server"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name               = "boutique-k3s-server"
      "boutique.io/role" = "server"
    }
  }

  tags = {
    Name = "boutique-k3s-server-lt"
  }
}

# The one worker. A separate template rather than a variant flag because its node
# role, instance type, AZ and volume are all different -- and those are exactly
# the four things a reader wants side by side.
resource "aws_launch_template" "k3s_worker" {
  # checkov:skip=CKV_AWS_341:Same deliberate hop limit 2 as the server template: a pod network namespace is one hop out, and the EBS CSI driver reads IMDS through it. See the server template's metadata_options block for the measured failure; IMDSv2 stays required.
  name_prefix   = "boutique-k3s-worker-"
  description   = "boutique-platform k3s workload node: t3.small (this account rejects t3.medium -- FreeTierEligible=false), schedulable, no control-plane taint. user_data renders platform/cluster-bootstrap.sh."
  image_id      = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type = var.instance_type_worker

  iam_instance_profile {
    name = aws_iam_instance_profile.boutique_node.name
  }

  vpc_security_group_ids = [
    aws_security_group.boutique_node_admin.id,
    aws_security_group.boutique_node_api.id,
    aws_security_group.boutique_node_internal.id,
  ]

  # base64gzip, not base64encode. EC2 caps user data at 16384 bytes and counts
  # the DECODED size, and cluster-bootstrap.sh is 17223 bytes on its own before
  # either substitution -- CreateLaunchTemplate rejected both templates on the
  # first apply (2026-10-14) with `InvalidUserData.Malformed: User data is
  # limited to 16384 bytes.` gzip brings the same script well under the cap, and
  # cloud-init decompresses it: it tests for the gzip magic bytes before
  # parsing, so nothing in the script changes.
  user_data = base64gzip(replace(
    replace(
      file("${path.module}/cluster-bootstrap.sh"),
      "BOUTIQUE_BOOTSTRAP_CONF", local.bootstrap_conf_worker,
    ),
    "BOUTIQUE_ETCD_SNAPSHOT_SCRIPT", file("${path.module}/etcd-snapshot.sh"),
  ))

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Hop limit 2 for the same reason the launch template says so at length:
    # hop 1 is IMDSv2-only AND pod-invisible, which stops the EBS CSI driver
    # from reaching the instance profile it authenticates with. Repeated here
    # rather than inherited because RunInstances reads this block, not the
    # template's, when both are present.
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.platform.arn
      delete_on_termination = true
      iops                  = 3000
      throughput            = 125
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "boutique-k3s-worker"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name               = "boutique-k3s-worker"
      "boutique.io/role" = "worker"
    }
  }

  tags = {
    Name = "boutique-k3s-worker-lt"
  }
}

# ---------------------------------------------------------------------------
# The three servers, one per AZ.
#
# `for_each` over local.azs IS the one-per-AZ contract: three AZs, three subnets,
# three instances, and an etcd quorum of three with any one node lost. There is no
# `count = 3` here that could drift onto two AZs.
# ---------------------------------------------------------------------------
resource "aws_instance" "k3s_server" {
  for_each = toset(local.azs)

  ami = data.aws_ssm_parameter.amazon_linux_2023.value
  # The one per-role asymmetry: the leader (local.leader_az) gets the large
  # shape, the two followers the small one. Set here and not on the launch
  # template because the template is shared and the role is decided by AZ.
  instance_type = each.value == local.leader_az ? var.instance_type_servers.leader : var.instance_type_servers.followers
  subnet_id     = aws_subnet.boutique[each.value].id

  launch_template {
    id = aws_launch_template.k3s_server.id
    # $Latest, not $Default. Measured 2026-10-14: the server template had
    # LatestVersionNumber=3 with DefaultVersionNumber=1, because
    # CreateLaunchTemplateVersion never promotes the new version to default.
    # EC2 resolves $Default at RunInstances time, so a -replace'd node launched
    # the ORIGINAL user_data (464 lines, no --cluster-init) even though the
    # template held the fixed one (v3). $Latest is the version that actually
    # contains the edit being bootstrapped.
    version = "$Latest"
  }
  iam_instance_profile = aws_iam_instance_profile.boutique_node.name

  # Repeated from the launch template, on purpose, and this is the one place the
  # duplication is worth it: EC2 takes these from the launch template at
  # RunInstances, but they are the four controls a reviewer checks first (IMDSv2,
  # monitoring, EBS optimisation, an instance profile with no keys), and having to
  # follow a reference into another resource to see them is how a hardening
  # regression gets approved. The values are identical; there is nothing to keep in
  # sync beyond editing both.
  #   instance_profile    the only role in the account a node may assume
  #   monitoring          1-minute metrics: the SPEC's U2 t3-credit risk is
  #                       sustained CPU, and this is how it is observed
  #   ebs_optimized       the t3 default, asserted
  #   metadata_options    IMDSv2 only, hop limit 2, no instance metadata tags
  # `monitoring` is a bool here, not a block -- the launch template's nested form
  # does not match the resource's, which is one of the small sharp edges of
  # putting configuration in both places.
  monitoring = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Hop limit 2 for the same reason the launch template says so at length:
    # hop 1 is IMDSv2-only AND pod-invisible, which stops the EBS CSI driver
    # from reaching the instance profile it authenticates with. Repeated here
    # rather than inherited because RunInstances reads this block, not the
    # template's, when both are present.
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  ebs_optimized = true

  # The root volume is NOT repeated here. Encryption, the volume type, the CMK and
  # the size are declared once, on the launch template's block_device_mappings,
  # which is what RunInstances uses -- and repeating a volume on the resource
  # itself would create two blocks that have to agree to the byte or Terraform
  # plans a perpetual in-place update on every run.
  # checkov:skip=CKV_AWS_8:The root volume is encrypted on the launch template
  # (aws_launch_template.k3s_server/k3s_worker: volume_type gp3, encrypted true,
  # kms_key_id = this stack's CMK). Checkov does not resolve a launch template
  # reference from the instance, and it reports this as unencrypted. Copying the
  # block here would be the only way to turn it green, at the cost of two volume
  # definitions that must agree exactly and a permanent diff when they drift.

  tags = {
    Name               = "boutique-k3s-server-${each.value}"
    "boutique.io/role" = "server"
    "boutique.io/az"   = each.value
  }

  lifecycle {
    # The tags a cloud controller manager would add if one ran here. k3s ships no
    # in-tree AWS provider (pkg/daemons/agent/agent_linux.go: kubelet gets
    # --cloud-provider=external and k3s's own internal CCM does node
    # initialisation with no AWS API calls), so nothing writes these today. The
    # ignore is defensive, and it is also what makes SPEC.md's "a second plan is
    # empty" criterion hold on the day someone installs the out-of-tree AWS cloud
    # controller manager for the Phase 5 ALB integration.
    # Launch template version is immutable after launch, and AWS returns it
    # resolved: state holds "6" while the config holds "$Latest", so without
    # this the next plan ForceNew'd all four nodes over a difference that can
    # only ever take effect at boot. The version a node boots from is decided
    # by RunInstances; changing it afterwards is what platform/README.md's
    # explicit `terraform apply -replace` is for.
    ignore_changes = [
      launch_template,
      # The user_data EC2 returned at launch. The instance resource copies the
      # launch template's value into state even though the template owns it, so
      # every plan after the first shows a removal -- and the apply that
      # enforces it stops and starts the instance (measured on the 2026-10-15
      # resize plan: all four nodes). The template is the source of truth; a
      # bootstrap edit reaching a RUNNING node is a documented `-replace`,
      # never an in-place stop.
      user_data,
      tags["node.kubernetes.io/instance-type"],
      tags["kubernetes.io/cluster/boutique-platform"],
      tags_all,
    ]
  }

  # A node that cannot read the join token has no business reporting Ready, so
  # the instances wait for the parameter rather than racing it.
  depends_on = [aws_ssm_parameter.k3s_token]
}

# ---------------------------------------------------------------------------
# The workload node, in the third AZ.
#
# No taint, no nodeSelector restriction, nothing: SPEC.md's scheduling model is
# that this node is a normal member of a four-node schedulable pool, not the only
# place work may run.
#
# It depends on the leader-ip parameter, so Terraform refuses to launch a worker
# that would have no leader to find. The two followers inside
# aws_instance.k3s_server do NOT have that dependency -- they are in the same
# resource as the leader, so depending on the parameter would be a cycle -- and
# poll for it with a deadline instead. Same behaviour, decided once the node is up
# rather than once the apply plans.
# ---------------------------------------------------------------------------
resource "aws_instance" "k3s_worker" {
  ami           = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type = var.instance_type_worker
  subnet_id     = aws_subnet.boutique[local.worker_az].id

  launch_template {
    id = aws_launch_template.k3s_worker.id
    # $Latest: see the note on the server block -- $Default stayed at version 1
    # across four template revisions and silently served stale bootstrap code.
    version = "$Latest"
  }
  iam_instance_profile = aws_iam_instance_profile.boutique_node.name

  # Repeated from the launch template, on purpose, and this is the one place the
  # duplication is worth it: EC2 takes these from the launch template at
  # RunInstances, but they are the four controls a reviewer checks first (IMDSv2,
  # monitoring, EBS optimisation, an instance profile with no keys), and having to
  # follow a reference into another resource to see them is how a hardening
  # regression gets approved. The values are identical; there is nothing to keep in
  # sync beyond editing both.
  #   instance_profile    the only role in the account a node may assume
  #   monitoring          1-minute metrics: the SPEC's U2 t3-credit risk is
  #                       sustained CPU, and this is how it is observed
  #   ebs_optimized       the t3 default, asserted
  #   metadata_options    IMDSv2 only, hop limit 2, no instance metadata tags
  # `monitoring` is a bool here, not a block -- the launch template's nested form
  # does not match the resource's, which is one of the small sharp edges of
  # putting configuration in both places.
  monitoring = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Hop limit 2 for the same reason the launch template says so at length:
    # hop 1 is IMDSv2-only AND pod-invisible, which stops the EBS CSI driver
    # from reaching the instance profile it authenticates with. Repeated here
    # rather than inherited because RunInstances reads this block, not the
    # template's, when both are present.
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  ebs_optimized = true

  # The root volume is NOT repeated here. Encryption, the volume type, the CMK and
  # the size are declared once, on the launch template's block_device_mappings,
  # which is what RunInstances uses -- and repeating a volume on the resource
  # itself would create two blocks that have to agree to the byte or Terraform
  # plans a perpetual in-place update on every run.
  # checkov:skip=CKV_AWS_8:The root volume is encrypted on the launch template
  # (aws_launch_template.k3s_server/k3s_worker: volume_type gp3, encrypted true,
  # kms_key_id = this stack's CMK). Checkov does not resolve a launch template
  # reference from the instance, and it reports this as unencrypted. Copying the
  # block here would be the only way to turn it green, at the cost of two volume
  # definitions that must agree exactly and a permanent diff when they drift.

  tags = {
    Name               = "boutique-k3s-worker"
    "boutique.io/role" = "worker"
    "boutique.io/az"   = local.worker_az
  }

  lifecycle {
    # Launch template version is immutable after launch, and AWS returns it
    # resolved: state holds "6" while the config holds "$Latest", so without
    # this the next plan ForceNew'd all four nodes over a difference that can
    # only ever take effect at boot. The version a node boots from is decided
    # by RunInstances; changing it afterwards is what platform/README.md's
    # explicit `terraform apply -replace` is for.
    ignore_changes = [
      launch_template,
      tags["node.kubernetes.io/instance-type"],
      tags["kubernetes.io/cluster/boutique-platform"],
      tags_all,
      # Same class as the launch-template ignore above: user_data is
      # launch-time input owned by the template, and the instance's copy of
      # it is state noise whose "fix" is a needless stop/start. See the
      # matching comment on the server instances.
      user_data,
    ]
  }

  depends_on = [
    aws_ssm_parameter.k3s_token,
    aws_ssm_parameter.k3s_leader_ip,
  ]
}

# ---------------------------------------------------------------------------
# Stable public addresses
#
# The public IPv4 handed out at launch is released the instant the instance
# stops, and `aws_instance`'s user_data update path IS stop -> modify -> start
# (CloudTrail, 2026-10-14: StopInstances 12:06:57Z, ModifyInstanceAttribute
# 12:07:17Z, StartInstances 12:07:19Z). On restart k3s comes back under the
# unit cloud-init wrote on first boot, so its `--tls-san` still names an
# address that no longer exists. Measured consequence: the apiserver serving
# cert and ~/.kube/boutique-prod.yaml both went stale and `kubectl` timed out
# while the ALB -- which targets private IPs -- was reporting every target
# healthy. An Elastic IP survives stop/start, so address, cert SAN and
# kubeconfig stay true across every replacement.
#
# Cost is $0.005/h for each UNATTACHED address in this region. These are
# attached to running instances for the life of the platform, so the running
# cost is zero; the line item only appears if a node is stopped and left
# stopped while holding its address.
resource "aws_eip" "k3s_server" {
  for_each = toset(local.azs)
  domain   = "vpc"
  instance = aws_instance.k3s_server[each.key].id

  tags = {
    Name               = "boutique-k3s-server-${each.key}"
    "boutique.io/role" = "server"
    "boutique.io/az"   = each.key
  }

  # An IGW must exist before a VPC-domain address can be allocated.
  depends_on = [aws_internet_gateway.boutique]
}

# The worker never names itself in a cert or a kubeconfig, so its address only
# has to stop rotating. Same resource for the same reason: uniformity across
# the fleet is cheaper to reason about than a rule with one exception.
resource "aws_eip" "k3s_worker" {
  domain   = "vpc"
  instance = aws_instance.k3s_worker.id

  tags = {
    Name               = "boutique-k3s-worker"
    "boutique.io/role" = "worker"
    "boutique.io/az"   = local.worker_az
  }

  depends_on = [aws_internet_gateway.boutique]
}
