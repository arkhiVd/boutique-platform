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

## What the plan looked like at Phase 2

```
Plan: 42 to add, 0 to change, 0 to destroy.
```

A `check` block named `node_shape_within_vcpu_quota` warns when the
`instance_type_*` values in tfvars would put Phase 3's shape over the account's
8 vCPU running-on-demand quota. It warns rather than fails — that is what a
Terraform check block does, by design; the hard gate for the same condition is
`scripts/cost-estimate.sh`, which exits 8.

## Phase 3 — the cluster

### What the plan looks like now

```
terraform -chdir=platform plan      Plan: 58 to add, 0 to change, 0 to destroy.
```

The 16 resources Phase 3 adds on top of Phase 2's 42:

| Resource | Count |
|---|---|
| `aws_kms_key` + `aws_kms_alias` | 2 |
| `aws_launch_template` (server, worker) | 2 |
| `aws_instance` (3 servers, 1 worker) | 4 |
| `aws_ssm_parameter` (join token, leader address) | 2 |
| `aws_s3_bucket` + policy/versioning/SSE/PAB/lifecycle (Phase 4) | 6 |

### The k3s join token — how it never reaches state or git

This is the part of the design with the sharpest edge, so it is spelled out in
full. The token is an **ephemeral variable** feeding a **write-only attribute**:

```hcl
variable "k3s_token" {
  ephemeral = true
  sensitive = true
}

resource "aws_ssm_parameter" "k3s_token" {
  type            = "SecureString"
  key_id          = aws_kms_key.platform.arn
  value_wo        = var.k3s_token
  value_wo_version = var.k3s_token_version
}
```

Two facts, both verified against the actual tooling rather than remembered:

1. **Terraform refuses to write an ephemeral value into a normal attribute.**
   Run directly, the error is *"Ephemeral values are not valid for `input`,
   because it is not a write-only attribute and must be persisted to state."* So
   the failure mode of getting this wrong is loud.
2. **The AWS provider's read path nulls the value when `value_wo` is in play.**
   `hashicorp/terraform-provider-aws@v6.68.0`, `internal/service/ssm/parameter.go`:
   `if hasWriteOnly { d.Set("value", nil) } else { d.Set("value", param.Value) }`.

Measured on a scratch configuration:

```
terraform plan -out=tfplan ; terraform show -json tfplan | grep -c <token>   -> 0
grep -c <token> tfplan                                                      -> 0
```

**The cost of that design, stated plainly:** an ephemeral variable cannot have a
default, so *every* Terraform command needs one:

```bash
export TF_VAR_k3s_token="$(openssl rand -hex 32)"
terraform plan
terraform apply
```

`openssl rand -hex 32` produces the value; keep it nowhere but the SSM parameter
once it has been applied. Rejected alternative, with the reason: `random_password`
plus `value` puts the token in the state file in cleartext, where anyone with
`s3:GetObject` on the state bucket plus `terraform show` has it.

**Rotation.** Two documented commands, both safe to run from a workstation:

```bash
# 1. rotate the parameter directly, with no Terraform involvement
aws ssm put-parameter --name /boutique-platform/k3s/token --type SecureString \
  --key-id "$(terraform -chdir=platform output -raw kms_key_arn)" \
  --value "$(openssl rand -hex 32)" --overwrite

# 2. or through Terraform, where the version integer is what forces the
#    provider to re-issue the parameter
terraform apply -var k3s_token="$(openssl rand -hex 32)" -var k3s_token_version=2
```

kubelet reads the token only at **node registration**, so a rotated token takes
effect on the next instance that (re)joins and the previous token stops working
for new nodes at that point. The nodes already in the cluster keep running.

### The shape

| Node | Type | AZ | Role |
|---|---|---|---|
| 3 × `t3.small` | server | `us-east-1a/b/c`, one each | etcd quorum of 3 |
| 1 × `t3.medium` | worker | `us-east-1c` | the schedulable pool |

**All four are schedulable and none of them is tainted.** The measured platform is
3850m / 4688Mi of requests against one t3.medium's 1830m / 3741Mi schedulable
(210.4% CPU, 125.3% RAM — `docs/resource-budget.md`), so a tainted control plane
puts `boutique` Pending forever. k3s labels its server nodes
`node-role.kubernetes.io/control-plane=true` and taints nothing; EKS taints
because it pairs its control plane with a separate worker fleet, and this account
has an 8.0 vCPU quota and therefore no second fleet.

The **designated leader** is the server in `local.azs[0]`, because an instance's AZ
does not change when it is replaced. It is the node that bootstraps the cluster,
that the two followers read their join URL from (via the SSM leader-address
parameter), and that runs the etcd snapshot timer.

### Per-node hardening

- `metadata_options`: `http_tokens = "required"` (IMDSv2), `http_put_response_hop_limit = 1`
  so a pod cannot reach the metadata endpoint at all, `instance_metadata_tags = "disabled"`.
- Root volume: 16 GiB **gp3, encrypted under this stack's own CMK**.
- **No `key_name`, no port 22 rule, no bastion.** `aws ec2 describe-instances`
  shows `KeyName: null`; the access path is SSM Session Manager.
- The k3s systemd unit gets a drop-in with
  `CPU/Memory/IO/TasksAccounting = yes`, and **no `WatchdogSec`**: k3s unsets
  `NOTIFY_SOCKET` right after `READY=1`, so the kubelet's systemd watchdog
  (enabled upstream since Kubernetes 1.35) cannot feed it and systemd kills the
  k3s service once the timeout elapses (k3s-io/k3s#13725).
- The kubelet's **read-only port 10255 is off by k3s's own construction**, not by
  configuration: `pkg/daemons/agent/agent_linux.go` builds
  `argsMap["read-only-port"] = "0"` with an explicit comment that the structured
  config drops a zero, so it is set through the CLI. No security-group rule
  mentions 10255 anywhere in Phase 2.

### Commands

```bash
# 1. inputs
cp terraform.tfvars.example terraform.tfvars        # gitignored
$EDITOR terraform.tfvars                             # admin_cidr, alert_email, bucket

# 2. first plan, with the token supplied from the environment
export TF_VAR_k3s_token="$(openssl rand -hex 32)"
terraform init -backend=false
mv backend.tf /tmp && terraform plan -no-color        # see the note in Phase 2 above
mv /tmp/backend.tf .

# 3. after bootstrap is applied, wire the S3 backend
terraform init -reconfigure -backend-config="bucket=$(terraform -chdir=bootstrap output -raw state_bucket_name)"

# 4. apply (the first cost-bearing apply, ~$61/mo — Aravind's gate)
terraform apply -no-color

# 5. get a kubeconfig, locally only
scripts/bootstrap-cluster.sh

# 6. is the cluster healthy?
KUBECONFIG=~/.kube/boutique-prod.yaml scripts/doctor.sh

# 7. apply the policy layer
kubectl apply -f cluster/rbac/ -f cluster/policies/ -f cluster/priority.yaml

# 8. an interactive session on the leader, for the manual checks
aws ssm start-session --target "$(terraform -chdir=platform output -raw leader_instance_id)"

# 9. prove a restore works, without touching the live cluster
#    (run on the leader; see scripts/etcd-restore-drill.sh)
sudo BOUTIQUE_ETCD_SNAPSHOT_BUCKET="$(terraform -chdir=platform output -raw etcd_snapshot_bucket)" \
  scripts/etcd-restore-drill.sh
```

### A note about `terraform plan` after an edit to the bootstrap script

Editing `cluster-bootstrap.sh` (or `etcd-snapshot.sh`) updates the launch template
in place and creates a new default version; it does **not** replace a running
instance, because EC2 reads the template at `RunInstances` time. To roll a new
bootstrap onto the nodes:

```bash
terraform apply -replace='aws_instance.k3s_server["us-east-1a"]' ...
```

### Phase 4 — etcd snapshots to S3

`boutique-etcd-snapshot.timer` on the leader runs
`k3s etcd-snapshot save --s3 --s3-bucket <bucket> --s3-region us-east-1
--s3-folder etcd-snapshots --etcd-snapshot-compress` at 00:00, 06:00, 12:00 and
18:00 UTC, with `Persistent=true` so a missed run is taken on the next boot.

- **One node uploads**, not three: k3s's S3 retention is cluster-wide, so three
  nodes on one schedule would fill the bucket with three copies of identical state.
- **The credentials are the instance role.** k3s's S3 client builds a chain of
  `Static → FileAWSCredentials → IAM` (`pkg/etcd/s3/s3.go`), so with no
  `--s3-access-key` and no `~/.aws/credentials` the chain reaches the instance
  profile. The grant is `EtcdSnapshotUpload` in `iam-nodes.tf`.
- **Retention is the bucket's lifecycle rule** (default 30 days), not k3s's
  `--etcd-s3-retention`: that is a *server* flag, and the timer's on-demand CLI
  path does not set it. Recorded as a deliberate trade, not an oversight.

## Known gaps, stated rather than hidden

- **VPC flow logs are off.** Costed, deferred, and recorded in `.checkov.yaml`.
- **The ALB to NodePort path is one rule short.** `boutique-edge` allows the
  node group onto Traefik's NodePorts; the reverse direction, nodes accepting
  traffic from the edge group, arrives with the ALB in Phase 5 — until then the
  edge group is attached to nothing.
- **The `ci` and `observability` namespaces have no default-deny NetworkPolicy.**
  SPEC.md's trust boundary 4 asks for one in `boutique` and `ci`; the `boutique`
  one ships in `cluster/policies/policies.yaml`. The other two are held back
  until Phase 7 and 9 have landed their real ports — a default-deny written
  against guessed ports is more dangerous than none, because it fails closed on
  the pipeline and nobody knows why.
- **No `kubeconform`/`conftest` gap for the policy layer.** `scripts/check.sh`
  runs both over `cluster/` since Phase 3.
- **The RBAC is not in drift detection.** It is a manifest, not a
  `kubernetes_*` resource, for the reasons at the top of `cluster/rbac/rbac.yaml`;
  the trade is that a hand edit on the cluster is not caught by
  `terraform plan`. The Phase 8 pipeline re-applies the manifests.

- **The etcd snapshot bucket did not exist** when Phase 2 shipped; Phase 4 creates
  it, in `etcd-backup.tf`, already encrypted under the CMK and with the lifecycle
  rule. The node grant was written before the bucket and now matches it exactly.
- **No IPv6 anywhere.** The VPC is IPv4-only.
- **Two costs the SPEC's table does not carry yet**: the CMK at $1.00/month and
  detailed monitoring at $0.30 per instance per month, which is $2.20/month over
  the remaining window. Recorded in `TASKS.md` rather than quietly absorbed.
- **The k3s installer script is not digest-pinned.** `cluster-bootstrap.sh`
  fetches `https://get.k3s.io` over TLS and runs it; the artefact it installs is
  pinned by `INSTALL_K3S_VERSION`, the script itself is whatever that URL serves.
