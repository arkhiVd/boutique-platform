#!/usr/bin/env bash
# ===========================================================================
# update-admin-cidr.sh — reconcile the operator egress address with the stack.
#
# The operator's ISP address rotates (three seen in 48 hours: 45.115.89.175,
# 138.199.21.205, 149.88.103.57), and `admin_cidr` opens 6443/tcp on
# boutique-node-api. While it is stale, `kubectl` against
# https://3.209.177.15:6443 times out on the TLS handshake while the cluster
# keeps reporting every node Ready — a lockout that looks like an outage.
#
# This script is the automation the SPEC asks for instead of remembering to
# hand-edit a gitignored tfvars file and an out-of-band SG rule.
#
#   ./scripts/update-admin-cidr.sh            # reconcile, or report up-to-date
#
# It prints what it is about to do before it does it, and stops without
# touching anything when the address already matches.
#
# The order is deliberate and safe, and the import step is the part the first
# version got wrong (2026-10-15: applying while a matching out-of-band rule
# already exists fails with InvalidPermission.Duplicate and leaves state
# half-swapped):
#   1. resolve the CURRENT egress address (the address this script runs from,
#      which is the only address that can reach the API server anyway)
#   2. if state, tfvars and AWS all already say that address, stop: idempotent,
#      so this is safe on a timer
#   3. if the egress rule already exists in AWS but is not in state, IMPORT it,
#      so Terraform owns the rule that is actually granting access
#   4. write it into terraform.tfvars and apply the rule resource
#   5. revoke any other 6443 /32 left in AWS (none of them is managed now)
#   6. prove the API is still reachable with kubectl before reporting success
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# The SG the 6443 rule lives on: platform/security-groups.tf,
# aws_security_group_rule.node_api_ingress_kube_api. Resolved by Name tag (the
# resource sets tags = { Name = "boutique-node-api" }), which survives the
# stack being rebuilt and does not duplicate an id that is not an output.
SG_ID="$(aws ec2 describe-security-groups --filters \
  'Name=tag:Name,Values=boutique-node-api' \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  echo "cannot resolve the boutique-node-api SG" >&2; exit 1
fi

PUBLIC_IP="$(curl -s --max-time 15 https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
  echo "could not determine the egress address (got '${PUBLIC_IP}')" >&2
  exit 1
}
NEW_CIDR="${PUBLIC_IP}/32"

# --- resolve the current stack value without a plan -----------------------
CURRENT="$(grep -E '^[[:space:]]*admin_cidr[[:space:]]*=' platform/terraform.tfvars \
  | sed -E 's/^[[:space:]]*admin_cidr[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')"
[ -n "$CURRENT" ] || { echo "admin_cidr not found in platform/terraform.tfvars" >&2; exit 1; }

# --- what AWS actually has on 6443 ----------------------------------------
echo "operator egress now:  ${PUBLIC_IP}"
echo "terraform.tfvars has: ${CURRENT}"
mapfile -t LIVE < <(python3 - "$SG_ID" <<'PY'
import json, subprocess, sys
args = ["aws", "ec2", "describe-security-groups", "--group-ids", sys.argv[1],
        "--query", "SecurityGroups[0].IpPermissions", "--output", "json"]
data = json.loads(subprocess.check_output(args, text=True))
for perm in data:
    if perm.get("FromPort") != 6443 or perm.get("ToPort") != 6443:
        continue
    for r in perm.get("IpRanges", []):
        print(r["CidrIp"])
PY
)

# --- what Terraform state tracks, and what AWS has -------------------------
# The rule's managed CIDR is the one in state, not the tfvars value: the two
# drift exactly when the operator edits tfvars and never applies. Reading state
# needs no plan and no API round trip.
STATE_CIDR="$(terraform -chdir=platform state show \
  aws_security_group_rule.node_api_ingress_kube_api 2>/dev/null \
  | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}/32' | head -1)"

[[ " ${LIVE[*]-} " == *" ${NEW_CIDR} "* ]] && EGRESS_IN_AWS=1 || EGRESS_IN_AWS=0

# All three sources must agree: the tfvars value is what the next
# `terraform plan`/`apply` anywhere will read, so a stale tfvars line is a
# latent lockout even while state and AWS still agree. Measured: the first
# version of this check passed with a stale tfvars line.
if [[ "$STATE_CIDR" == "$NEW_CIDR" && "$CURRENT" == "$NEW_CIDR" \
   && "$EGRESS_IN_AWS" == 1 && "${#LIVE[@]}" -eq 1 ]]; then
  echo "in sync: terraform, tfvars and AWS all say ${NEW_CIDR}. Nothing to do."
  exit 0
fi

for c in "${LIVE[@]-}"; do
  if [[ "$c" != "$NEW_CIDR" ]]; then
    echo "AWS also has:        ${c}"
  fi
done
[ "$STATE_CIDR" != "$CURRENT" ] && echo "state has:           ${STATE_CIDR:-<none>}"

# --- adopt the rule the operator hand-added, rather than fighting it --------
# Measured 2026-10-15: applying while the egress rule already exists in AWS
# fails with InvalidPermission.Duplicate and leaves the stack half-swapped
# (destroy succeeded, create rejected) -- the state/rule mismatch this branch
# spent a repair fixing. When the egress rule is already present, the right
# move is to import it and let Terraform own it; the create-with-no-duplicate
# path stays for the case where AWS has only the stale TF rule.
if [[ "$EGRESS_IN_AWS" == 1 && "$STATE_CIDR" != "$NEW_CIDR" ]]; then
  echo "-> the egress rule already exists in AWS; importing it into state"
  TF_VAR_k3s_token="$(cat /tmp/k3s.token)" terraform -chdir=platform import \
    'aws_security_group_rule.node_api_ingress_kube_api' \
    "sg-${SG_ID#sg-}_ingress_tcp_6443_6443_${NEW_CIDR}" \    | tail -1
fi

# --- point the stack at it --------------------------------------------------
if [[ "$CURRENT" != "$NEW_CIDR" ]]; then
  echo "-> tfvars ${CURRENT} -> ${NEW_CIDR}"
  # One line, replaced in place. The file is gitignored (platform/*.tfvars), so
  # this is the live input, not a tracked artifact; the value is not a secret.
  python3 - "$NEW_CIDR" <<'PY'
import pathlib, re, sys
new = sys.argv[1]
p = pathlib.Path("platform/terraform.tfvars")
s = p.read_text()
pat = re.compile(r'(^\s*admin_cidr\s*=\s*")[^"]+(")', re.M)
s2, n = pat.subn(lambda m: m.group(1) + new + m.group(2), s)
if n != 1:
    raise SystemExit(f"expected exactly 1 admin_cidr line, found {n}")
p.write_text(s2)
PY
  TF_VAR_k3s_token="$(cat /tmp/k3s.token)" terraform -chdir=platform apply -auto-approve \
    -target=aws_security_group_rule.node_api_ingress_kube_api 2>&1 | grep -E 'Apply complete|Error' || true
fi

# --- then revoke every other 6443 /32, none of which Terraform owns ---------
for c in "${LIVE[@]-}"; do
  if [[ -n "$c" && "$c" != "$NEW_CIDR" ]]; then
    echo "-> revoking leftover rule ${c}"
    aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
      --protocol tcp --port 6443 --cidr "$c" || true
  fi
done

# --- prove the API is still reachable before saying so ---------------------
mapfile -t LEFT < <(python3 - "$SG_ID" <<'PY'
import json, subprocess, sys
args = ["aws", "ec2", "describe-security-groups", "--group-ids", sys.argv[1],
        "--query", "SecurityGroups[0].IpPermissions[?FromPort==`6443`].IpRanges[].CidrIp",
        "--output", "json"]
print("\n".join(json.loads(subprocess.check_output(args, text=True))))
PY
)
echo "AWS now has:         ${LEFT[*]-<none>}"

if KUBECONFIG="${KUBECONFIG:-$HOME/.kube/boutique-prod.yaml}" timeout 30 \
    kubectl get nodes --no-headers >/dev/null 2>&1; then
  echo "kube-apiserver still reachable. Done."
else
  echo "WARNING: the API server did not answer. The address still allowed in AWS" \
    "is ${LEFT[*]-<none>}; if this machine's egress moved again, re-run this script." >&2
  exit 1
fi
