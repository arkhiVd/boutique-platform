# ===========================================================================
# Phase 4 -- the etcd snapshot bucket.
#
# WHAT IS IN A k3s SNAPSHOT, and why this bucket is not just "somewhere to put
# a backup". The k3s documentation is explicit: an etcd snapshot is a complete
# copy of the datastore together with the cluster CA certificates and private
# keys, encrypted with an AES-256 key derived from the server join token using
# PBKDF2. "Any attacker who possesses a copy of the etcd snapshot file AND the
# server join token can extract encrypted resources, along with private keys to
# the cluster CAs." That is the whole reasoning behind the three choices below:
# a customer managed key (the join token has the same CMK, so reading the
# snapshot and reading the token need the same grant -- and conversely, the node
# role can read the snapshot only because it can read the token), public access
# blocked on all four flags, and TLS enforced by policy.
#
# WHY THE LIFECYCLE RULE IS THE RETENTION MECHANISM
#   k3s's --etcd-s3-retention is a SERVER flag: it is set on the k3s process and
#   applies to snapshots the server's own scheduler creates. The Phase 3 design
#   uses `k3s etcd-snapshot save` from a systemd timer instead, and that CLI path
#   has no retention argument -- "There is no retention for these on-demand
#   snapshots and the user needs to remove them manually" (docs.k3s.io/cli/
#   etcd-snapshot). So retention here is the bucket's lifecycle rule, not
#   something k3s prunes. That is a deliberate trade, not an oversight: a timer
#   can be inspected, run by hand before a change, and left out of the k3s
#   process's own flags, at the cost of expiry being enforced by S3 rather than
#   by the uploader.
# ===========================================================================

resource "aws_s3_bucket" "etcd_snapshots" {
  bucket = local.etcd_snapshot_bucket_name

  # checkov:skip=CKV_AWS_18:Access logging needs a second bucket to log to, and
  # this bucket holds objects nobody enumerates routinely. The restore drill
  # (scripts/etcd-restore-drill.sh) is the only consumer and it is triggered by
  # hand. Recorded as a real gap rather than a false positive.

  tags = {
    Name = local.etcd_snapshot_bucket_name
  }
}

resource "aws_s3_bucket_public_access_block" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is on, and it is not decoration: it is the only thing that undoes an
# `aws s3 rm` against a snapshot someone needs. Snapshot objects are immutable
# and timestamped, so an overwrite cannot happen; a delete can.
resource "aws_s3_bucket_versioning" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.platform.arn
    }
    bucket_key_enabled = true
  }
}

# The bucket policy. Two statements, both narrow:
#
#   1. The node role -- the writer. It is the identity that actually uploads, and
#      it is named here so the resource side of the grant is reviewable in one
#      place instead of being implied by the absence of a deny. It is the same
#      grant the role's inline policy carries in iam-nodes.tf; a policy on both
#      sides is the belt-and-braces that makes an accidental widening of the
#      inline policy not sufficient on its own.
#
#   2. The account, read-only. The restore drill and the operator need
#      GetObject, and nobody else does. Because the IAM policy is still the other
#      half of every allow, "the account" here means "any principal that already
#      holds s3:GetObject in IAM", not "everyone in the account can list it".
#
# Plus the standard deny on non-TLS, because a snapshot fetched in cleartext is a
# snapshot that did not need to be stolen.
data "aws_iam_policy_document" "etcd_snapshots" {
  statement {
    sid    = "AllowNodeRoleSnapshotWrite"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.etcd_snapshots.arn,
      "${aws_s3_bucket.etcd_snapshots.arn}/${local.etcd_snapshot_folder}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.boutique_node.arn]
    }
  }

  statement {
    sid    = "AllowAccountSnapshotRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.etcd_snapshots.arn,
      "${aws_s3_bucket.etcd_snapshots.arn}/${local.etcd_snapshot_folder}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.etcd_snapshots.arn,
      "${aws_s3_bucket.etcd_snapshots.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id
  policy = data.aws_iam_policy_document.etcd_snapshots.json
}

resource "aws_s3_bucket_lifecycle_configuration" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  rule {
    id     = "expire-etcd-snapshots"
    status = "Enabled"

    filter {
      prefix = "${local.etcd_snapshot_folder}/"
    }

    # The arithmetic, so the number is a decision and not a default: 4 snapshots
    # a day (the Phase 3 timer runs at 00/6:00) x var.etcd_snapshot_retention_days
    # objects, each a few MB compressed for a cluster this size. At 30 days that
    # is ~120 objects and stays inside the S3 5 GiB free tier with room for the
    # versioned copies below.
    expiration {
      days = var.etcd_snapshot_retention_days
    }

  }

  # A separate bucket-wide rule, because the abort policy is about the bucket and
  # not about one prefix: an interrupted multipart upload on a burstable t3.small
  # can happen against any prefix, and it is charged as stored storage until it
  # expires. Keeping it out of the snapshot rule also makes the two rules
  # independent -- changing the retention cannot silently change the abort policy.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "expire-etcd-snapshot-noncurrent-versions"
    status = "Enabled"

    filter {
      prefix = "${local.etcd_snapshot_folder}/"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.etcd_snapshot_retention_days
    }
  }
}
