#!/bin/bash
# ===========================================================================
# boutique-platform -- etcd snapshot to S3, Phase 4.
#
# Written to /usr/local/bin/boutique-etcd-snapshot.sh by
# platform/cluster-bootstrap.sh (which renders it into the node's user_data) and
# driven by /etc/systemd/system/boutique-etcd-snapshot.timer on the designated
# leader only.
#
# Configuration comes from /etc/boutique/bootstrap.conf, which the bootstrap
# script writes from the Terraform-rendered config block. It is a separate file
# rather than hard-coded values so this script stays independently checkable:
# it is a standalone file that shellcheck and bash -n can read directly, not
# heredoc text inside another script.
#
# WHY THERE ARE NO AWS KEYS HERE
#   k3s's S3 client builds its credentials as a chain:
#       credentials.NewChainCredentials([]credentials.Provider{
#           credentials.Static{... --s3-access-key / --s3-secret-key / env ...},
#           credentials.FileAWSCredentials{},
#           credentials.IAM{}})
#   (k3s pkg/etcd/s3/s3.go). This script passes no keys and leaves no
#   ~/.aws/credentials on the node, so the chain's static and file providers are
#   empty and the IAM provider supplies the instance role. The grant that lets
#   it work is `EtcdSnapshotUpload` in platform/iam-nodes.tf, scoped to
#   s3://<bucket>/etcd-snapshots/*.
#
#   HOME is exported because credentials.FileAWSCredentials needs a home
#   directory to look in before it fails and the chain moves on to IAM. Leaving
#   HOME unset would also work -- by failing the provider rather than by
#   choosing the role, which is not a thing to rely on.
# ===========================================================================
set -euo pipefail

readonly CONF=/etc/boutique/bootstrap.conf
[ -r "$CONF" ] || { printf 'FATAL %s is missing\n' "$CONF" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"

readonly LOG=/var/log/boutique-etcd-snapshot.log
exec >>"$LOG" 2>&1

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

export HOME=/root

for var in K3S_SNAPSHOT_BUCKET K3S_SNAPSHOT_FOLDER AWS_REGION; do
  if [ -z "${!var:-}" ]; then
    printf 'FATAL %s is not set in %s\n' "$var" "$CONF" >&2
    exit 1
  fi
done

log "snapshot starting: s3://$K3S_SNAPSHOT_BUCKET/$K3S_SNAPSHOT_FOLDER/ (region $AWS_REGION)"
START="$(date -u +%s)"

# --s3-region is passed even though it defaults to us-east-1: the bucket is in
# this region and an explicit value is the difference between a signed request
# that works and one that fails with SignatureDoesNotMatch in another region.
k3s etcd-snapshot save \
  --s3 \
  --s3-bucket "$K3S_SNAPSHOT_BUCKET" \
  --s3-region "$AWS_REGION" \
  --s3-folder "$K3S_SNAPSHOT_FOLDER" \
  --etcd-snapshot-compress

# The post-condition. A failed save exits non-zero and prints FATAL, so reaching
# this line means upload was accepted; listing is what proves the object is
# actually there, and it also prints the retention picture the operator needs:
# k3s's --etcd-s3-retention is a server-side flag that this on-demand CLI path
# does not set, so retention in this design is enforced by the bucket's lifecycle
# rule (platform/etcd-backup.tf), not by k3s.
LIST="$(k3s etcd-snapshot ls \
  --s3 --s3-bucket "$K3S_SNAPSHOT_BUCKET" \
  --s3-region "$AWS_REGION" --s3-folder "$K3S_SNAPSHOT_FOLDER")"
printf '%s\n' "$LIST" | sed 's/^/    /'

ELAPSED=$(( $(date -u +%s) - START ))
COUNT="$(printf '%s\n' "$LIST" | grep -c 's3://' || true)"
log "snapshot complete: $COUNT object(s) listed in ${ELAPSED}s"

if [ "$COUNT" -lt 1 ]; then
  log 'FAILED: no object listed after a reported save'
  exit 1
fi
