# The one-shot bootstrap: the state bucket, the OIDC provider and the two
# GitHub Actions roles, the Budget, and the alert bus. Local state, one run,
# one owner. README.md has the run procedure.

locals {
  state_bucket_name = "boutique-platform-tfstate-${data.aws_caller_identity.current.account_id}-us-east-1"

  # The node role is created by platform/iam-nodes.tf. The name is the only
  # contract between the two stacks: nothing here can read the platform state.
  node_role_name        = "boutique-platform-node"
  node_instance_profile = "boutique-platform-node"
  github_repository     = "arkhiVd/boutique-platform"
  # The repository opted into GitHub's immutable OIDC subject, which names the
  # owner and repo by id as well as by name. A trust policy written only for
  # the legacy `repo:owner/name:` form matches no token at all, and that is why
  # the plan gate could never assume its role (found 2026-10-17 from
  # GET /repos/{repo}/actions/oidc/customization/sub). Both forms are trusted:
  # the ids pin this exact repository even across a rename.
  github_repository_immutable = "arkhiVd@95763443/boutique-platform@1410757654"

  github_oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github_actions[0].arn : var.existing_oidc_provider_arn
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# The real TLS thumbprint of the GitHub Actions OIDC endpoint, read at plan
# time from the endpoint itself. IAM no longer validates the thumbprint for
# a well-known issuer, but it is still required by the API, and a copied one
# goes stale without notice.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

# ---------------------------------------------------------------------------
# State bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  # checkov:skip=CKV_AWS_18:Access logging would need a second bucket to log to,
  # and this bucket holds no object whose presence is a secret. Lifecycle + SSE
  # + public access block are the controls that matter; the log bucket is a
  # Phase 5 edge concern.
  #
  # checkov:skip=CKV_AWS_144:Cross-region replication doubles the state footprint
  # for a lab stack that is destroyed at Phase 14. Snapshots are out of scope.
  #
  # checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is the SPEC decision: a customer
  # managed key is ~$1/mo against a $30 budget, and Terraform state for this
  # repo is checked against gitleaks precisely because it must hold no secrets.
  #
  # checkov:skip=CKV2_AWS_62:Event notifications are meaningless for a state
  # bucket nobody reads except the apply job.

  tags = {
    Name = local.state_bucket_name
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # Versioned state grows one object per apply. Noncurrent versions are
    # dead weight after the merge they belong to; the bucket keeps the current
    # file and every version made in the last 30 days.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Clean up the multipart debris a killed apply leaves behind.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = {
    Name = "github-actions"
  }
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    sid     = "GitHubActionsOidc"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    # GitHub's OIDC token carries a single aud, so StringEquals pins it exactly.
    # ForAnyValue would be the same test on a multi-valued key.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike rather than StringEquals because the environment name is a
    # wildcard. The repo path is anchored, so no other repository in any
    # account can assume these roles.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.github_repository}:environment:*",
        "repo:${local.github_repository_immutable}:environment:*",
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# plan role — read-only twin of the apply role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = "boutique-platform-plan"
  description          = "Read-only. Assumed by the PR plan gate; can read the Terraform state and describe the account, nothing else."
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume.json
  max_session_duration = 3600

  tags = {
    Name = "boutique-platform-plan"
  }
}

data "aws_iam_policy_document" "plan_readonly" {
  statement {
    sid    = "PlanReadsInventory"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:Get*",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:Get*",
    ]
    # checkov:skip=CKV_AWS_356:The plan role's whole job is reading the account
    # inventory a plan diffs against. Neither EC2 nor ELB has an ARN wildcard
    # that covers Describe/Get across every resource type a VPC holds, and the
    # accounts reads here are pinned to one region by the condition below.

    resources = ["*"]

    # Real least privilege, not decoration: the account uses one region, so a
    # leaked session token is useless anywhere else.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "PlanReadsAccount"
    effect = "Allow"
    actions = [
      "servicequotas:GetAWSDefaultServiceQuota",
      "servicequotas:GetServiceQuota",
      "servicequotas:ListServiceQuotas",
      "sts:GetCallerIdentity",
      "cloudwatch:GetMetricData",
      "ce:GetCostAndUsage",
    ]
    # checkov:skip=CKV_AWS_356:Quota, metric, cost and caller-identity reads
    # return account-level answers and accept no resource ARN. Every action here
    # is a read; there is no write action in this policy at all.
    resources = ["*"]
  }

  statement {
    sid    = "ReadProjectRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
    ]
    # The plan gate diffs the platform stack, whose only role is the node role.
    # Scoped rather than `*` so the role cannot read the account's other roles.
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/boutique-platform-*"]
  }

  # The PR gate plans with -refresh=false (see .github/workflows/plan.yml): the
  # AWS provider refreshes an SSM SecureString WITH decryption even when it was
  # written via value_wo, so a refreshing plan needs kms:Decrypt on the key
  # that guards the k3s join token, and that is not a read a PR gate gets
  # (measured 2026-10-17: AccessDenied on kms:Decrypt for /boutique-platform/k3s/token).
  # Without refresh, the plan still reads every DATA source, and these are the
  # two that the EC2 statement above does not cover.
  statement {
    sid     = "PlanReadsDataSources"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    # The AL2023 AMI id the launch template resolves through a public parameter.
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::parameter/aws/service/*"]
  }

  statement {
    sid    = "ReadTerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "boutique-platform-plan-readonly"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_readonly.json
}

# ---------------------------------------------------------------------------
# apply role — post-merge promotion on main
# ---------------------------------------------------------------------------

resource "aws_iam_role" "apply" {
  name                 = "boutique-platform-apply"
  description          = "Assumed by the post-merge apply on main. Full EC2/ELB/ECR/S3-state write, IAM write only on the platform's own node identity."
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume.json
  max_session_duration = 3600

  tags = {
    Name = "boutique-platform-apply"
  }
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid    = "ReadTerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
  }

  statement {
    sid    = "WriteTerraformState"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads",
    ]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  # Blast radius, stated: this can create and destroy anything EC2 and any load
  # balancer in the account, including running instances. That is what an apply
  # role is for. The controls around it are the plan role above (read-only, same
  # trust), the two Deny statements below, and the $30/mo Budget.
  statement {
    sid    = "NetworkAndCompute"
    effect = "Allow"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
    ]
    resources = ["*"]

    # One region, one account, one project. A leaked session token is bound to
    # us-east-1 and cannot enumerate or mutate a second region.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "Registry"
    effect    = "Allow"
    actions   = ["ecr:*"]
    resources = ["*"]

    # Same constraint as the EC2 statement: one region. It also keeps the
    # ecr:* wildcard off the cloudsplaining unconstrained-write list, because
    # an ECR token can only ever pull from this account's us-east-1 registry.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # The platform stack has to create and maintain the node role, its instance
  # profile and the inline policy that makes the nodes SSM-reachable, so this
  # grants exactly those IAM actions on exactly those two ARNs. Without it the
  # role could pass a role it is forbidden to make.
  statement {
    sid    = "NodeIdentityWrite"
    effect = "Allow"
    actions = [
      # role
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      # instance profile
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.node_role_name}",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${local.node_instance_profile}",
    ]

    # IfExists on both keys, deliberately. iam:CreateRole runs before the role
    # has any resource tag, so only aws:RequestTag is populated; every other
    # action here runs on a role that already carries Project. The Deny below
    # closes the hole that StringEqualsIfExists alone would leave open on an
    # untagged existing role.
    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:ResourceTag/Project"
      values   = ["boutique-platform"]
    }

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/Project"
      values   = ["boutique-platform"]
    }
  }

  statement {
    sid     = "NodeInlinePolicyWrite"
    effect  = "Allow"
    actions = ["iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.node_role_name}",
    ]

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:ResourceTag/Project"
      values   = ["boutique-platform"]
    }
  }

  # AmazonSSMManagedInstanceCore is an AWS-managed policy: it carries no tag and
  # is not editable, so it is exempt from the Project tag rule below.
  statement {
    sid       = "ReadAwsManagedPolicies"
    effect    = "Allow"
    actions   = ["iam:GetPolicy"]
    resources = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/*"]
  }

  statement {
    sid       = "PassNodeRoleToEc2Only"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.node_role_name}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # The SPEC forbids key pairs (nodes are reached through SSM, no port 22) and
  # every instance is Linux, so Windows administrator passwords are meaningless
  # here. Denying these by name also removes them from the ec2:* grant above,
  # which is the point: they cannot be used even accidentally.
  statement {
    sid       = "DenyCredentialExposure"
    effect    = "Deny"
    actions   = ["ec2:GetPasswordData", "ec2:CreateKeyPair", "ec2:ImportKeyPair", "ec2:DeleteKeyPair"]
    resources = ["*"]
  }

  # The guard rail. Every IAM action is denied on anything that is not tagged
  # Project=boutique-platform, which is the default_tags contract on both
  # stacks. Negated operators match when the tag is absent, so an untagged role
  # is denied too; the IfExists variant keeps the statement usable on
  # iam:CreateRole, where the resource does not exist yet and only
  # aws:RequestTag is populated. AWS-managed policies are exempt because they
  # cannot carry tags at all.
  statement {
    sid           = "DenyIamOutsideProject"
    effect        = "Deny"
    actions       = ["iam:*"]
    not_resources = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/*"]

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "aws:ResourceTag/Project"
      values   = ["boutique-platform"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "aws:RequestTag/Project"
      values   = ["boutique-platform"]
    }
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "boutique-platform-apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}

# ---------------------------------------------------------------------------
# Cost guardrails
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name         = "boutique-platform-alerts"
  display_name = "boutique-platform alerts"

  # checkov:skip=CKV_AWS_26:No KMS key. A customer managed key is ~$1/mo for a
  # topic whose entire payload is budget thresholds and cluster alarms, never
  # customer data. Revisit the moment an alert body carries anything secret.
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = data.aws_iam_policy_document.sns_publish.json
}

data "aws_iam_policy_document" "sns_publish" {
  statement {
    sid     = "AllowBudgetsToPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:budgets:${var.aws_region}:${data.aws_caller_identity.current.account_id}:budget/boutique-platform-monthly"]
    }
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  name         = "boutique-platform-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Both notifications go through the SNS topic, whose subscription is
  # var.alert_email, so the budget and the Phase 9+ cluster alarms share one
  # mail path instead of two.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }
}
