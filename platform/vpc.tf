# A VPC for a cluster that has to be public by construction.
#
# The account has no NAT budget (SPEC: "no NAT gateways, nodes run in public
# subnets and must be hardened accordingly"), so every node gets a public IP and
# the ingress surface is narrowed with security groups instead of with a NAT
# hop. That is the cost decision; the SGs in security-groups.tf are what makes
# it survivable.

resource "aws_vpc" "boutique" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "boutique-platform"
  }
}

# The route out for every node: out through the IGW. There is no private subnet
# and no NAT gateway to pay for.
resource "aws_internet_gateway" "boutique" {
  vpc_id = aws_vpc.boutique.id

  tags = {
    Name = "boutique-platform-igw"
  }
}

resource "aws_route_table" "boutique" {
  vpc_id = aws_vpc.boutique.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.boutique.id
  }

  tags = {
    Name = "boutique-platform-public"
  }
}

resource "aws_route_table_association" "boutique" {
  for_each = aws_subnet.boutique

  subnet_id      = each.value.id
  route_table_id = aws_route_table.boutique.id
}

resource "aws_subnet" "boutique" {
  for_each = toset(local.azs)

  vpc_id            = aws_vpc.boutique.id
  availability_zone = each.value
  # /20 per AZ: 4091 addresses, which is far more than three nodes with
  # Kubernetes' per-node IP requirement (250 addresses) and leaves the /16
  # mostly unused rather than pre-carved.
  cidr_block = cidrsubnet(aws_vpc.boutique.cidr_block, 4, index(local.azs, each.value))

  # Deliberate. No NAT gateway means the nodes have no other path to the
  # internet than a public address; the SGs, not the address, are the control.
  map_public_ip_on_launch = true

  tags = {
    Name = "boutique-platform-${each.value}"

    # The AWS Cloud Controller Manager's "shared" tag: this cluster's subnets
    # may be used by a load balancer for this cluster and any other that tags
    # them shared too. Without it the in-tree cloud provider refuses to place
    # an ALB here at all.
    "kubernetes.io/cluster/boutique-platform" = "shared"

    # Public subnets: the AWS Load Balancer Controller's in-tree predecessor
    # uses this to decide where an internet-facing ELB goes. Needed by the
    # Phase 5 edge.
    "kubernetes.io/role/elb" = "1"
  }
}

# The VPC resolver at the base of the primary CIDR, which is where Route 53
# Resolver always sits. AmazonProvidedDNS means "whatever Amazon hands out for
# this VPC" rather than a pinned IP, so subnets in other AZs and future
# secondary CIDRs keep working.
resource "aws_vpc_dhcp_options" "boutique" {
  domain_name_servers = ["AmazonProvidedDNS"]

  tags = {
    Name = "boutique-platform-dhcp"
  }
}

resource "aws_vpc_dhcp_options_association" "boutique" {
  vpc_id          = aws_vpc.boutique.id
  dhcp_options_id = aws_vpc_dhcp_options.boutique.id
}

# AWS creates a default security group in every VPC that allows all ingress
# from itself and all egress. Nothing in this stack uses it, and an open group
# nobody owns is how "someone attached the default SG" accidents happen. No
# ingress and no egress blocks means Terraform removes both rules as soon as it
# takes the group over.
resource "aws_default_security_group" "boutique" {
  vpc_id = aws_vpc.boutique.id

  tags = {
    Name = "boutique-platform-default"
  }
}
