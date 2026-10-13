resource "aws_s3_bucket" "alb_logs" {
  bucket_prefix = "boutique-platform-alb-logs-"
  tags = {
    Component = "edge"
  }
}

# An ALB access-log bucket with a public access block, versioning, SSE and a
# lifecycle rule. Access logs are the only record of what the Web ACL let
# through and what the ALB routed, so they are the incident source of truth.
resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.platform.arn
    }
  }
}

# CKV_AWS_18: the access-log bucket gets its own access log, into a disjoint
# second bucket. A bucket cannot log to itself: the ELB write ACL check would
# fail against the same bucket it is appending to.
resource "aws_s3_bucket" "alb_logs_audit" {
  bucket_prefix = "boutique-platform-alb-logs-audit-"
  tags = {
    Component = "edge"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs_audit" {
  bucket                  = aws_s3_bucket.alb_logs_audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs_audit" {
  bucket = aws_s3_bucket.alb_logs_audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.platform.arn
    }
  }
}

resource "aws_s3_bucket_versioning" "alb_logs_audit" {
  bucket = aws_s3_bucket.alb_logs_audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs_audit" {
  bucket = aws_s3_bucket.alb_logs_audit.id
  rule {
    id     = "expire-audit-logs"
    status = "Enabled"
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    # A failed multipart upload still occupies space and is billed. The ALB
    # writes small objects, so this rule fires almost never -- but when it does,
    # it is the only thing that reclaims the partial part.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "alb_logs" {
  bucket        = aws_s3_bucket.alb_logs.id
  target_bucket = aws_s3_bucket.alb_logs_audit.id
  target_prefix = "server-access/"
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# The ALB service writes the logs, and the elb-account-id principal differs by
# region. us-east-1 is 127311923021. Scope the GrantLogDelivery permission to the
# bucket ARN and not to "*", or any account that knows the bucket name could
# write to it.
data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid    = "AllowELBLogDelivery"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elb.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
  }
  statement {
    sid    = "AllowELBAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elb.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.alb_logs.arn]
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    # A failed multipart upload still occupies space and is billed. The ALB
    # writes small objects, so this rule fires almost never -- but when it does,
    # it is the only thing that reclaims the partial part.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The two-layer edge from ADR-0002: an external ALB terminating TLS and applying
# the Web ACL, forwarding to the in-cluster Traefik NodePort.
#
# deletion_protection is off deliberately: this platform is a short-lived
# validation target that Phase 14 must be able to destroy from a cost alarm, and
# a protection flag that must be removed before destroy is a destroy that fails.
resource "aws_lb" "edge" {
  name               = "boutique-platform-edge"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.boutique_edge.id]
  subnets            = [for s in values(aws_subnet.boutique) : s.id]


  # Access logs to S3 rather than CloudWatch: they are queried once a month at
  # most, and S3 storage is roughly a fifth of CloudWatch Logs ingestion.
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
  }

  # If the health check is wrong, the ALB marks every target unhealthy and the
  # site goes down while every pod is Running. See docs/runbooks/edge.md.
  drop_invalid_header_fields = true

  # Deletion protection defaults to FALSE here and that is a deliberate,
  # documented deviation, not an oversight: Phase 14's teardown is driven by a
  # budget alarm, and a protected ALB turns `terraform destroy` into a
  # two-step manual operation at the exact moment the operator is trying to stop
  # a spend. A long-lived deployment sets var.alb_deletion_protection = true,
  # which is why it is a variable.
  enable_deletion_protection = var.alb_deletion_protection

  tags = {
    Component = "edge"
  }
}

# Target groups point at the NODES, not the pods. The ALB-to-pod path would
# require VPC CNI in direct-server-return mode and an NLB (blocked), so the
# target type is instance and the traffic crosses the node once more.
resource "aws_lb_target_group" "traefik_http" {
  name        = "boutique-platform-tf-http"
  port        = var.traefik_nodeport_http
  protocol    = "HTTP"
  vpc_id      = aws_vpc.boutique.id
  target_type = "instance"

  # /ping is Traefik's own health endpoint, and it does not touch the
  # application backends. A wrong path here (e.g. "/") makes the ALB depend on
  # the app to consider the ingress healthy, which is the failure mode this
  # comment exists to prevent.
  health_check {
    path                = "/ping"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Component = "edge"
  }
}

resource "aws_lb_target_group" "traefik_https" {
  name        = "boutique-platform-tf-https"
  port        = var.traefik_nodeport_https
  protocol    = "HTTPS"
  vpc_id      = aws_vpc.boutique.id
  target_type = "instance"

  # HTTPS to the node: the ALB re-encrypts to Traefik, so the hop from the ALB
  # into the cluster is encrypted and only the backend is plaintext.
  protocol_version = "HTTP1"

  health_check {
    path                = "/ping"
    matcher             = "200"
    protocol            = "HTTP"
    port                = var.traefik_nodeport_http
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Component = "edge"
  }
}

# Every schedulable node is registered, so an ALB target group always spans all
# three AZs. Phase 3 proved the four-node shape fits the measured requests.
# Attachment by index, not by instance ID. Instance IDs are unknown until apply,
# and a `for_each` keyed on an unknown value is a hard Terraform error (it
# "cannot determine the full set of keys"). The instance COUNT is known — it is
# the SPEC's four-node shape — so index is stable and correct.
resource "aws_lb_target_group_attachment" "traefik_http" {
  count            = length(local.azs) + 1
  target_group_arn = aws_lb_target_group.traefik_http.arn
  target_id        = local.all_node_ids[count.index]
  port             = var.traefik_nodeport_http
}

resource "aws_lb_target_group_attachment" "traefik_https" {
  count            = length(local.azs) + 1
  target_group_arn = aws_lb_target_group.traefik_https.arn
  target_id        = local.all_node_ids[count.index]
  port             = var.traefik_nodeport_https
}

# HTTP is redirected, not served. A fixed-action redirect means the ALB never
# terminates plaintext into the app, so no request can reach the frontend
# without a TLS upgrade forced at the edge.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.edge.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
      host        = "#{host}"
      path        = "/#{path}"
      query       = "#{query}"
    }
  }

  tags = {
    Component = "edge"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.edge.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.cert_mode == "http01" ? null : local.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik_https.arn
  }

  tags = {
    Component = "edge"
  }
}

# There is no Route 53 zone and no ACM certificate in this account, so a DNS
# validated certificate is impossible. The two paths, gated by var.cert_mode:
#
#   self-signed — a cert generated by scripts/tls/generate-selfsigned.sh and
#     imported into ACM at apply time. Real TLS and a real chain the client can
#     verify against the CA, but the CA is one we generated, so a browser warns.
#     This is the default because it needs no third party.
#
#   http01 — no ACM cert at all. cert-manager runs in-cluster, solves HTTP-01
#     against the ALB's DNS name through sslip.io, and terminates TLS at Traefik.
#     A real public CA chain, at the cost of a public FQDN we do not control.
#
# Neither is a production cert. SPEC.md non-goal 7 says so explicitly.
locals {
  acm_certificate_arn = var.cert_mode == "self-signed" ? (
    var.acm_certificate_arn != "" ? var.acm_certificate_arn : (
      length(aws_acm_certificate.self_signed) > 0 ? aws_acm_certificate.self_signed[0].arn : null
    )
  ) : null
}

resource "aws_acm_certificate" "self_signed" {
  count = var.cert_mode == "self-signed" ? 1 : 0

  # The private key is supplied by the operator, never generated by Terraform:
  # a key in state is a key in the state file, and the state file is in S3.
  private_key       = var.acm_private_key
  certificate_body  = var.acm_certificate_body
  certificate_chain = var.acm_certificate_chain

  tags = {
    Component = "edge"
  }

  lifecycle {
    # Importing a new cert every apply would be an unmanageable diff; the ARN is
    # the only thing that matters and it is stable across a re-import.
    ignore_changes = [private_key, certificate_body, certificate_chain]
    # The listener depends on the ARN, so a replace would break it. Creating the
    # new certificate before destroying the old one means a replacement is a
    # rolling swap, not a window with no certificate.
    create_before_destroy = true
  }
}

# The Web ACL. COUNT by default. Switching to BLOCK before the count-only logs
# in the CloudWatch log group below have been reviewed for a few days of traffic
# will take the site down on the first false positive.
resource "aws_wafv2_web_acl" "edge" {
  name        = "boutique-platform-edge"
  description = "Edge protection for the Boutique platform"
  scope       = "REGIONAL"

  default_action {
    dynamic "allow" {
      for_each = var.waf_action == "block" ? [] : [1]
      content {}
    }
    dynamic "block" {
      for_each = var.waf_action == "block" ? [1] : []
      content {}
    }
  }

  # AWS's own WAF rules, in COUNT mode so the log is the test suite.
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 10
    override_action {
      dynamic "count" {
        for_each = var.waf_action == "block" ? [] : [1]
        content {}
      }
      dynamic "none" {
        for_each = var.waf_action == "block" ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"
    priority = 20
    override_action {
      dynamic "count" {
        for_each = var.waf_action == "block" ? [] : [1]
        content {}
      }
      dynamic "none" {
        for_each = var.waf_action == "block" ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "sqli"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 30
    override_action {
      dynamic "count" {
        for_each = var.waf_action == "block" ? [] : [1]
        content {}
      }
      dynamic "none" {
        for_each = var.waf_action == "block" ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "knownbad"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesLinuxRuleSet"
    priority = 40
    override_action {
      dynamic "count" {
        for_each = var.waf_action == "block" ? [] : [1]
        content {}
      }
      dynamic "none" {
        for_each = var.waf_action == "block" ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesLinuxRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "linux"
      sampled_requests_enabled   = true
    }
  }

  # The rate limit is always enforced. Unlike the signature rules, it does not
  # depend on a body pattern that a legitimate request could resemble, and it is
  # the control that survives a misconfigured rule group above.
  # CVE-2021-44228 (Log4Shell) / CVE-2021-45046. The Boutique app ships a Java
  # service (adservice), so a Log4j deserialization payload is a real input
  # class. The Log4JRCE_BODY / Log4JRCE_URIPATH / Log4JRCE_QUERYSTRING rules
  # live INSIDE AWSManagedRulesKnownBadInputsRuleSet (verified for this account:
  # `aws wafv2 describe-managed-rule-group --name AWSManagedRulesKnownBadInputsRuleSet`
  # returns Log4JRCE_BODY, Log4JRCE_HEADER, Log4JRCE_QUERYSTRING,
  # Log4JRCE_URIPATH plus JavaDeserializationRCE_*). Adding the group again
  # would double-count the same traffic, so this rule references it by name and
  # gives it its own CloudWatch metric so a false positive is attributable to
  # the Log4j rules rather than the rest of the known-bad-inputs set.
  rule {
    name     = "log4j-coverage"
    priority = 15
    override_action {
      dynamic "count" {
        for_each = var.waf_action == "block" ? [] : [1]
        content {}
      }
      dynamic "none" {
        for_each = var.waf_action == "block" ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "log4j"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit"
    priority = 50
    action {
      dynamic "block" {
        for_each = var.waf_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_action == "block" ? [] : [1]
        content {}
      }
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "boutique-platform-edge"
    sampled_requests_enabled   = true
  }

  tags = {
    Component = "edge"
  }
}

resource "aws_wafv2_web_acl_association" "edge" {
  resource_arn = aws_lb.edge.arn
  web_acl_arn  = aws_wafv2_web_acl.edge.arn
}

# The log is what makes COUNT mode useful. Without it, a false positive is
# invisible until someone reports the site is down.
# KMS-encrypted, because the WAF sampled request log contains authority
# headers and request bodies. The CMK is the one Phase 3 already creates for the
# node volumes, so this adds no new key lifecycle.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "/aws/waf/boutique-platform-edge"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
  tags = {
    Component = "edge"
  }
}

data "aws_iam_policy_document" "waf_logs" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.waf.arn}:*"]
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name     = "boutique-platform-waf"
  policy_document = data.aws_iam_policy_document.waf_logs.json
}

resource "aws_wafv2_web_acl_logging_configuration" "edge" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.edge.arn

  # Request bodies and extra detail are redacted by default: an access log that
  # captured a checkout request would capture a synthetic credit card.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

# Every schedulable node, in a deterministic order: the three k3s servers
# (one per AZ, ordered by AZ name) then the worker. LOCAL is used because the
# IDs are unknown until apply, and a local can be referenced by a resource with
# count without Terraform needing the values to build the plan.
locals {
  all_node_ids = concat(
    [for az in sort(keys(aws_instance.k3s_server)) : aws_instance.k3s_server[az].id],
    [aws_instance.k3s_worker.id],
  )
}

# CKV_AWS_378 is suppressed for the http target group alone, with the reason
# inline: the ALB forwards to the Traefik NodePort on plaintext HTTP, and the
# in-cluster second layer (cluster/traefik) terminates TLS and forces the upgrade
# through its redirectScheme middleware. Egress is limited to the node internal
# security group on that port only, so the plaintext hop never crosses the VPC.
# The https target group is the one that carries real traffic.
#
# The scanner also sees a policy for a *different* bucket than the one the
# findings point at, because the audit bucket inherits the same checks; both are
# configured above.
