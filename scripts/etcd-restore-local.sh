#!/usr/bin/env bash
# ===========================================================================
# etcd-restore-local.sh -- restore the real etcd snapshot into a throwaway k3s
# and prove the restored cluster serves the shop. Timed, end to end.
#
# WHY THIS EXISTS NEXT TO etcd-restore-drill.sh
#   etcd-restore-drill.sh proves a snapshot is intact and loads into etcd. Its
#   own header lists what that does NOT prove: that k3s accepts the snapshot,
#   that the join token still decrypts the bootstrap data inside it, and that
#   the workloads come back. This script proves exactly those three things.
#
# WHY IT RUNS ON A WORKSTATION, NOT ON A SPARE EC2 NODE
#   The account's on-demand vCPU quota is 8 and the cluster uses all 8, so there
#   is no room for a scratch instance (measured 2026-10-17, quota L-1216C47A).
#   A k3s container on the workstation is the same binary, has no network path
#   to the live cluster, and costs nothing. ROADMAP Phase 13: "the DR drill must
#   not run against the live cluster's etcd" -- this one cannot reach it.
#
# WHAT IT DOES
#   1. downloads the newest snapshot from the etcd snapshot bucket
#   2. reads the cluster token from SSM into a 0600 file (never printed)
#   3. `k3s server --cluster-reset --cluster-reset-restore-path` in a container
#   4. starts k3s on the restored data, tainted so nothing schedules yet
#   5. removes what must not run off-cluster (Jenkins, the observability stack
#      that would publish alerts, the edge) and the four dead node objects
#   6. untaints, waits for every boutique Deployment, and fetches the home page
#      and a product page through the restored frontend
#   7. tears everything down, including the token file, on any exit
#
# Requires: aws (with read on the bucket and the token parameter), docker, curl.
# ===========================================================================
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
BUCKET="${BOUTIQUE_ETCD_SNAPSHOT_BUCKET:-boutique-platform-etcd-snapshots-$(aws sts get-caller-identity --query Account --output text)}"
PREFIX="${BOUTIQUE_ETCD_SNAPSHOT_PREFIX:-etcd-snapshots/}"
TOKEN_PARAM="${BOUTIQUE_K3S_TOKEN_PARAM:-/boutique-platform/k3s/token}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.36.5-k3s1}"
NAME=boutique-restore-drill
PORT="${PORT:-18080}"
KEEP="${KEEP:-no}"

cyan() { printf '\033[1;36m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
die() { red "FATAL $*"; exit 1; }
now() { date -u +%s; }
k() { docker exec "$NAME" kubectl "$@"; }

for t in aws docker curl; do command -v "$t" >/dev/null || die "$t not found"; done

WORK="$(mktemp -d)"
chmod 0700 "$WORK"
cleanup() {
  if [ "$KEEP" != yes ]; then
    docker rm -f "$NAME" >/dev/null 2>&1
    docker volume rm "$NAME" >/dev/null 2>&1
  fi
  # The token is the only secret this script touches. It never leaves $WORK.
  [ -f "$WORK/token.env" ] && shred -u "$WORK/token.env" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

declare -A T
T[start]=$(now)

cyan "== 1. newest snapshot in s3://$BUCKET/$PREFIX"
KEY="$(aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix "$PREFIX" \
  --query 'sort_by(Contents,&LastModified)[-1].[Key,LastModified,Size]' --output text)" \
  || die "cannot list the snapshot bucket"
read -r SNAP_KEY SNAP_TIME SNAP_SIZE <<<"$KEY"
if [ -z "$SNAP_KEY" ] || [ "$SNAP_KEY" = None ]; then die "no snapshot under $PREFIX"; fi
echo "    $SNAP_KEY  ($SNAP_SIZE bytes, written $SNAP_TIME)"
# Its own directory, mounted read-write: k3s decompresses the .zip NEXT TO
# it ("open /drill/<name>: read-only file system" otherwise). The token file
# stays outside this mount, so the container never sees it as a file.
mkdir -p "$WORK/snap"
aws s3 cp --only-show-errors --region "$REGION" "s3://$BUCKET/$SNAP_KEY" "$WORK/snap/$(basename "$SNAP_KEY")" \
  || die "download failed"
SNAP_FILE="$(basename "$SNAP_KEY")"
T[downloaded]=$(now)

cyan "== 2. cluster token from SSM $TOKEN_PARAM (written 0600, never shown)"
# K3S_TOKEN through --env-file, not --token on a command line (visible in ps
# and shell history) and not --token-file: a restore rejects the file form with
# "server/token does not exist, please pass --token" (k3s v1.36.5, measured
# 2026-10-17). The file is 0600, read by the docker client, shredded on exit.
( umask 077
  printf 'K3S_TOKEN=%s\n' "$(aws ssm get-parameter --region "$REGION" --name "$TOKEN_PARAM" \
    --with-decryption --query Parameter.Value --output text)" >"$WORK/token.env" ) \
  || die "cannot read the token parameter"
[ "$(wc -c <"$WORK/token.env")" -gt 12 ] || die "token parameter is empty"
echo "    ok"

docker rm -f "$NAME" >/dev/null 2>&1
docker volume rm "$NAME" >/dev/null 2>&1
docker volume create "$NAME" >/dev/null

COMMON=(--privileged --tmpfs /run --tmpfs /var/run --env-file "$WORK/token.env"
  -v "$NAME:/var/lib/rancher/k3s" -v "$WORK/snap:/drill")
# The same two disables the real servers run with (platform/nodes.tf).
SERVER_FLAGS=(--disable traefik --disable servicelb)

cyan "== 3. k3s --cluster-reset from the snapshot"
# Success is the exit status: k3s exits 0 once the restored member has been
# reset to a single-voter cluster, and non-zero (level=fatal) on a bad
# snapshot, a wrong token or a version mismatch.
docker run --rm --name "$NAME-reset" "${COMMON[@]}" "$K3S_IMAGE" server "${SERVER_FLAGS[@]}" \
  --cluster-reset --cluster-reset-restore-path "/drill/$SNAP_FILE" >"$WORK/reset.log" 2>&1
RESET_RC=$?
grep -iE 'level=(fatal|error)|restor|cluster-reset|membership' "$WORK/reset.log" \
  | grep -oE 'msg="[^"]{0,160}' | sed 's/^msg="/    k3s: /' | tail -6
[ "$RESET_RC" -eq 0 ] || { tail -20 "$WORK/reset.log"; die "cluster-reset exited $RESET_RC"; }
T[reset]=$(now)

cyan "== 4. k3s on the restored data (tainted: nothing schedules yet)"
docker run -d --name "$NAME" "${COMMON[@]}" -p "127.0.0.1:${PORT}:${PORT}" "$K3S_IMAGE" \
  server "${SERVER_FLAGS[@]}" --node-name restore-drill \
  --node-taint drill.boutique.io/restore=true:NoSchedule >/dev/null || die "k3s did not start"
for _ in $(seq 1 90); do k get --raw /readyz >/dev/null 2>&1 && break; sleep 2; done
k get --raw /readyz >/dev/null 2>&1 || { docker logs --tail 30 "$NAME"; die "apiserver never became ready"; }
T[api]=$(now)
echo "    apiserver ready; restored objects:"
for ns in boutique ci observability traefik; do
  printf '      %-14s deployments=%-3s statefulsets=%-3s services=%-3s configmaps=%s\n' "$ns" \
    "$(k -n "$ns" get deploy --no-headers 2>/dev/null | wc -l)" \
    "$(k -n "$ns" get sts --no-headers 2>/dev/null | wc -l)" \
    "$(k -n "$ns" get svc --no-headers 2>/dev/null | wc -l)" \
    "$(k -n "$ns" get cm --no-headers 2>/dev/null | wc -l)"
done
echo "    nodes in the snapshot: $(k get nodes --no-headers | awk '$1!="restore-drill"{print $1}' | tr '\n' ' ')"

cyan "== 5. remove what must not run off-cluster, and the dead nodes"
# Jenkins would run pipelines, Alertmanager would page, the edge has no ALB.
# The collector goes with observability: the frontend's trace export then
# fails quietly, which is the documented degraded mode (docs/runbooks/traces.md).
for ns in ci observability traefik; do k delete ns "$ns" --wait=false >/dev/null 2>&1; done
k -n boutique scale deploy loadgenerator --replicas=0 >/dev/null 2>&1
k get nodes --no-headers | awk '$1!="restore-drill"{print $1}' | xargs -r docker exec "$NAME" kubectl delete node >/dev/null
k taint node restore-drill drill.boutique.io/restore- >/dev/null
T[cleaned]=$(now)

cyan "== 6. every boutique pod Ready on the restored node"
# NOT `rollout status`: a restored Deployment still carries the status it had
# when the snapshot was taken (Available, observedGeneration current), so
# rollout status returns at once while the real pods are still being created.
# Measured on the first run of this drill: "11 deployments available" with
# every pod in ContainerCreating. Readiness of the pods themselves, on the one
# node that exists, is the only honest signal.
WANT="$(k -n boutique get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}' \
  | awk -F= '$1!="loadgenerator"{s+=$2} END{print s}')"
for _ in $(seq 1 180); do
  READY="$(k -n boutique get pods -o jsonpath='{range .items[*]}{.spec.nodeName} {.status.conditions[?(@.type=="Ready")].status} {.metadata.deletionTimestamp}{"\n"}{end}' \
    | awk '$1=="restore-drill" && $2=="True" && NF==2' | wc -l)"
  [ "$READY" -ge "$WANT" ] && break
  sleep 5
done
[ "$READY" -ge "$WANT" ] || { k -n boutique get pods -o wide; die "only $READY of $WANT boutique pods became Ready"; }
echo "    $READY of $WANT boutique pods Ready on restore-drill"
T[app]=$(now)

cyan "== 7. the shop answers through the restored frontend"
docker exec -d "$NAME" kubectl -n boutique port-forward --address 0.0.0.0 svc/frontend "${PORT}:80"
for _ in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:${PORT}/" && break; sleep 2; done
HOME_CODE="$(curl -s -o "$WORK/home.html" -w '%{http_code}' "http://127.0.0.1:${PORT}/")"
PRODUCT="$(grep -oE '/product/[A-Z0-9]+' "$WORK/home.html" | head -1)"
PROD_CODE="$(curl -s -o "$WORK/product.html" -w '%{http_code}' "http://127.0.0.1:${PORT}${PRODUCT:-/product/OLJCESPC7Z}")"
echo "    GET /            -> $HOME_CODE  ($(grep -c 'product-card' "$WORK/home.html") product cards)"
echo "    GET ${PRODUCT:-/product/OLJCESPC7Z} -> $PROD_CODE"
T[served]=$(now)
if [ "$HOME_CODE" != 200 ] || [ "$PROD_CODE" != 200 ] || ! grep -q 'product-card' "$WORK/home.html"; then
  die "the restored shop did not serve"
fi

cyan "== timings (seconds)"
printf '    download snapshot     %4s\n' $((T[downloaded] - T[start]))
printf '    cluster-reset         %4s\n' $((T[reset] - T[downloaded]))
printf '    apiserver ready       %4s\n' $((T[api] - T[reset]))
printf '    off-cluster cleanup   %4s\n' $((T[cleaned] - T[api]))
printf '    boutique available    %4s\n' $((T[app] - T[cleaned]))
printf '    shop serving          %4s\n' $((T[served] - T[app]))
printf '    TOTAL (RTO measured)  %4s\n' $((T[served] - T[start]))
green "PASS: snapshot $SNAP_KEY restored and served the shop in $((T[served] - T[start]))s"
