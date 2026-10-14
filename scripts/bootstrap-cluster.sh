#!/usr/bin/env bash
# ===========================================================================
# bootstrap-cluster.sh -- get from "the instances exist" to `kubectl get nodes`.
#
# WHAT THIS DOES AND DOES NOT DO
#   It runs the k3s bootstrap over SSM Session Manager, which is the only access
#   path the SPEC allows: no key pair, no port 22, no bastion. Specifically it
#
#     1. finds the designated leader,
#     2. asks it (through `aws ssm send-command`, as root) for its kubeconfig,
#     3. writes that kubeconfig to ~/.kube/boutique-prod.yaml and NOTHING ELSE,
#     4. prints `k3s kubectl get nodes` from the leader, and
#     5. prints the one `export KUBECONFIG=...` line the operator needs.
#
#   send-command is used rather than `aws ssm start-session` because this script
#   is meant to be re-run unattended: start-session needs a TTY and the
#   session-manager-plugin, and its output cannot be captured into a file. The
#   interactive path is printed at the end, for the operator who wants a shell.
#
# THE KUBECONFIG
#   Written to $KUBECONFIG_DEST, which defaults to ~/.kube/boutique-prod.yaml.
#   The repo root's .kube/ is gitignored, and this script REFUSES to write to a
#   path inside the repository even if someone points it there: the SPEC's exit
#   criterion is "no kubeconfig in the repo", and the cheapest way to lose that
#   is a `cd` in the wrong directory. $HOME/.kube is used because it is outside
#   the repo by construction, and because KUBECONFIG there is the convention
#   every other tool already looks at.
#
#   The kubeconfig is rewritten on the way through: k3s.yaml points at
#   https://127.0.0.1:6443, which is correct on the node and useless from a
#   workstation. See --leader-address for the two rules behind the rewrite.
#
# IDEMPOTENT
#   Every step can be run again. It overwrites the kubeconfig, re-reads the node
#   list, and prints the same export line. It never appends to the file, never
#   restarts k3s, and never writes to the cluster.
# ===========================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K3S_KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml
K3S_LEADER_IP_PARAMETER=/boutique-platform/k3s/leader-ip
KUBECONFIG_DEST="${KUBECONFIG_DEST:-$HOME/.kube/boutique-prod.yaml}"
LEADER_ADDRESS="${LEADER_ADDRESS:-}"
TARGET_INSTANCE="${TARGET_INSTANCE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSM_WAIT_SECONDS=120

cyan() { printf '\033[1;36m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
die() { red "FATAL $*"; exit 1; }

step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
for tool in aws kubectl sed; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

# ---------------------------------------------------------------------------
# 2. Find the leader
# ---------------------------------------------------------------------------
# Two ways, in order of preference:
#
#   TARGET_INSTANCE=<i-...>        explicit, for the times when it is not obvious
#   otherwise: read /boutique-platform/k3s/leader-ip, then ask EC2 which instance
#     holds that private address.
#
# The second path is why the leader address lives in SSM at all: the node needs
# it without holding an AWS key, and the workstation needs it without a working
# kubeconfig.
step "Find the designated k3s leader"
if [ -z "$TARGET_INSTANCE" ]; then
  LEADER_IP="$(aws ssm get-parameter --region "$AWS_REGION" \
    --name "$K3S_LEADER_IP_PARAMETER" --query 'Parameter.Value' --output text 2>/dev/null \
    || true)"
  [ -n "$LEADER_IP" ] || die "could not read $K3S_LEADER_IP_PARAMETER (no cluster applied yet?); pass TARGET_INSTANCE=<i-...> to override"
  TARGET_INSTANCE="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=private-ip-address,Values=$LEADER_IP" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
  [ -n "$TARGET_INSTANCE" ] || die "no instance holds private address $LEADER_IP in $AWS_REGION"
fi
green "leader instance = $TARGET_INSTANCE"

# ---------------------------------------------------------------------------
# 3. Ask the leader for its kubeconfig, over SSM, as root
# ---------------------------------------------------------------------------
# sudo, because /etc/rancher/k3s/k3s.yaml is 0600 root:root and the SSM agent
# runs as ssm-user. Amazon Linux 2023 grants ssm-user passwordless sudo; nothing
# else on the node can read the file, which is the point.
step "Read /etc/rancher/k3s/k3s.yaml from $TARGET_INSTANCE over SSM"
COMMAND_ID="$(aws ssm send-command --region "$AWS_REGION" \
  --instance-ids "$TARGET_INSTANCE" \
  --document-name AWS-RunShellScript \
  --comment "boutique-platform: read k3s kubeconfig (bootstrap-cluster.sh)" \
  --parameters "commands=[\"sudo cat $K3S_KUBECONFIG_PATH\"]" \
  --query 'Command.CommandId' --output text 2>&1)" \
  || die "aws ssm send-command failed: $COMMAND_ID"

waited=0
until STATUS="$(aws ssm get-command-invocation --region "$AWS_REGION" \
        --instance-id "$TARGET_INSTANCE" --command-id "$COMMAND_ID" \
        --plugin-name aws:RunShellScript --query 'Status' --output text 2>/dev/null)"; do
  [ "$waited" -ge "$SSM_WAIT_SECONDS" ] && die "SSM invocation $COMMAND_ID did not finish within ${SSM_WAIT_SECONDS}s"
  sleep 3; waited=$((waited + 3))
done

if [ "$STATUS" != "Success" ]; then
  red "SSM invocation status: $STATUS"
  aws ssm get-command-invocation --region "$AWS_REGION" --instance-id "$TARGET_INSTANCE" \
    --command-id "$COMMAND_ID" --plugin-name aws:RunShellScript \
    --query '[Status, StandardErrorContent]' --output text 2>/dev/null || true
  die "the leader did not return a kubeconfig. Check that cloud-init finished: run scripts/doctor.sh --node-log $TARGET_INSTANCE"
fi

RAW_KUBECONFIG="$(aws ssm get-command-invocation --region "$AWS_REGION" \
  --instance-id "$TARGET_INSTANCE" --command-id "$COMMAND_ID" \
  --plugin-name aws:RunShellScript \
  --query 'StandardOutputContent' --output text 2>/dev/null)"

printf '%s\n' "$RAW_KUBECONFIG" | grep -q 'apiVersion: v1' \
  || die "the file returned by the leader is not a kubeconfig (no apiVersion: v1)"
printf '%s\n' "$RAW_KUBECONFIG" | grep -q 'client-certificate-data' \
  || die "the returned kubeconfig has no client certificate"

# ---------------------------------------------------------------------------
# 4. Where does the workstation point?
# ---------------------------------------------------------------------------
# k3s.yaml says `server: https://127.0.0.1:6443`, which is right on the node and
# wrong everywhere else. Two rules decide the replacement:
#
#   LEADER_ADDRESS=<ip>   if set, use it verbatim.
#   otherwise             the leader's PUBLIC address, because the nodes sit in
#                         public subnets (no NAT budget) and the node-api
#                         security group opens 6443/tcp to var.admin_cidr and
#                         nothing else. If the operator is on a VPN inside the
#                         VPC, set LEADER_ADDRESS to the private address instead --
#                         the rewrite is one sed either way.
if [ -z "$LEADER_ADDRESS" ]; then
  LEADER_ADDRESS="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --instance-ids "$TARGET_INSTANCE" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || true)"
  [ -n "$LEADER_ADDRESS" ] || die "the leader has no public address; set LEADER_ADDRESS=<private-ip> to use the VPC route"
fi

step "Rewrite the apiserver address to $LEADER_ADDRESS"
KUBECONFIG="$(printf '%s\n' "$RAW_KUBECONFIG" | sed \
  -e "s|https://127.0.0.1:6443|https://${LEADER_ADDRESS}:6443|g" \
  -e "s|https://localhost:6443|https://${LEADER_ADDRESS}:6443|g")"

# ---------------------------------------------------------------------------
# 5. Write it, somewhere it cannot be committed
# ---------------------------------------------------------------------------
# The guard: refuse any destination inside this repository. The repo root's
# .kube/ IS gitignored (checks with `git check-ignore`), so writing there would
# already be safe -- but a path that is only safe by an ignore rule is one refactor
# away from being committed, and this is the single file whose disclosure is the
# whole cluster.
step "Write the kubeconfig to $KUBECONFIG_DEST"
REPO="$(cd "$REPO_ROOT" && pwd)"
case "$(cd "$(dirname "$KUBECONFIG_DEST")" 2>/dev/null && pwd)/$(basename "$KUBECONFIG_DEST")" in
  "$REPO"/*)
    die "KUBECONFIG_DEST is inside the repository ($REPO). The kubeconfig never lands in git; set KUBECONFIG_DEST=$HOME/.kube/boutique-prod.yaml"
    ;;
esac
if git -C "$REPO" check-ignore -q ".kube/boutique-prod.yaml" 2>/dev/null; then
  cyan "  (note: .kube/ in the repo is gitignored, but this script still refuses to write there)"
fi

mkdir -p "$(dirname "$KUBECONFIG_DEST")"
printf '%s\n' "$KUBECONFIG" >"$KUBECONFIG_DEST"
chmod 0600 "$KUBECONFIG_DEST"
green "written: $KUBECONFIG_DEST (mode $(stat -c %a "$KUBECONFIG_DEST"))"

# ---------------------------------------------------------------------------
# 6. Prove it works, from the workstation and from the leader
# ---------------------------------------------------------------------------
step "kubectl version and cluster-info through the new kubeconfig"
KUBECONFIG="$KUBECONFIG_DEST" kubectl version --short 2>/dev/null || true
KUBECONFIG="$KUBECONFIG_DEST" kubectl cluster-info 2>&1 | sed 's/^/    /' || true

step "k3s kubectl get nodes, run on the leader over SSM"
# Two independent views of the same fact: the local one, which is what the
# operator will use from now on, and the one from inside the cluster, which is
# the one that proves the SSM path still works when the outside route does not.
NODES_COMMAND_ID="$(aws ssm send-command --region "$AWS_REGION" \
  --instance-ids "$TARGET_INSTANCE" \
  --document-name AWS-RunShellScript \
  --comment "boutique-platform: k3s kubectl get nodes (bootstrap-cluster.sh)" \
  --parameters 'commands=["k3s kubectl get nodes -o wide"]' \
  --query 'Command.CommandId' --output text)" \
  || die "could not ask the leader for its node list"
waited=0
until STATUS="$(aws ssm get-command-invocation --region "$AWS_REGION" \
        --instance-id "$TARGET_INSTANCE" --command-id "$NODES_COMMAND_ID" \
        --plugin-name aws:RunShellScript --query 'Status' --output text 2>/dev/null)"; do
  [ "$waited" -ge "$SSM_WAIT_SECONDS" ] && die "the node list invocation did not finish within ${SSM_WAIT_SECONDS}s"
  sleep 3; waited=$((waited + 3))
done
[ "$STATUS" = "Success" ] || die "the leader returned status $STATUS for the node list"
aws ssm get-command-invocation --region "$AWS_REGION" --instance-id "$TARGET_INSTANCE" \
  --command-id "$NODES_COMMAND_ID" --plugin-name aws:RunShellScript \
  --query 'StandardOutputContent' --output text 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 7. Tell the operator what to run next
# ---------------------------------------------------------------------------
step "Next"
cat <<EOF
  export KUBECONFIG=$KUBECONFIG_DEST
  scripts/doctor.sh                       # the one-shot health report
  aws ssm start-session --target $TARGET_INSTANCE    # an interactive session on the leader
  terraform -chdir=platform output -raw leader_instance_id   # what that --target is
EOF
green "done. Re-run this script at any time; it is safe to repeat."
