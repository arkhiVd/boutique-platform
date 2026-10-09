# platform — network and node identity

The Phase 2 stack: one VPC, three public subnets (one per AZ), an IGW, DHCP
options, four security groups that narrow a public-subnet cluster, and the
instance profile the k3s nodes will wear.

**Nothing here bills.** A VPC, an internet gateway, subnet, route table, DHCP
options, security group, IAM role, instance profile and inline policy are all
free. No instances, volumes, load balancers, NAT gateways, or endpoints are
created — that is Phase 3, and it is the first cost-bearing apply.

| Created | Count | Why it looks like this |
|---|---|---|
| VPC `10.90.0.0/16` | 1 | does not overlap the default VPC's `172.31.0.0/16` |
| Public subnets | 3 | one per AZ, `us-east-1a/b/c`, for the one-node-per-AZ etcd quorum |
| Internet gateway + route | 1 | no NAT gateway: that is a $32/month line, so nodes are public and narrow |
| DHCP options | 1 | `AmazonProvidedDNS`, resolver at the base of the VPC CIDR |
| Security groups | 4 | `boutique-node-admin`, `boutique-node-api`, `boutique-node-internal`, `boutique-edge` |
| Security group rules | 21 | every one an `aws_security_group_rule`, so the policy reads as a list |
| Node role + profile + inline policy | 4 | SSM, ECR pull, metrics/logs, one S3 prefix, one SSM parameter |
| SSM parameter | 1 | the k3s channel, Standard tier |
| VPC default group | 1 | emptied: an open group nobody owns is how accidents happen |

## Prerequisites

`bootstrap/` must have been applied first. It creates the state bucket this
stack stores state in, the OIDC provider and the two GitHub Actions roles.

## Commands

```bash
cd platform

# 1. inputs
cp terraform.tfvars.example terraform.tfvars        # gitignored
$EDITOR terraform.tfvars
#   admin_cidr            your egress IP as /32 — required, no default
#   alert_email           same address as the bootstrap tfvars
#   bootstrap_state_bucket
#     terraform -chdir=bootstrap output -raw state_bucket_name

# 2. init against local state, the first time only. `terraform init` with the S3
#    backend needs the bucket to exist and, before bootstrap is applied, it does
#    not.
terraform init -backend=false
terraform fmt -check -recursive && terraform validate

# 3. wire the remote state (the bucket must already exist from bootstrap)
terraform init -reconfigure -backend-config="bucket=$(terraform -chdir=bootstrap output -raw state_bucket_name)"

# 4. read the plan before anything is created
terraform plan -no-color

# 5. apply
terraform apply -no-color

# 6. destroy — safe here, it removes only free resources
terraform destroy -no-color
```

### Why the first plan needs the backend declaration set aside

`terraform init -backend=false` followed by `terraform plan` stops with
`Backend initialization required`, because a backend block is present and the
bucket it names does not exist yet — the bucket is created by `bootstrap/`, and
this stack cannot be bootstrapped by the bucket it is supposed to live in. So
the first plan (the one to read before the bootstrap apply, which is the
ordering the ROADMAP asks for) is taken like this:

```bash
mv backend.tf /tmp && terraform init -backend=false && terraform plan -no-color
mv /tmp/backend.tf .
```

After `bootstrap/` is applied, `terraform init -reconfigure -backend-config=...`
works and the plan is the ordinary one. The reason the bucket name is not simply
written in `backend.tf` is that backend blocks accept constant strings only, and
an account-scoped bucket name does not belong in a tracked file.

## The security-group contract

| Group | Ingress | Egress |
|---|---|---|
| `boutique-node-admin` | **nothing at all** | 443/tcp anywhere, 53 udp+tcp to `10.90.0.2/32` |
| `boutique-node-api` | 6443/tcp from `var.admin_cidr` | same |
| `boutique-node-internal` | 8472/udp, 10250/tcp, 2379-2380/tcp, 6443/tcp from itself | same |
| `boutique-edge` | 80/tcp + 443/tcp from the internet, Traefik NodePorts from `boutique-node-internal` | same |

- **No 22/tcp anywhere, and no key pair.** `aws ec2 describe-security-groups`
  on `boutique-node-admin` shows an empty `IpPermissions`. SSM Session Manager is
  the access path, and `scripts/security-audit.sh` checks it in Phase 3.
- **No 10255/tcp.** kubelet's read-only port is disabled in k3s, so there is
  nothing to open and nothing to accidentally re-open.
- **The egress policy is not `0.0.0.0/0` blind.** `aws_security_group` revokes
  the default allow-all egress when it creates a group, so these three rules per
  group are the complete policy: TLS out, DNS to one address, nothing else.

## What the plan looks like

```
Plan: 42 to add, 0 to change, 0 to destroy.
```

A `check` block named `node_shape_within_vcpu_quota` warns when the
`instance_type_*` values in tfvars would put Phase 3's shape over the account's
8 vCPU running-on-demand quota. It warns rather than fails — that is what a
Terraform check block does, by design; the hard gate for the same condition is
`scripts/cost-estimate.sh`, which exits 8.

## Known gaps, stated rather than hidden

- **VPC flow logs are off.** Costed, deferred, and recorded in `.checkov.yaml`.
- **The ALB to NodePort path is one rule short.** `boutique-edge` allows the
  node group onto Traefik's NodePorts; the reverse direction, nodes accepting
  traffic from the edge group, arrives with the ALB in Phase 5 — until then the
  edge group is attached to nothing.
- **The etcd snapshot bucket does not exist yet.** The node policy grants
  `s3:PutObject` on
  `arn:aws:s3:::boutique-platform-etcd-snapshots-<account>/etcd-snapshots/*`;
  Phase 4 creates the bucket with the snapshot schedule.
- **No IPv6 anywhere.** The VPC is IPv4-only.
