variable "bootstrap_state_bucket" {
  type        = string
  description = "State bucket created by bootstrap/ (its state_bucket_name output). Named `boutique-platform-tfstate-<account>-us-east-1`; kept a variable because it is account-scoped and must never be written into a tracked file."
  nullable    = false

  validation {
    condition     = can(regex("^boutique-platform-tfstate-[a-z0-9-]+-us-east-1$", var.bootstrap_state_bucket))
    error_message = "Must be the bootstrap stack's state_bucket_name output, in the form boutique-platform-tfstate-<account>-us-east-1."
  }
}

variable "admin_cidr" {
  type        = string
  description = "The operator's egress IP as a /32 (or the smallest prefix that covers it). The only source allowed to reach the kube-apiserver on 6443/tcp. Get it with `curl -s https://checkip.amazonaws.com` and write `ADDRESS/32`."
  nullable    = false

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$", var.admin_cidr))
    error_message = "admin_cidr must be an IPv4 CIDR in the form <ip>/<prefix>, e.g. 203.0.113.10/32."
  }

  validation {
    condition     = !contains(["0.0.0.0/0", "::/0"], var.admin_cidr)
    error_message = "admin_cidr must not be the whole internet. The SPEC's trust boundary 3 puts the apiserver behind the operator's address only."
  }
}

variable "alert_email" {
  type        = string
  description = "Address the Budget alerts and the Phase 9 cluster alarms go to. The SNS topic and its subscription already exist in bootstrap/; this stack re-states the value so one tfvars file drives both stacks."
  nullable    = false

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a single email address."
  }
}

variable "azs" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
  description = "The three availability zones, one subnet each. SPEC pins one node per AZ for the etcd quorum, so changing this list changes the cluster's fault tolerance, not just its layout."

  validation {
    condition     = length(var.azs) == 3
    error_message = "Exactly three AZs: the SPEC's three-node k3s cluster needs one per AZ for a quorum that survives one loss."
  }
}

variable "vpc_cidr" {
  type        = string
  default     = "10.90.0.0/16"
  description = "VPC CIDR. 10.90.0.0/16 does not overlap the account's default VPC (172.31.0.0/16), which is what makes the two routable side by side if anything ever needs to talk between them."

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && !contains(["0.0.0.0/0", "::/0"], var.vpc_cidr)
    error_message = "vpc_cidr must be a real IPv4 network, not the internet."
  }
}

variable "traefik_nodeport_http" {
  type        = number
  default     = 32080
  description = "NodePort the in-cluster Traefik listens on for plaintext, before the ALB's HTTP to HTTPS redirect is applied. SPEC's two-layer edge puts the ALB in front of this port."

  validation {
    condition     = var.traefik_nodeport_http >= 30000 && var.traefik_nodeport_http <= 32767
    error_message = "NodePorts live in 30000-32767 (the Kubernetes NodePort range); 10255 and 10250 are deliberately outside any rule in this stack."
  }
}

variable "traefik_nodeport_https" {
  type        = number
  default     = 32443
  description = "NodePort the in-cluster Traefik listens on for TLS-terminated traffic from the ALB."
}

variable "traefik_nodeport_ping" {
  type        = number
  default     = 32081
  description = "NodePort of Traefik's own `traefik` entrypoint, which is where --ping answers. The ALB target groups health-check /ping here. Measured 2026-10-14: probing traefik_nodeport_http instead can never return 200, because that is the `web` entrypoint and it answers every request with the entrypoint's 301 to https."

  validation {
    condition     = var.traefik_nodeport_ping >= 30000 && var.traefik_nodeport_ping <= 32767
    error_message = "NodePorts live in 30000-32767 (the Kubernetes NodePort range)."
  }
}

variable "instance_type_servers" {
  type        = string
  default     = "t3.small"
  description = "Instance shape of the three k3s server nodes (Phase 3). Read here, at plan time, so the shape is validated against the account's vCPU quota before anything is launched."
}

variable "instance_type_worker" {
  type        = string
  default     = "t3.small"
  description = "Instance shape of the one workload node (Phase 3). t3.medium is deliberately NOT the default: this account rejects RunInstances for any instance type whose FreeTierEligible flag is false, with InvalidParameterCombination 'The specified instance type is not eligible for Free Tier'. Verified 2026-10-14 in us-east-1: t3.small, t4g.small and c7i-flex.large are eligible; t3.medium and t2.* are not. Four equal t3.small nodes also model cheaper ($82.56/mo vs $97.74/mo)."
}

variable "k3s_channel_parameter_name" {
  type        = string
  default     = "/boutique-platform/k3s/channel"
  description = "SSM parameter holding the k3s release channel. The node role can read exactly this one parameter, and Phase 3's cloud-init reads it instead of hardcoding a version."
}

variable "node_role_name" {
  type        = string
  default     = "boutique-platform-node"
  description = "Name of the instance role and instance profile. Also the ARN the bootstrap apply role is allowed to pass to EC2."
}

# ---------------------------------------------------------------------------
# Phase 3: the cluster.
# ---------------------------------------------------------------------------

variable "k3s_token" {
  type      = string
  sensitive = true
  ephemeral = true
  nullable  = false

  description = <<-EOT
    The k3s join token. EPHEMERAL and WRITE-ONLY: Terraform passes it to
    aws_ssm_parameter.k3s_token as a write-only attribute and then discards it, so
    it appears in neither the plan nor the state nor any plan file.

    Because an ephemeral variable cannot have a default, EVERY Terraform command
    needs one:

        TF_VAR_k3s_token="$(openssl rand -hex 32)" terraform plan
        TF_VAR_k3s_token="..."                       terraform apply

    Generate one with `openssl rand -hex 32`. Rotation is either
    `terraform apply -var k3s_token=<new> -var k3s_token_version=2` or the
    documented aws ssm put-parameter command in platform/README.md.

    Never write this into a tracked file. *.tfvars is gitignored, so a local
    terraform.tfvars is acceptable for a workstation, but it is plaintext on disk.
  EOT

  validation {
    condition     = length(var.k3s_token) >= 32
    error_message = "k3s_token must be at least 32 characters: `openssl rand -hex 32` produces 64."
  }
}

variable "k3s_token_version" {
  type        = number
  default     = 1
  description = "The write-only attribute's version. Bump it together with a new k3s_token to make the provider re-issue the SSM parameter; without a bump, a changed token is silently ignored."

  validation {
    condition     = var.k3s_token_version >= 1 && floor(var.k3s_token_version) == var.k3s_token_version
    error_message = "k3s_token_version must be a positive integer, 1 or greater."
  }
}

variable "node_volume_size_gb" {
  type        = number
  default     = 16
  description = "Size of each node's encrypted gp3 root volume. 4 x 16 GiB = 64 GiB, of which 30 GiB is the free tier, which is what scripts/cost-estimate.sh assumes."

  validation {
    condition     = var.node_volume_size_gb >= 8 && var.node_volume_size_gb <= 512
    error_message = "node_volume_size_gb must be between 8 and 512. The SPEC's cost model assumes 16 GiB x 4 nodes."
  }
}

variable "api_ready_wait_seconds" {
  type        = number
  default     = 300
  description = "How long a node's cloud-init waits for the kube-apiserver to report healthy before giving up. Strict on the designated leader (the apply fails) and advisory on the other nodes (the systemd unit keeps retrying)."

  validation {
    condition     = var.api_ready_wait_seconds >= 60
    error_message = "api_ready_wait_seconds must allow at least 60s: k3s takes about that long to write its first serving certificate."
  }
}

variable "ssm_parameter_wait_seconds" {
  type        = number
  default     = 600
  description = "How long a node's cloud-init polls SSM for the join token and the leader address. Long on purpose: on a cold cluster the leader is still installing k3s when the followers boot."
}

variable "etcd_snapshot_retention_days" {
  type        = number
  default     = 30
  description = "How long an etcd snapshot stays in S3 before the lifecycle rule expires it. The Phase 3 timer writes 4 a day, so 30 days is about 120 recovery points and stays inside the S3 5 GiB free tier."

  validation {
    condition     = var.etcd_snapshot_retention_days >= 1 && var.etcd_snapshot_retention_days <= 365
    error_message = "etcd_snapshot_retention_days must be between 1 and 365. The SPEC's window is 43 days."
  }
}

# ---------------------------------------------------------------------------
# Phase 5 — the edge
# ---------------------------------------------------------------------------

variable "ssl_policy" {
  type    = string
  default = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"

  description = "The ALB TLS policy. Verified present against `aws elbv2 describe-ssl-policies` on 2026-10-08. This one requires TLS 1.2 or higher, prefers TLS 1.3, and enables post-quantum key exchange where the client supports it. The `-FIPS-` variants are not used: they are for accounts that must attest to FIPS, and the TLS negotiation is slightly restrictive on old clients."

  validation {
    condition     = startswith(var.ssl_policy, "ELBSecurityPolicy-TLS13-1-2")
    error_message = "ssl_policy must be a TLS 1.2+ minimum ELBSecurityPolicy. Anything else leaves a TLS 1.0 or 1.1 path open, and SPEC.md requires TLS 1.2+."
  }
}

# There is no Route 53 zone and no ACM certificate in the account, so the two
# cert paths are a self-signed import (the default) and cert-manager HTTP-01
# against a wildcard-DNS hostname. Neither is a production cert; SPEC.md
# non-goal 7 records that.
variable "cert_mode" {
  type    = string
  default = "self-signed"

  description = "`self-signed` imports a cert generated by scripts/tls/generate-selfsigned.sh and terminates TLS at the ALB. `http01` creates no ACM cert and terminates TLS at Traefik with a cert-manager-issued public cert."

  validation {
    condition     = contains(["self-signed", "http01"], var.cert_mode)
    error_message = "cert_mode must be 'self-signed' or 'http01'."
  }
}

variable "acm_certificate_arn" {
  type        = string
  default     = ""
  sensitive   = true
  description = "An existing ACM certificate ARN to import instead of one created here. Prefer this in a real account: a cert generated by scripts/tls/generate-selfsigned.sh is a development path. Empty means this stack creates and imports the self-signed cert."

  validation {
    condition     = var.acm_certificate_arn == "" || startswith(var.acm_certificate_arn, "arn:")
    error_message = "acm_certificate_arn must be empty or a valid ARN."
  }
}

# The three ACM values are sensitive: they are a private key and a certificate
# body. They arrive from the operator at apply time (TF_VAR_ or a gitignored
# tfvars file) and are never generated by Terraform, so the key never enters the
# state file.
variable "acm_private_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "The PEM private key for the imported certificate, from scripts/tls/generate-selfsigned.sh. Never generated by Terraform: a key in state is a key in the S3 state file."
}

variable "acm_certificate_body" {
  type        = string
  default     = ""
  sensitive   = true
  description = "The PEM certificate body for acm_private_key, from scripts/tls/generate-selfsigned.sh."
}

variable "acm_certificate_chain" {
  type        = string
  default     = ""
  sensitive   = true
  description = "The PEM intermediate chain. Empty for a self-signed cert; required if a real CA issued the leaf."
}

# The Web ACL is a COUNT-by-default control. Switching to BLOCK before the
# CloudWatch WAF log has been reviewed against real traffic will take the site
# down on the first false positive, because the common rule set matches plenty
# of legitimate Boutique requests (a product search with an apostrophe is SQLi
# to it).
variable "waf_action" {
  type    = string
  default = "count"

  description = "`count` runs every AWS managed rule group and the rate limit in count-only mode, so the log is the test suite. `block` enforces them. Flip to block only after docs/runbooks/edge.md's review step has been completed against real traffic."

  validation {
    condition     = contains(["count", "block"], var.waf_action)
    error_message = "waf_action must be 'count' or 'block'."
  }
}

variable "waf_rate_limit" {
  type    = number
  default = 2000

  description = "Requests per 5-minute window per source IP before the rate rule acts. 2000 in 5 minutes is roughly 6.8 requests/second sustained, which is well above a single browser but low enough to blunt a brute-force or a runaway script."

  validation {
    condition     = var.waf_rate_limit >= 100 && var.waf_rate_limit <= 100000000
    error_message = "waf_rate_limit must be between 100 and 100000000. Below 100 blocks a page load, which is many requests."
  }
}

variable "log_retention_days" {
  type    = number
  default = 14

  description = "CloudWatch retention for the WAF log group. The S3 access-log bucket uses its own 30-day lifecycle. 14 days is the SPEC's default for platform logs."

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts."
  }
}

# Default false for the reason in edge.tf's comment: Phase 14 tears this down
# from a budget alarm, and a protected ALB makes destroy a manual two-step at the
# worst possible moment. Not a hardening step, a cost decision.
variable "alb_deletion_protection" {
  type        = bool
  default     = false
  description = "Enable ALB deletion protection. False by default so Phase 14's budget-driven teardown can complete; set true on a long-lived deployment."
}
