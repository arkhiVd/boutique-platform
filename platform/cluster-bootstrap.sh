#!/bin/bash
# ===========================================================================
# boutique-platform -- k3s node bootstrap, Phase 3.
#
# HOW THIS FILE REACHES THE INSTANCE
#   platform/nodes.tf injects it as the launch template's user_data, base64
#   encoded, with the two marker lines below replaced by a per-role config block
#   and by the rendered etcd-snapshot script. Cloud-init on Amazon Linux 2023
#   classifies user data that does not begin with `#cloud-config` as
#   text/x-shellscript and runs it once, as root, on first boot. Its output
#   lands in /var/log/cloud-init-output.log and, because this script redirects
#   its own, in /var/log/boutique-bootstrap.log -- which is the file
#   scripts/doctor.sh reads back over SSM.
#
# WHY NO SECRET IS IN THIS FILE OR IN ANY RENDERED COPY OF IT
#   The k3s join token is fetched from SSM at boot using the instance role's own
#   IMDS credentials. It is never placed in user_data, never echoed to a log,
#   never written anywhere except /etc/systemd/system/k3s.service.env (which the
#   k3s installer itself creates with mode 0600), and never reaches the
#   Terraform state or git. See step 3 and platform/nodes.tf.
#
# WHAT IS DELIBERATELY ABSENT
#   * no `key_name`, no sshd rule, no authorized_keys: SSM Session Manager is the
#     only path in (SPEC trust boundary 3).
#   * no control-plane taint. k3s labels its server nodes
#     node-role.kubernetes.io/control-plane=true but taints nothing, and the
#     SPEC's scheduling model requires all four nodes to be schedulable.
#   * no `WatchdogSec` in the systemd unit: see step 6.
#   * no `--node-label` under kubernetes.io/: KEP-279 forbids a node from
#     asserting its own role labels into that prefix, so only boutique.io/* is
#     used.
#   * no `ec2:Describe*` call. k3s ships no in-tree AWS cloud provider, so the
#     cluster needs none and the node role stays narrow.
# ===========================================================================
set -euo pipefail

readonly BOOTSTRAP_LOG=/var/log/boutique-bootstrap.log
mkdir -p /var/log
mkdir -p "$(dirname "$BOOTSTRAP_LOG")"
exec >>"$BOOTSTRAP_LOG" 2>&1

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s FATAL %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; exit 1; }

# --- BEGIN BOOTSTRAP CONFIG (rendered by platform/nodes.tf) -----------------
# The config is written to a file and sourced, rather than being inlined here,
# for one reason: platform/etcd-snapshot.sh runs from a systemd timer long after
# this script has exited and needs the same values. It reads them from
# /etc/boutique/bootstrap.conf instead of repeating them.
mkdir -p /etc/boutique
cat >/etc/boutique/bootstrap.conf <<'BOUTIQUE_CONF'
BOUTIQUE_BOOTSTRAP_CONF
BOUTIQUE_CONF
chmod 0644 /etc/boutique/bootstrap.conf
# shellcheck source=/dev/null
. /etc/boutique/bootstrap.conf
# --- END BOOTSTRAP CONFIG ---------------------------------------------------

log "=== boutique k3s node bootstrap starting ==="
log "config: K3S_VERSION=$K3S_VERSION NODE_ROLE=$K3S_NODE_ROLE LEADER_AZ=$K3S_LEADER_AZ"
log "config: EXTRA_FLAGS=$K3S_EXTRA_FLAGS"
log "config: TOKEN_PARAM=$K3S_TOKEN_PARAMETER LEADER_IP_PARAM=$K3S_LEADER_IP_PARAMETER"
log "config: SNAPSHOT_BUCKET=$K3S_SNAPSHOT_BUCKET FOLDER=$K3S_SNAPSHOT_FOLDER REGION=$AWS_REGION"
log "config: SSM_WAIT=${K3S_SSM_WAIT_SECONDS}s API_WAIT=${K3S_API_WAIT_SECONDS}s"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v aws         >/dev/null 2>&1 || die "aws cli not found; Amazon Linux 2023 ships it"
command -v curl        >/dev/null 2>&1 || die "curl not found"
command -v systemctl   >/dev/null 2>&1 || die "systemctl not found"
command -v hostnamectl >/dev/null 2>&1 || die "hostnamectl not found"

# IMDSv2 only. The launch template sets http_tokens = "required", so a
# token-less v1 request is already refused by the hypervisor; this is the same
# constraint, not a convention layered on top of it.
imds() {
  local path="/latest/meta-data/$1" token
  token="$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
             -H "X-aws-ec2-metadata-token-ttl-seconds: 60")" \
    || die "could not mint an IMDSv2 session token"
  curl -sf -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254${path}"
}

INSTANCE_ID="$(imds instance-id)"
PRIVATE_IP="$(imds local-ipv4)"
MY_AZ="$(imds placement/availability-zone)"
log "instance=$INSTANCE_ID private_ip=$PRIVATE_IP az=$MY_AZ"

# ---------------------------------------------------------------------------
# 2. Am I the leader?
#
# The SPEC pins one server per AZ, so the AZ is the only identity a node can
# establish for itself without a second IAM grant. Designated leader = the
# server living in K3S_LEADER_AZ; that node bootstraps the cluster and every
# other node joins it.
#
# The property that makes this survive a replacement: an instance's AZ does not
# change when it is replaced, because the subnet is per-AZ. A replaced leader is
# therefore discovered as the leader by its replacement, and
# K3S_LEADER_IP_PARAMETER follows the new address on its own.
#
# What is NOT used: `aws ec2 describe-instances` to locate the leader. That
# needs an ec2:Describe* grant the SPEC's least-privilege line does not want, for
# a cluster that has no cloud controller manager to use it.
# ---------------------------------------------------------------------------
if [ "$K3S_NODE_ROLE" = "server" ] && [ "$MY_AZ" = "$K3S_LEADER_AZ" ]; then
  IS_LEADER=1
  ROLE=leader
else
  IS_LEADER=0
  if [ "$K3S_NODE_ROLE" = "worker" ]; then ROLE=agent; else ROLE=follower; fi
fi
log "role=$ROLE is_leader=$IS_LEADER"

# ---------------------------------------------------------------------------
# 3. Read the SSM parameters
#
# K3S_TOKEN_PARAMETER holds the join token as a SecureString encrypted under
# this stack's own CMK. Terraform creates it from a write-only attribute fed by
# an ephemeral variable, so the token is not in the plan, not in the state, and
# not in git; the node reads it with the instance role, which is the only place
# it needs to exist in cleartext.
#
# K3S_LEADER_IP_PARAMETER is a plain String Terraform writes from the leader
# instance's private address. Followers read it rather than baking a join URL
# into their own user_data, so a replaced leader does not invalidate the
# followers' configuration: the parameter follows the new address.
# ---------------------------------------------------------------------------
# imds_public_ipv4: this instance's public address, via IMDSv2.
#
# Returns non-zero and prints nothing if IMDS is unreachable or the instance has
# no public IPv4, so callers can treat an empty string as "no public SAN" rather
# than failing the boot over a nicety.
imds_public_ipv4() {
  local token ip
  token="$(curl -sf --connect-timeout 3 --max-time 5 \
            -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null)" \
    || return 1
  ip="$(curl -sf --connect-timeout 3 --max-time 5 \
          -H "X-aws-ec2-metadata-token: $token" \
          "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null)" \
    || return 1
  printf '%s' "$ip"
}

# The progress line inside this function goes to STDERR, deliberately. Both
# call sites capture the function with `$(...)`: if the waiting message were on
# stdout it would be concatenated onto the value and the caller would use a
# string like `2026-10-14T05:19:33Z waiting for parameter ...` as if it were
# the answer. Measured 2026-10-14: both followers built
# `--server https://2026-10-14T05:19:33Z` from exactly that, and k3s failed
# with `failed to validate token: Invalid server url` at 483 restarts. A
# function whose stdout is captured must print only the value on stdout.

ssm_wait() {
  local name="$1" deadline="$2" waited=0 value
  until value="$(aws ssm get-parameter --region "$AWS_REGION" --name "$name" \
                 --query 'Parameter.Value' --output text 2>/dev/null)" && [ -n "$value" ]; do
    if [ "$waited" -ge "$deadline" ]; then
      return 1
    fi
    log "waiting for parameter $name (${waited}s of ${deadline}s elapsed)" >&2
    sleep 10
    waited=$((waited + 10))
  done
  printf '%s' "$value"
}

# leader_wait: the leader's address, and only an address that answers.
#
# ssm_wait returns as soon as a value is READABLE, which is the wrong test on a
# replace: the parameter still holds the PREVIOUS leader's address until
# Terraform rewrites it, and the two followers boot in parallel with the leader
# they are about to join. Measured 2026-10-14 -- both followers read
# 10.90.12.149 (the leader from the generation before) and died with
# `Get "https://10.90.12.149:6443/cacerts": context deadline exceeded` while
# the live leader was already at 10.90.0.50. A readable stale value is worse
# than an absent one: an absent value keeps polling, a stale one stops it.
#
# So this re-reads the parameter on every attempt and accepts the value only
# once https://<ip>:6443/cacerts answers. That covers both cases -- a stale
# address is rejected and re-read (catching Terraform's write a few seconds
# later), and a correct address whose apiserver has not started yet is waited
# on rather than handed to k3s. -k because the serving cert is the cluster's
# self-signed one and is not in this host's CA bundle at this point.
leader_wait() {
  local name="$1" deadline="$2" waited=0 ip
  while :; do
    ip="$(ssm_wait "$name" "$deadline")" \
      || { log "SSM parameter $name never became readable" >&2; return 1; }
    if curl -sk --connect-timeout 5 --max-time 8 \
         "https://${ip}:6443/cacerts" -o /dev/null; then
      printf '%s' "$ip"
      return 0
    fi
    if [ "$waited" -ge "$deadline" ]; then
      log "no leader answered /cacerts within ${deadline}s (last value: $ip)" >&2
      return 1
    fi
    log "leader not answering at ${ip}:6443 (${waited}s of ${deadline}s elapsed); re-reading $name" >&2
    sleep 10
    waited=$((waited + 10))
  done
}

log "reading $K3S_TOKEN_PARAMETER (SecureString, with-decryption)"
K3S_TOKEN="$(ssm_wait "$K3S_TOKEN_PARAMETER" "$K3S_SSM_WAIT_SECONDS")" \
  || die "SSM parameter $K3S_TOKEN_PARAMETER did not become readable within ${K3S_SSM_WAIT_SECONDS}s. The platform/ Terraform stack creates it, and the node role grants GetParameter on exactly this ARN."
[ -n "$K3S_TOKEN" ] || die "empty k3s token returned from $K3S_TOKEN_PARAMETER"

K3S_JOIN_URL=""
if [ "$IS_LEADER" -eq 0 ]; then
  LEADER_IP="$(leader_wait "$K3S_LEADER_IP_PARAMETER" "$K3S_SSM_WAIT_SECONDS")" \
    || die "No leader became reachable at $K3S_LEADER_IP_PARAMETER within ${K3S_SSM_WAIT_SECONDS}s. The parameter must eventually hold the new leader's address and that leader must answer /cacerts."
  log "leader private address = $LEADER_IP"
  K3S_JOIN_URL="https://${LEADER_IP}:6443"
fi

# ---------------------------------------------------------------------------
# 4. Node identity
#
# `--node-name` is what kubelet registers with and is what is passed below, so
# the node name does not depend on hostnamectl having taken effect before kubelet
# starts. The hostname is set anyway, for the humans who land in an SSM session.
# ---------------------------------------------------------------------------
NODE_NAME="boutique-${ROLE}-${INSTANCE_ID}"
hostnamectl set-hostname "$NODE_NAME" 2>/dev/null \
  || log "WARN hostnamectl failed; the AMI default hostname is kept"
log "node name = $NODE_NAME"

# ---------------------------------------------------------------------------
# 5. Install k3s
#
# INSTALL_K3S_VERSION pins the exact build. `curl -s
# https://update.k3s.io/v1-release/channels/stable` resolves to that string; the
# channel is not used to select the version, because a node rejoining later would
# then pull whatever the channel pointed at that day.
#
# `--disable traefik` and `--disable servicelb`: Traefik is installed by this
# repo in Phase 5 through a Helm chart, which is the only way to get real host
# routes, the p99 histogram buckets the latency SLO needs, and a Service that
# matches the Phase 5 ALB target group. klipper-lb is disabled because NLB
# capacity in this account is 0, so a Service of type LoadBalancer is never going
# to be satisfied. coredns, local-storage and metrics-server stay enabled: every
# HPA in apps/boutique/ is CPU-utilisation based and has no second source of
# metrics.
#
# Residual risk, recorded rather than hidden: the installer script is fetched
# over TLS from get.k3s.io and is NOT digest-pinned. The artifact it installs is
# pinned by version; the script itself is whatever that URL serves that day.
# ---------------------------------------------------------------------------
# topology.kubernetes.io/zone is set here rather than left to a cloud provider.
# k3s stamps every node with providerID `k3s://<hostname>`, so no AWS controller
# ever resolves it to an availability zone and the standard label is simply
# absent -- measured 2026-10-14: `kubectl get nodes -L topology.kubernetes.io/zone`
# returned `<no-zone-label>` on all four. Every topologySpreadConstraints in
# apps/boutique/base uses `topologyKey: topology.kubernetes.io/zone`, so without
# it the AZ spread is a no-op and scripts/doctor.sh fails its spread check.
# MY_AZ comes from IMDS placement/availability-zone, which is the same value the
# scheduler would have derived.
NODE_FLAGS="--node-name ${NODE_NAME} --node-label boutique.io/role=${ROLE} --node-label boutique.io/az=${MY_AZ} --node-label topology.kubernetes.io/zone=${MY_AZ} ${K3S_EXTRA_FLAGS}"
JOIN_FLAG=""
[ -n "$K3S_JOIN_URL" ] && JOIN_FLAG="--server ${K3S_JOIN_URL}"

# `--cluster-init` on the designated leader and on nobody else. Without it k3s
# falls back to kine (a SQLite file local to that one node), which is neither
# HA nor etcd: the second server then refuses to join with
# `failed to bootstrap cluster data: etcd disabled`, the SPEC's "three servers
# form an etcd quorum" acceptance criterion is unmeetable, and
# boutique-etcd-snapshot.sh snapshots a datastore that is not etcd.
# Measured 2026-10-14 on the first boot: /var/lib/rancher/k3s/server held
# kine.sock and db/state.db with no db/etcd directory at all.
#
# Exactly one node may pass it. The other two join through the leader with the
# token and become etcd members on their own; passing --cluster-init on a node
# that is joining would ask it to start a second, separate cluster.
CLUSTER_INIT_FLAG=""
if [ "$K3S_NODE_ROLE" = "server" ] && [ "$IS_LEADER" -eq 1 ]; then
  CLUSTER_INIT_FLAG="--cluster-init"
fi
[ -n "$CLUSTER_INIT_FLAG" ] && log "this node bootstraps embedded etcd: $CLUSTER_INIT_FLAG"

# `--tls-san` for the instance's PUBLIC address, read from IMDSv2 at boot.
#
# k3s puts only 10.43.0.1, the node IPs, 127.0.0.1 and ::1 into the apiserver
# certificate. The operator reaches that apiserver on port 6443 through the
# instance's public address (boutique-node-api opens 6443/tcp to var.admin_cidr
# and nothing else, and there is no NAT/VPC route from the workstation), so
# without this SAN every remote kubectl fails with:
#   x509: certificate is valid for 10.43.0.1, 10.90.x.x, 127.0.0.1, ::1,
#         not 100.61.37.125
# -- measured 2026-10-14 on the first boot of this cluster.
#
# Read here rather than set from Terraform because the address is only assigned
# at RunInstances time and is not in the plan. IMDSv2 only: the PUT token hop is
# one hop, and http_put_response_hop_limit=1 in the launch template means this
# shell can reach 169.254.169.254 and a pod on the node cannot.
TLS_SAN_FLAG=""
if [ "$K3S_NODE_ROLE" = "server" ]; then
  PUBLIC_IP="$(imds_public_ipv4 || true)"
  if [ -n "$PUBLIC_IP" ]; then
    TLS_SAN_FLAG="--tls-san ${PUBLIC_IP}"
    log "apiserver public SAN = $PUBLIC_IP"
  else
    log "WARN no public IPv4 in IMDS; remote kubectl will fail TLS verification against this node"
  fi
fi

if [ "$K3S_NODE_ROLE" = "server" ]; then
  K3S_EXEC_COMMAND="server ${NODE_FLAGS} ${CLUSTER_INIT_FLAG} ${TLS_SAN_FLAG} ${JOIN_FLAG}"
  K3S_UNIT=k3s.service
  K3S_ENV_FILE=/etc/systemd/system/k3s.service.env
else
  K3S_EXEC_COMMAND="agent ${NODE_FLAGS} ${JOIN_FLAG}"
  K3S_UNIT=k3s-agent.service
  K3S_ENV_FILE=/etc/systemd/system/k3s-agent.service.env
fi
log "installing: k3s ${K3S_EXEC_COMMAND}"

curl -sfL https://get.k3s.io -o /var/tmp/k3s-install.sh \
  || die "could not download the k3s install script"

# K3S_TOKEN is exported so the installer persists it into the systemd environment
# file. That file is the one place on the node holding the join token in
# cleartext, and the installer creates it 0600; the chmod below re-asserts it,
# because `ls -l` is how a reviewer confirms nobody widened it afterwards.
INSTALL_K3S_VERSION="$K3S_VERSION" \
INSTALL_K3S_EXEC="$K3S_EXEC_COMMAND" \
K3S_TOKEN="$K3S_TOKEN" \
K3S_NODE_NAME="$NODE_NAME" \
  bash /var/tmp/k3s-install.sh \
  || die "the k3s install script exited non-zero; see the log above"
rm -f /var/tmp/k3s-install.sh

chmod 0600 "$K3S_ENV_FILE" || log "WARN could not chmod $K3S_ENV_FILE"

# ---------------------------------------------------------------------------
# 6. Systemd hardening drop-in
#
# SET: CPU/Memory/IO/TasksAccounting -- the safe half of the watchdog question,
# and what makes the t3 credit risk measurable after the fact.
# `systemctl show k3s -p CPUUsageNSec` is the number that says whether the
# cluster is quietly burning CPU credits, which is the SPEC's U2: requests are an
# admission guarantee, not a performance one, and a t3 sustains 20% of a vCPU, not
# 100%.
#
# NOT SET, on purpose: WatchdogSec. k3s removes NOTIFY_SOCKET from its own
# environment immediately after sending READY=1, so the kubelet's systemd
# watchdog goroutine (enabled upstream since Kubernetes 1.35) cannot feed the
# watchdog at all and logs `failed to notify systemd watchdog, notification not
# supported`. With WatchdogSec set, systemd kills the k3s service once the
# timeout elapses -- a self-inflicted outage on every node. The report is
# k3s-io/k3s#13725 and the maintainers declined to change it ("K3s is not just
# the kubelet"). Liveness therefore stays Restart=always plus scripts/doctor.sh.
# ---------------------------------------------------------------------------
DROPIN_DIR="/etc/systemd/system/${K3S_UNIT}.d"
mkdir -p "$DROPIN_DIR"
cat >"${DROPIN_DIR}/10-boutique-hardening.conf" <<'DROPIN'
# boutique-platform -- Phase 3 node hardening. Accounting only.
# WatchdogSec is absent deliberately: with it set, systemd kills k3s because the
# kubelet cannot feed a watchdog socket that k3s has already unset
# (k3s-io/k3s#13725).
[Service]
CPUAccounting=yes
MemoryAccounting=yes
IOAccounting=yes
TasksAccounting=yes
DROPIN
systemctl daemon-reload

# ---------------------------------------------------------------------------
# 7. Wait for this node to matter
#
# The leader's wait is strict: a failed apply is the right outcome if the API
# never comes up, rather than a green apply that the operator discovers is wrong
# from kubectl. The other nodes' wait is advisory -- k3s's own unit retries the
# join, and a follower that is Ready four minutes later is a working cluster, not
# a failed one.
# ---------------------------------------------------------------------------
api_ready() { k3s kubectl get --raw=/healthz >/dev/null 2>&1; }

waited=0
until api_ready; do
  if [ "$waited" -ge "$K3S_API_WAIT_SECONDS" ]; then
    if [ "$IS_LEADER" -eq 1 ]; then
      log "unit state: $(systemctl is-active "$K3S_UNIT" || true)"
      log "last 40 journal lines of ${K3S_UNIT}:"
      journalctl -u "$K3S_UNIT" -n 40 --no-pager || true
      die "the apiserver was not healthy after ${K3S_API_WAIT_SECONDS}s"
    fi
    log "WARN k3s not reportable healthy after ${waited}s; the systemd unit keeps retrying"
    break
  fi
  sleep 10
  waited=$((waited + 10))
done
log "kube-apiserver reachable after ~${waited}s"

if [ "$K3S_NODE_ROLE" = "server" ]; then
  # Asserted, not assumed: the SPEC's scheduling model rests on a server node
  # being schedulable, and this is the cheapest place to prove it on every boot.
  log "taints on this node: $(k3s kubectl get node "$NODE_NAME" \
      -o jsonpath='{.spec.taints}' 2>/dev/null || echo '<node not registered yet>')"
fi

# ---------------------------------------------------------------------------
# 8. etcd snapshots to S3 -- leader only
#
# ONE node uploads. k3s's S3 retention is cluster-wide, so three nodes on the
# same schedule would fill the bucket with three copies of identical state.
#
# The credentials are the instance role, not a key pair: see the header of
# platform/etcd-snapshot.sh for the chain k3s builds and where the grant lives.
# ---------------------------------------------------------------------------
if [ "$IS_LEADER" -eq 1 ]; then
  cat >/usr/local/bin/boutique-etcd-snapshot.sh <<'SNAPSCRIPT'
BOUTIQUE_ETCD_SNAPSHOT_SCRIPT
SNAPSCRIPT
  chmod 0700 /usr/local/bin/boutique-etcd-snapshot.sh

  cat >/etc/systemd/system/boutique-etcd-snapshot.service <<'UNIT'
[Unit]
Description=boutique-platform etcd snapshot to S3
Documentation=file:///usr/local/bin/boutique-etcd-snapshot.sh
After=k3s.service
Requires=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/boutique-etcd-snapshot.sh
# A compressed snapshot for this cluster is a few MB, but the S3 upload from a
# burstable t3.small can be slow, so this is not a tight timeout.
TimeoutStartSec=600
UNIT

  cat >/etc/systemd/system/boutique-etcd-snapshot.timer <<'UNIT'
[Unit]
Description=boutique-platform etcd snapshot to S3, every six hours

[Timer]
# 00:00, 06:00, 12:00, 18:00 UTC. Aligned to the four six-hour boundaries so
# consecutive snapshots are always six hours apart instead of drifting by the
# run duration.
OnCalendar=*-*-* 00/6:00:00
# A snapshot missed because the leader was stopped or being replaced is taken on
# the next boot rather than silently skipped.
Persistent=true
# Spread the start so a cluster that has just come up does not immediately
# snapshot a cold etcd.
RandomizedDelaySec=300
Unit=boutique-etcd-snapshot.service

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now boutique-etcd-snapshot.timer
  log "etcd snapshot timer: $(systemctl is-enabled boutique-etcd-snapshot.timer 2>&1) / $(systemctl is-active boutique-etcd-snapshot.timer 2>&1)"
fi

# ---------------------------------------------------------------------------
# 9. Completion marker
#
# Not a guard -- a second cloud-init run is a no-op for k3s, which is idempotent
# by design. The marker is what scripts/bootstrap-cluster.sh and
# scripts/doctor.sh read back, so the operator sees in one line that this node
# finished bootstrap rather than merely booted.
# ---------------------------------------------------------------------------
cat >/var/lib/boutique-bootstrap-complete <<MARKER
instance_id=$INSTANCE_ID
node_name=$NODE_NAME
role=$ROLE
az=$MY_AZ
k3s_version=$K3S_VERSION
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER
chmod 0644 /var/lib/boutique-bootstrap-complete

log "=== boutique k3s node bootstrap complete: $NODE_NAME ($ROLE) ==="

# Unset so nothing later in this process tree can print it by accident.
unset K3S_TOKEN
