# Four security groups, one per trust boundary in the SPEC. Every rule is a
# standalone `aws_security_group_rule` so the whole policy is readable as a list
# instead of being buried in four blocks.
#
# Source, because this file's correctness depends on it: hashicorp/terraform-provider-aws
# v6.68.0, internal/service/ec2/vpc_security_group.go, resourceSecurityGroupCreate:
#   "AWS defaults all Security Groups to have an ALLOW ALL egress rule.
#    Here we revoke that rule, so users don't unknowingly have/use it."
# So a security group created by this stack starts with NO egress rule, and the
# three egress rules declared below per group are the complete egress policy.
# Nothing needs a revoke pass to make that true.

# ---------------------------------------------------------------------------
# Shared egress policy
#
# Every node group gets exactly these three egress rules. They are written out
# per group rather than looped, because each one is a line a reader has to agree
# with: there is no "allow all egress", and there is no rule that would let a
# node reach another VPC, a peered network, or the instance metadata service.
#
#   443/tcp    -> 0.0.0.0/0   dnf/yum mirrors, ECR, S3, STS
#   53/udp,53/tcp -> 10.90.0.2  the VPC resolver only (see vpc.tf / dhcp options)
# ---------------------------------------------------------------------------

resource "aws_security_group" "boutique_node_admin" {
  name        = "boutique-node-admin"
  description = "k3s control-plane group. Ingress is deliberately empty: access is SSM Session Manager, not SSH."
  vpc_id      = aws_vpc.boutique.id

  tags = {
    Name = "boutique-node-admin"
  }
}

# Ingress: none. Not "22 restricted to the operator" — no 22 rule exists at all.
# The SPEC's trust boundary 3 says nodes are reachable only through SSM Session
# Manager: no key pair, no port 22, no bastion. `aws ec2 describe-security-groups`
# on this group must show an empty IpPermissions list, which is what
# scripts/security-audit.sh checks in Phase 3.
resource "aws_security_group_rule" "node_admin_egress_https" {
  type              = "egress"
  description       = "outbound TLS to package mirrors, ECR and S3"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.boutique_node_admin.id
}

resource "aws_security_group_rule" "node_admin_egress_dns_udp" {
  type              = "egress"
  description       = "DNS to the VPC resolver only"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [local.vpc_dns_cidr]
  security_group_id = aws_security_group.boutique_node_admin.id
}

resource "aws_security_group_rule" "node_admin_egress_dns_tcp" {
  type              = "egress"
  description       = "DNS over TCP to the VPC resolver only"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_dns_cidr]
  security_group_id = aws_security_group.boutique_node_admin.id
}

resource "aws_security_group" "boutique_node_api" {
  name = "boutique-node-api"
  # No apostrophe here, and that is not a style choice. AWS rejects a security
  # group description containing any character outside
  # `a-zA-Z0-9 ._-:/()#,@[]+=&;{}!$*`, and an apostrophe is not in that set:
  # CreateSecurityGroup came back with `Invalid security group description` on
  # the first real apply of this stack (2026-10-14). Terraform's own variable
  # and output descriptions are free text and were never affected, so nothing
  # local ever caught it.
  description = "The kube-apiserver front door: 6443/tcp from the operator CIDR only."
  vpc_id      = aws_vpc.boutique.id

  tags = {
    Name = "boutique-node-api"
  }
}

resource "aws_security_group_rule" "node_api_ingress_kube_api" {
  type              = "ingress"
  description       = "kubectl and the AWS cloud controller manager, from the operator address only"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  cidr_blocks       = [var.admin_cidr]
  security_group_id = aws_security_group.boutique_node_api.id
}

resource "aws_security_group_rule" "node_api_egress_https" {
  type              = "egress"
  description       = "outbound TLS to package mirrors, ECR and S3"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.boutique_node_api.id
}

resource "aws_security_group_rule" "node_api_egress_dns_udp" {
  type              = "egress"
  description       = "DNS to the VPC resolver only"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [local.vpc_dns_cidr]
  security_group_id = aws_security_group.boutique_node_api.id
}

resource "aws_security_group_rule" "node_api_egress_dns_tcp" {
  type              = "egress"
  description       = "DNS over TCP to the VPC resolver only"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_dns_cidr]
  security_group_id = aws_security_group.boutique_node_api.id
}

resource "aws_security_group" "boutique_node_internal" {
  name        = "boutique-node-internal"
  description = "Node-to-node traffic only: Flannel VXLAN, kubelet, etcd, the apiserver."
  vpc_id      = aws_vpc.boutique.id

  tags = {
    Name = "boutique-node-internal"
  }
}

# Self-referencing, so only the nodes in this group. No other group, no other
# CIDR, can open any of these ports.
resource "aws_security_group_rule" "node_internal_ingress_flannel" {
  type                     = "ingress"
  description              = "Flannel VXLAN, the overlay that carries pod-to-pod traffic"
  from_port                = 8472
  to_port                  = 8472
  protocol                 = "udp"
  source_security_group_id = aws_security_group.boutique_node_internal.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "node_internal_ingress_kubelet" {
  type                     = "ingress"
  description              = "kubelet API: metrics, logs, exec used by the control plane and by Prometheus"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.boutique_node_internal.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

# node-exporter runs on the host network (it reads the host's /proc and /sys),
# so Prometheus -- a pod on one node -- scrapes it at <node-ip>:9100 and this SG
# decides. Without the rule only the node Prometheus happened to run on was
# reachable: 3 of 4 node-exporter targets timed out (found 2026-10-18 when the
# node-exporter ServiceMonitor was first enabled).
resource "aws_security_group_rule" "node_internal_ingress_node_exporter" {
  type                     = "ingress"
  description              = "node-exporter metrics on the host network, scraped by Prometheus"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.boutique_node_internal.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "node_internal_ingress_etcd" {
  type                     = "ingress"
  description              = "etcd client and peer ports, for the HA quorum across three AZs"
  from_port                = 2379
  to_port                  = 2380
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.boutique_node_internal.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "node_internal_ingress_kube_api" {
  type                     = "ingress"
  description              = "apiserver, server to server, so a lost operator route does not stop the cluster"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.boutique_node_internal.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

# 10255/tcp is the kubelet read-only port and it is NOT open here, on purpose.
# Upstream Kubernetes removed it in 1.24 --read-only-port semantics, and k3s
# runs with it off (the read-only port is disabled, kubelet only listens on
# 10250), so there is no rule to write and no port to accidentally re-open.
# Phase 3's k3s install keeps it that way; nothing in this repo enables it.

# Everything to the peers, and nothing else outside the allow-list below.
#
# The ingress rules above are enumerated on purpose; egress to the peers is not,
# because enumerating it is what stopped the cluster from forming at all. The
# three node security groups ship egress of DNS (53) and HTTPS (443) only, so
# the follower could reach SSM and GitHub but not the leader's apiserver: k3s
# failed with `Get "https://10.90.12.149:6443/cacerts": context deadline
# exceeded`, 483 restarts deep, while the matching INGRESS rule for 6443 was
# present and correct. A handshake needs both halves. Measured 2026-10-14.
#
# Scoped to this group rather than 10.90.0.0/16 so "node to node" stays exactly
# what the group's name says: the ALB, the subnets and any other instance are
# unaffected, and the external egress allow-list below still governs everything
# leaving the nodes.
resource "aws_security_group_rule" "node_internal_egress_self" {
  type                     = "egress"
  description              = "node to node without a port allow-list: apiserver, etcd peer, flannel VXLAN, kubelet, and whatever the next phase adds"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.boutique_node_internal.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "node_internal_egress_https" {
  type              = "egress"
  description       = "outbound TLS to package mirrors, ECR and S3"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "node_internal_egress_dns_udp" {
  type              = "egress"
  description       = "DNS to the VPC resolver only"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [local.vpc_dns_cidr]
  security_group_id = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "node_internal_egress_dns_tcp" {
  type              = "egress"
  description       = "DNS over TCP to the VPC resolver only"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_dns_cidr]
  security_group_id = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group" "boutique_edge" {
  name        = "boutique-edge"
  description = "Public edge, in front of the ALB. 80/443 from the internet; NodePorts from the nodes only."
  vpc_id      = aws_vpc.boutique.id

  tags = {
    Name = "boutique-edge"
  }
}

# Correct to be world-open: this is the one group the SPEC's trust boundary 1
# makes the internet's entry point. It sits in front of the ALB, which
# terminates TLS and carries the Web ACL; nothing answers on 80/443 without
# going through it.
resource "aws_security_group_rule" "edge_ingress_http" {
  type              = "ingress"
  description       = "plaintext, only ever to be redirected to https"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.boutique_edge.id
}

resource "aws_security_group_rule" "edge_ingress_https" {
  type              = "ingress"
  description       = "the public edge"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.boutique_edge.id
}

# The in-cluster path: the nodes reach the edge group on Traefik's NodePorts,
# named by the source of the traffic. The ALB wears this same group in Phase 5,
# so its target group's traffic is allowed by the node identity rather than by
# a CIDR that has to be maintained by hand.
# ALB to node, written on the RECEIVING side.
#
# These two rules were the other way around on 2026-10-14: they sat on
# boutique_edge sourced from boutique_node_internal, which permits the nodes to
# reach the ALB on the NodePort -- a path nothing uses -- while the ALB's own
# health checks and forwards, which originate from the edge group, were denied.
# Every target reported `Target.Timeout` for exactly that reason. An ingress
# rule belongs to the group that receives the packet.
resource "aws_security_group_rule" "edge_ingress_traefik_http" {
  type                     = "ingress"
  description              = "ALB to Traefik NodePort, plaintext"
  from_port                = var.traefik_nodeport_http
  to_port                  = var.traefik_nodeport_http
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.boutique_edge.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "edge_ingress_traefik_https" {
  type                     = "ingress"
  description              = "ALB to Traefik NodePort, TLS"
  from_port                = var.traefik_nodeport_https
  to_port                  = var.traefik_nodeport_https
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.boutique_edge.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

# The health-check port, same direction as the two above. Without it the ALB
# cannot even reach the endpoint its own health check names, which is the
# difference between `Target.Timeout` and a real answer.
resource "aws_security_group_rule" "edge_ingress_traefik_ping" {
  type                     = "ingress"
  description              = "ALB health checks to the Traefik ping entrypoint"
  from_port                = var.traefik_nodeport_ping
  to_port                  = var.traefik_nodeport_ping
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.boutique_edge.id
  security_group_id        = aws_security_group.boutique_node_internal.id
}

# ALB to the Traefik NodePorts, egress side.
#
# An SG filter has to pass on BOTH ends: the node accepts the packet (the
# three ingress rules below) and the ALB must be allowed to send it. This
# group carried only 443 and DNS on 2026-10-14, so the ALB's own health
# checks were dropped at the source and every target read `Target.Timeout`
# no matter what the node answered locally. One rule per port, rather than a
# 32080-32443 range, so this never becomes implicit permission for unrelated
# NodePorts.
resource "aws_security_group_rule" "edge_egress_traefik_http" {
  type                     = "egress"
  description              = "ALB to the Traefik plaintext NodePort"
  from_port                = var.traefik_nodeport_http
  to_port                  = var.traefik_nodeport_http
  protocol                 = "tcp"
  security_group_id        = aws_security_group.boutique_edge.id
  source_security_group_id = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "edge_egress_traefik_ping" {
  type                     = "egress"
  description              = "ALB health checks to the Traefik ping entrypoint"
  from_port                = var.traefik_nodeport_ping
  to_port                  = var.traefik_nodeport_ping
  protocol                 = "tcp"
  security_group_id        = aws_security_group.boutique_edge.id
  source_security_group_id = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "edge_egress_traefik_https" {
  type                     = "egress"
  description              = "ALB to the Traefik TLS NodePort"
  from_port                = var.traefik_nodeport_https
  to_port                  = var.traefik_nodeport_https
  protocol                 = "tcp"
  security_group_id        = aws_security_group.boutique_edge.id
  source_security_group_id = aws_security_group.boutique_node_internal.id
}

resource "aws_security_group_rule" "edge_egress_https" {
  type              = "egress"
  description       = "outbound TLS to package mirrors, ECR and S3"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.boutique_edge.id
}

resource "aws_security_group_rule" "edge_egress_dns_udp" {
  type              = "egress"
  description       = "DNS to the VPC resolver only"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [local.vpc_dns_cidr]
  security_group_id = aws_security_group.boutique_edge.id
}

resource "aws_security_group_rule" "edge_egress_dns_tcp" {
  type              = "egress"
  description       = "DNS over TCP to the VPC resolver only"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_dns_cidr]
  security_group_id = aws_security_group.boutique_edge.id
}
