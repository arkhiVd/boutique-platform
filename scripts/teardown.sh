#!/usr/bin/env bash
# ===========================================================================
# teardown.sh -- return the account to $0, in the only order that works.
#
#   scripts/teardown.sh                                    inventory only (default)
#   scripts/teardown.sh --confirm "destroy boutique-platform"   the real thing
#
# A bare `terraform destroy` leaves money behind or stops half way, for reasons
# each measured on this platform:
#   1. EBS volumes created by the CSI driver for PVCs are NOT in Terraform state.
#      Destroying the nodes strands them, unattached and billing (five such
#      volumes from the 2026-10-14 cluster were found and deleted 2026-10-17).
#      So the PVCs are deleted while the cluster can still reclaim them.
#   2. No bucket has force_destroy, so a non-empty bucket fails the destroy. The
#      etcd-snapshot and ALB-log buckets are emptied first, every version.
#   3. platform/'s state lives in bootstrap/'s versioned bucket: platform goes
#      first, then the state bucket is emptied of every version, then bootstrap.
#
# ROADMAP Phase 14 names a destroy.yml workflow. This is a script instead: the CI
# apply role is scoped to create and update, and a destroy needs deletes on KMS,
# WAF, IAM and every bucket, which a role GitHub can assume should not hold. It
# runs from an operator's machine with the account's own credentials.
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
PHRASE="destroy boutique-platform"
CONFIRM=""
[ "${1:-}" = "--confirm" ] && CONFIRM="${2:-}"
REGION="${AWS_REGION:-us-east-1}"

cyan() { printf '\033[1;36m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
die() { red "FATAL $*"; exit 1; }
for t in aws terraform kubectl jq; do command -v "$t" >/dev/null || die "$t not found"; done

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" || die "no AWS credentials"
export TF_VAR_k3s_token="${TF_VAR_k3s_token:-$(aws ssm get-parameter --region "$REGION" \
  --name /boutique-platform/k3s/token --with-decryption --query Parameter.Value --output text 2>/dev/null)}"
[ -n "$TF_VAR_k3s_token" ] || export TF_VAR_k3s_token=teardown-placeholder-not-a-credential-000000000000

# shellcheck disable=SC2016  # the backticks are JMESPath literals, not shell
csi_volumes() { aws ec2 describe-volumes --region "$REGION" --filters Name=tag-key,Values=ebs.csi.aws.com/cluster \
  --query 'Volumes[].[VolumeId,State,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' --output text; }
project_buckets() { aws s3api list-buckets --query "Buckets[?starts_with(Name, 'boutique-platform-')].Name" --output text | tr '\t' '\n'; }
empty_bucket() { # every object version and delete marker, 1000 per delete call
  local b="$1" page
  while :; do
    # jq, not a JMESPath projection: a bucket with no delete markers (or no
    # versions) makes the projection emit null, and delete-objects rejects it.
    page="$(aws s3api list-object-versions --bucket "$b" --max-items 1000 --output json \
      | jq -c '{Objects: [((.Versions // []) + (.DeleteMarkers // []))[] | {Key, VersionId}], Quiet: true}')"
    [ "$(printf '%s' "$page" | jq '.Objects | length')" -gt 0 ] || break
    aws s3api delete-objects --bucket "$b" --delete "$page" >/dev/null || return 1
  done
}
versions() { aws s3api list-object-versions --bucket "$1" --output json 2>/dev/null \
  | jq '((.Versions // []) + (.DeleteMarkers // [])) | length'; }

cyan "== inventory, account $ACCOUNT"
printf '  terraform state: bootstrap %s resources, platform %s resources\n' \
  "$(terraform -chdir=bootstrap state list 2>/dev/null | wc -l)" "$(terraform -chdir=platform state list 2>/dev/null | wc -l)"
echo "  CSI volumes (not in Terraform state):"; csi_volumes | sed 's/^/    /'
echo "  project buckets and object versions:"
for b in $(project_buckets); do
  printf '    %-60s %s\n' "$b" "$(versions "$b")"
done
echo "  running instances:"; aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Project,Values=boutique-platform Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output text | sed 's/^/    /'

if [ "$CONFIRM" != "$PHRASE" ]; then
  echo
  echo "Inventory only. To destroy everything above, run:"
  echo "  scripts/teardown.sh --confirm \"$PHRASE\""
  exit 0
fi

START=$(date -u +%s)
cyan "== 1. delete the PVCs while the cluster can still reclaim their volumes"
if kubectl get --raw /readyz >/dev/null 2>&1; then
  for ns in observability ci; do kubectl delete ns "$ns" --wait=true --timeout=600s; done
  for _ in $(seq 1 60); do [ -z "$(csi_volumes)" ] && break; sleep 10; done
else
  echo "  the cluster is unreachable; stranded volumes are deleted in step 4"
fi

cyan "== 2. empty the platform buckets (every version)"
for b in $(project_buckets); do
  case "$b" in *tfstate*) continue ;; esac
  echo "  $b"; empty_bucket "$b" || die "could not empty $b"
done

cyan "== 3. terraform destroy platform/"
terraform -chdir=platform destroy -auto-approve -input=false -no-color | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || die "platform destroy failed; state is intact, re-run after fixing"

cyan "== 4. anything the CSI driver left behind"
csi_volumes | while read -r v state _; do
  [ "$state" = available ] && aws ec2 delete-volume --region "$REGION" --volume-id "$v" && echo "  deleted $v"
done

cyan "== 5. empty the state bucket, then terraform destroy bootstrap/"
for b in $(project_buckets); do case "$b" in *tfstate*) echo "  $b"; empty_bucket "$b" || die "could not empty $b" ;; esac; done
terraform -chdir=bootstrap destroy -auto-approve -input=false -no-color | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || die "bootstrap destroy failed"

cyan "== 6. tell CI there is nothing left to plan"
# The PR plan job skips its AWS steps when this repository variable is
# 'false' (.github/workflows/plan.yml); the plan role it would assume is gone.
if command -v gh >/dev/null && gh variable set PLATFORM_DEPLOYED --body false >/dev/null 2>&1; then
  echo "  repository variable PLATFORM_DEPLOYED=false"
else
  echo "  set the repository variable PLATFORM_DEPLOYED=false by hand (gh unavailable)"
fi

cyan "== 7. what is left, by the Project tag"
aws resourcegroupstaggingapi get-resources --region "$REGION" --tag-filters Key=Project,Values=boutique-platform \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed 's/^/  /'
csi_volumes | sed 's/^/  volume /'
echo "  took $(( $(date -u +%s) - START ))s"
echo
echo "The bill needs a week to settle. Check it with:"
echo "  aws ce get-cost-and-usage --time-period Start=$(date -u -d '+1 day' +%F),End=$(date -u -d '+8 days' +%F) \\"
echo "    --granularity DAILY --metrics UnblendedCost --query 'ResultsByTime[].[TimePeriod.Start,Total.UnblendedCost.Amount]'"
