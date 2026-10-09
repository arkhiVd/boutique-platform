#!/usr/bin/env bash
# ===========================================================================
# etcd-restore-drill.sh -- prove a restore works, without touching the cluster.
#
# WHY THIS DRILL IS NOT "restore the cluster and see if it comes back"
#   That is the test everyone means and nobody runs, because it is the one action
#   that can turn a partial outage into a total one. A k3s restore is destructive
#   BY CONSTRUCTION (docs.k3s.io/cli/etcd-snapshot, "Restoring Snapshots"): it
#   moves the current etcd database aside, extracts the snapshot, verifies the
#   checksum, starts etcd, and removes every cluster member except the current
#   node. There is no "try it and put it back".
#
#   So this drill does the part that actually fails in practice -- the snapshot
#   itself -- in full: download the newest snapshot from S3, verify its hash,
#   revision and key count, and restore it into a SCRATCH data directory with
#   etcdctl. It then times each phase and reports the total. Everything except
#   `--target cluster-live` is read-only with respect to the live cluster, and the
#   script refuses to write anywhere under /var/lib/rancher/k3s in any mode.
#
# WHAT IT PROVES AND WHAT IT DOES NOT
#   PROVES: the snapshot in S3 is intact, downloadable, parseable by etcdctl, and
#   loadable into a real etcd data directory, with a measured duration for each
#   of those steps. That is the part that rots silently -- a snapshot that never
#   uploaded, one that uploaded truncated, one whose lifecycle rule deleted it a
#   day early, one whose KMS grant stopped working.
#   DOES NOT PROVE: that k3s will rejoin a restored cluster, that the CA and join
#   token still decrypt the snapshot's bootstrap data, or that the whole cluster
#   comes back. Those need a live cluster and a maintenance window, which is why
#   the destructive path is a separate, explicitly-gated mode and not the default.
#
# WHERE IT RUNS
#   Designed for the designated k3s leader, where k3s ships its own etcdctl at
#   /var/lib/rancher/k3s/data/current/bin/etcdctl and where the instance role can
#   read the snapshot bucket with no extra credentials. It also runs on a
#   workstation that has `aws`, `etcdctl` and `sha256sum`, and it says so loudly
#   when one of them is missing rather than passing by omission.
# ===========================================================================
set -uo pipefail

BUCKET="${BOUTIQUE_ETCD_SNAPSHOT_BUCKET:-}"
FOLDER="${BOUTIQUE_ETCD_SNAPSHOT_FOLDER:-etcd-snapshots}"
REGION="${AWS_REGION:-us-east-1}"
SNAPSHOT="${SNAPSHOT:-}"
SCRATCH_DIR="${SCRATCH_DIR:-}"
TARGET="${TARGET:-scratch}"
KEEP="${KEEP:-no}"
LIVE_ACK="${LIVE_ACK:-no}"

# The one path this script must never write to. k3s's data directory contains the
# live cluster: server/db/etcd is the state, server/tls is the CA, and
# server/token is the join token. A restore here is the real thing, not a drill.
readonly K3S_DATA_DIR=/var/lib/rancher/k3s

cyan() { printf '\033[1;36m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
die() { red "FATAL $*"; exit 1; }
now() { date -u +%s; }

usage() {
  cat <<'EOF'
boutique etcd restore drill -- prove a snapshot restores, without touching the cluster.

  TARGET=scratch (default)   restore into a throwaway data dir under $TMPDIR
                             SAFE: nothing outside the scratch dir is written
  TARGET=cluster-live        the real restore path. REFUSED unless
                             LIVE_ACK=yes is also set

  BOUTIQUE_ETCD_SNAPSHOT_BUCKET=<bucket>   override the bucket
  FOLDER=etcd-snapshots                   override the prefix
  SNAPSHOT=<name>                          otherwise the newest object is used
  SCRATCH_DIR=<path>                       default: a mktemp directory
  KEEP=yes                                 leave the scratch dir for inspection

examples
  # on the designated k3s leader, over SSM:
  sudo BOUTIQUE_ETCD_SNAPSHOT_BUCKET=... /usr/local/bin/boutique-etcd-restore-drill.sh
  # the destructive path, in a maintenance window only:
  sudo TARGET=cluster-live LIVE_ACK=yes ...
EOF
}

# ---------------------------------------------------------------------------
# 0. Arguments and the guard rails
# ---------------------------------------------------------------------------
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { usage; exit 0; }

case "$TARGET" in
  scratch) ;;
  cluster-live)
    if [ "$LIVE_ACK" != "yes" ]; then
      die "TARGET=cluster-live refused. A k3s restore removes every cluster member except the node it runs on and moves the live etcd database aside; there is no undo. Re-run with LIVE_ACK=yes if that is genuinely what you intend, in a maintenance window."
    fi
    ;;
  *) die "TARGET must be scratch or cluster-live (got $TARGET)" ;;
esac

command -v aws >/dev/null 2>&1 || die "aws cli not on PATH"

# The scratch-directory guard, hoisted above the etcdctl lookup so it cannot be
# skipped by an environment that also lacks etcdctl. k3s's data directory holds the
# live cluster: server/db/etcd is the state, server/tls is the CA, server/token is
# the join token. Nothing in this drill writes there, in any mode.
if [ -n "$SCRATCH_DIR" ]; then
  # `realpath -m` resolves a path that does not exist yet, which `cd; pwd`
  # cannot. Normalising before comparing is what stops a symlinked or relative
  # SCRATCH_DIR reaching the live data directory by accident.
  case "$(realpath -m "$SCRATCH_DIR")/" in
    "$K3S_DATA_DIR"*)
      die "SCRATCH_DIR resolves under $K3S_DATA_DIR. This drill never writes to the live k3s data directory, in any mode."
      ;;
  esac
fi

# etcdctl: k3s ships its own, and the static build on a workstation is not always
# the same version as the one that wrote the snapshot. Prefer the node's copy.
ETCDCTL="${ETCDCTL:-}"
if [ -z "$ETCDCTL" ]; then
  if [ -x /var/lib/rancher/k3s/data/current/bin/etcdctl ]; then
    ETCDCTL=/var/lib/rancher/k3s/data/current/bin/etcdctl
  elif command -v etcdctl >/dev/null 2>&1; then
    ETCDCTL=etcdctl
  else
    die "no etcdctl found (looked for /var/lib/rancher/k3s/data/current/bin/etcdctl and etcdctl on PATH). Run this on the designated k3s leader, or set ETCDCTL. The bucket download and checksum steps CANNOT be completed without it, so this is a reported gap and not a pass."
  fi
fi

[ -n "$BUCKET" ] || die "BOUTIQUE_ETCD_SNAPSHOT_BUCKET is not set. On the leader it is in /etc/boutique/bootstrap.conf; anywhere else, pass it."

TOTAL_START="$(now)"

# ---------------------------------------------------------------------------
# 1. Which snapshot?
# ---------------------------------------------------------------------------
cyan "== the snapshot to restore =="
if [ -z "$SNAPSHOT" ]; then
  # The newest object in the prefix. k3s names them <name>-<nodename>-<unix-ts>,
  # and a lexical sort on the timestamp suffix is not a chronological sort across
  # nodes, so the listing is sorted by LastModified instead.
  SNAPSHOT="$(aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" \
    --prefix "$FOLDER/" --query 'reverse(sort_by(Contents,&LastModified))[0].Key' \
    --output text 2>/dev/null | sed "s|^$FOLDER/||")"
  [ -n "$SNAPSHOT" ] || die "no objects under s3://$BUCKET/$FOLDER/ -- the Phase 4 timer has never run successfully, or the lifecycle rule expired them"
fi
SNAPSHOT_NAME="$(basename "$SNAPSHOT")"
echo "    bucket   = s3://$BUCKET/$FOLDER/"
echo "    snapshot = $SNAPSHOT_NAME"

# ---------------------------------------------------------------------------
# 2. Download into the scratch directory
# ---------------------------------------------------------------------------
if [ -z "$SCRATCH_DIR" ]; then
  SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/boutique-etcd-restore-drill.XXXXXX")"
fi

# The guard, checked against the RESOLVED path so a symlink or a `~/..` cannot
# reach the live data directory by accident.
case "$(cd "$SCRATCH_DIR" && pwd -P)/" in
  "$K3S_DATA_DIR"*) die "SCRATCH_DIR resolves under $K3S_DATA_DIR. This drill never writes to the live k3s data directory." ;;
esac

mkdir -p "$SCRATCH_DIR"
LOCAL_FILE="$SCRATCH_DIR/$SNAPSHOT_NAME"

cyan "== download to $LOCAL_FILE =="
DOWNLOAD_START="$(now)"
aws s3 cp --region "$REGION" "s3://$BUCKET/$FOLDER/$SNAPSHOT_NAME" "$LOCAL_FILE" 2>&1 | sed 's/^/    /' \
  || die "aws s3 cp failed for s3://$BUCKET/$FOLDER/$SNAPSHOT_NAME"
# An `aws s3 cp` that returns 0 for a missing object is not possible, but a file
# written by something else under the same scratch directory is. Check the thing
# that is actually going to be verified, not the exit status of the command.
[ -s "$LOCAL_FILE" ] || die "$LOCAL_FILE is empty after the download"
DOWNLOAD_END="$(now)"
echo "    $((DOWNLOAD_END - DOWNLOAD_START))s, $(stat -c %s "$LOCAL_FILE" 2>/dev/null || echo 0) bytes"

# ---------------------------------------------------------------------------
# 3. Integrity: the snapshot's own checksum, from etcdctl
# ---------------------------------------------------------------------------
cyan "== integrity: etcdctl snapshot status =="
STATUS_START="$(now)"
if ! STATUS="$("$ETCDCTL" snapshot status "$LOCAL_FILE" -w json 2>&1)"; then
  printf '    %s\n' "$STATUS"
  die "etcdctl could not read the snapshot. A snapshot that downloads but does not parse is the classic truncated-upload failure, and it means the timer's post-condition was never run."
fi
STATUS_END="$(now)"
printf '    %s\n' "$STATUS" | sed 's/^/    /'
HASH="$(printf '%s' "$STATUS" | jq -r '.hash // empty')"
REVISION="$(printf '%s' "$STATUS" | jq -r '.revision // empty')"
TOTAL_KEY="$(printf '%s' "$STATUS" | jq -r '.totalKey // empty')"
echo "    hash=$HASH revision=$REVISION keys=$TOTAL_KEY  ($((STATUS_END - STATUS_START))s)"

# A snapshot with zero keys is a snapshot of an empty cluster. Not fatal -- the
# timer would legitimately produce one in the first minutes after a fresh install
# -- but it is not a backup of anything, so it is named.
if [ "$TOTAL_KEY" = "0" ]; then
  echo "    WARN the snapshot holds 0 keys: it is an empty cluster, and restoring it proves nothing"
fi

# ---------------------------------------------------------------------------
# 4. Restore into scratch
# ---------------------------------------------------------------------------
cyan "== restore into $SCRATCH_DIR/restored-data =="
RESTORE_DIR="$SCRATCH_DIR/restored-data"
case "$RESTORE_DIR/" in
  "$K3S_DATA_DIR"*) die "internal error: the restore target is under $K3S_DATA_DIR" ;;
esac

RESTORE_START="$(now)"
if [ "$TARGET" = "scratch" ]; then
  # `--name` must match the member name the snapshot was taken with, otherwise
  # the restored data directory does not have a member directory. It is derived
  # from the snapshot's filename, which k3s builds as
  # <snapshot-name>-<node-name>-<timestamp>.
  MEMBER_NAME="$SNAPSHOT_NAME"
  "$ETCDCTL" snapshot restore "$LOCAL_FILE" \
    --data-dir="$RESTORE_DIR" --name="$MEMBER_NAME" \
    --skip-hash-check=false 2>&1 | sed 's/^/    /' \
    || die "etcdctl snapshot restore failed"
else
  red "    TARGET=cluster-live: this is the real, destructive path."
  cat <<EOF
    Before continuing, confirm on the leader node, over SSM:
      * systemctl stop k3s                # on ALL THREE servers
      * k3s etcd-snapshot save            # one more snapshot before touching anything
      * k3s server --cluster-reset \\
          --cluster-reset-restore-path=$LOCAL_FILE     # on the leader only
      * rm -rf \${data-dir}/server/db/    # on the other two, then start k3s
    See docs/runbooks/ for the full sequence; a half-done restore leaves a
    single-member cluster with the other two separated.
EOF
  read -r -p "    Type 'yes' to proceed: " ANSWER
  [ "$ANSWER" = "yes" ] || die "aborted, nothing was changed"
  "$ETCDCTL" snapshot restore "$LOCAL_FILE" --data-dir="$RESTORE_DIR" --name="$MEMBER_NAME" \
    || die "restore failed"
fi
RESTORE_END="$(now)"

if [ -d "$RESTORE_DIR/member/snap" ] || [ -d "$RESTORE_DIR/member/wal" ]; then
  green "    restored data directory looks complete: $(find "$RESTORE_DIR" -type f | wc -l) files, $(du -sh "$RESTORE_DIR" 2>/dev/null | cut -f1)"
else
  die "the restore completed but $RESTORE_DIR has no member/snap: the restored data directory is not usable"
fi

# ---------------------------------------------------------------------------
# 5. Verdict
# ---------------------------------------------------------------------------
TOTAL_END="$(now)"
cyan "== verdict =="
printf '    %-22s %ss\n' "download" "$((DOWNLOAD_END - DOWNLOAD_START))"
printf '    %-22s %ss\n' "integrity" "$((STATUS_END - STATUS_START))"
printf '    %-22s %ss\n' "restore" "$((RESTORE_END - RESTORE_START))"
printf '    %-22s %ss\n' "TOTAL" "$((TOTAL_END - TOTAL_START))"
echo "    scratch dir: $SCRATCH_DIR"

if [ "$KEEP" = "yes" ]; then
  echo "    (KEEP=yes: left in place)"
else
  rm -rf "$SCRATCH_DIR"
  echo "    (scratch dir removed; set KEEP=yes to inspect it)"
fi

green "VERDICT: PASS -- $SNAPSHOT_NAME (revision $REVISION, $TOTAL_KEY keys) downloaded, verified and restored into scratch in $((TOTAL_END - TOTAL_START))s"
echo "         This proves the snapshot is loadable. It does NOT prove a full cluster"
echo "         restore: that is the TARGET=cluster-live path and it needs a window."
exit 0
