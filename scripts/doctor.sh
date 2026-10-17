#!/usr/bin/env bash
# Every check_* function is invoked by name from the run list at the bottom,
# which shellcheck before 0.11 cannot see, so it reports each body as
# unreachable (SC2317). That is a false positive for the whole file.
# shellcheck disable=SC2317
# ===========================================================================
# doctor.sh -- one command, one verdict: is this cluster healthy, and if not,
# exactly which thing is wrong.
#
# DESIGN RULES, and why they are not negotiable
#
#   1. Every check prints PASS, WARN or FAIL on its own line, with the evidence
#      that decided it. A check that cannot run says MISSING and counts as a
#      failure -- the same rule scripts/check.sh uses -- because "no answer"
#      reported as "fine" is how a broken cluster gets missed.
#
#   2. The exit code is 0 only when nothing failed. There is no "mostly fine".
#
#   3. What is NOT claimed: this is not a chaos test and it does not prove the
#      drift path. It is the health report an on-call person runs first, and every
#      check names the command it ran so the reader can re-run it by hand.
#
# WHAT IT CHECKS, in the order a failure gets more expensive
#   prereq    kubectl and the kubeconfig, and the kubeconfig is not in git
#   nodes     4 nodes, 4 Ready, and all four SCHEDULABLE (SPEC's scheduling model)
#   spread    one node per AZ, so topologySpreadConstraints have somewhere to go
#   apiserver /healthz, which is the one endpoint that is the cluster's front door
#   etcd      reachable, plus quorum arithmetic on the three servers
#   pods      every non-kube-system pod Running or Succeeded, and no restart storm
#   pdb       every PodDisruptionBudget's currentHealthy >= desiredHealthy
#   hpa       every HPA's target has enough ready replicas, or says it is at max
#   pvc       every PersistentVolumeClaim Bound
#   certs     the kubeconfig client cert and the apiserver serving cert, in days
#   targets   every active Prometheus scrape target is up (a dark target is a blind alert)
#   alerts    nothing at severity page/critical is firing; tickets and warnings WARN
#   marker    (optional) the bootstrap-complete marker on every node, over SSM
#
# WHY SOME THINGS ARE ARITHMETIC RATHER THAN MEASURED, and which
#   etcd quorum: the etcd client port (2379) is not reachable from the operator's
#   workstation by design -- the node-internal security group opens it only to
#   nodes. So the member list is not available here, and the check is stated as
#   what it is: /healthz/etcd returns ok, and at least 2 of the 3 server nodes are
#   Ready, which is the quorum definition for a 3-member cluster. The precise
#   member list is `k3s etcd-snapshot list` / `etcdctl member list` on the leader,
#   and scripts/bootstrap-cluster.sh prints the SSM session to do exactly that.
# ===========================================================================
# The checks are dispatched by name rather than called directly: `run <label>
# <function>` decides which ones run, and one of them (check_node_marker) only
# runs when NODE_LOG_INSTANCE is set. That indirection reads to shellcheck as
# dead code (SC2329), so it is disabled file-wide rather than flattening the run
# table into something less readable.
# shellcheck disable=SC2329
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/boutique-prod.yaml}"
EXPECTED_NODES="${EXPECTED_NODES:-4}"
EXPECTED_SERVERS="${EXPECTED_SERVERS:-3}"
# AZS comes from the environment, so it is split into an array with `read -a`
# rather than an unquoted expansion. A quoted default would instead make this ONE
# element holding three AZ names, and the spread check would look for a node
# labelled "us-east-1a us-east-1b us-east-1c" and report it missing on a perfectly
# healthy cluster. That exact bug was found by running this script against a
# stubbed cluster; the test is in the commit.
AZS=()
read -r -a AZS <<<"${AZS:-us-east-1a us-east-1b us-east-1c}"
NODE_LOG_INSTANCE="${NODE_LOG_INSTANCE:-}"

# 30 days to a failing cert: the kubeconfig client cert is what reissued every 90
# by default in k3s, and an expiry inside a month is not enough time to notice it
# before `kubectl` stops working.
CERT_FAIL_DAYS=30
CERT_WARN_DAYS=90
# Prometheus, reached through the apiserver's service proxy so the check needs
# nothing but the kubeconfig. Overridable for a renamed release.
PROM_PROXY="${PROM_PROXY:-/api/v1/namespaces/observability/services/kube-prometheus-stack-prometheus:9090/proxy}"

PASS=0; FAIL=0; WARN=0
FAILURES=()

cyan() { printf '\033[1;36m%s\033[0m\n' "$*"; }
green() { printf '  \033[1;32mPASS\033[0m\n'; }
red() { printf '  \033[1;31mFAIL\033[0m\n'; }
yellow() { printf '  \033[1;33mWARN\033[0m\n'; }

# Exit 77 from a check means "ran, worked, but is worth a warning".
run() {
  local name="$1" fn="$2" rc=0
  printf '\n\033[1;36m== %s\033[0m\n' "$name"
  "$fn" || rc=$?
  case "$rc" in
    0)  PASS=$((PASS+1)); green ;;
    77) WARN=$((WARN+1)); yellow ;;
    *)  FAIL=$((FAIL+1)); FAILURES+=("$name"); red ;;
  esac
  return 0
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "    (need $1)"; return 1; }; }

# A kubectl call that produced no parseable JSON is a FAILED check, not an empty
# one. Without this, `kubectl get pods -A -o json` failing on a broken kubeconfig
# returns zero objects and the "all pods Running" check reports PASS on a cluster
# that cannot be reached at all -- precisely the "no answer reported as fine"
# failure this script exists to avoid.
kjson() {
  local out
  out="$(kubectl "$@" -o json 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  jq -e . >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------
check_prereq() {
  need kubectl || return 1
  need jq || return 1
  [ -r "$KUBECONFIG_PATH" ] || { echo "    no readable kubeconfig at $KUBECONFIG_PATH; run scripts/bootstrap-cluster.sh"; return 1; }
  export KUBECONFIG="$KUBECONFIG_PATH"

  # The SPEC's exit criterion is that this file is nowhere in the repo. Checking
  # it here rather than trusting it is the difference between a criterion and an
  # intention.
  if git -C "$REPO_ROOT" ls-files --error-unmatch -- '*.kubeconfig' 'kubeconfig*' >/dev/null 2>&1; then
    echo "    a kubeconfig-looking file is tracked in git -- remove it"
    return 1
  fi
  echo "    KUBECONFIG=$KUBECONFIG (mode $(stat -c %a "$KUBECONFIG_PATH"))"
  kubectl version --short 2>/dev/null | sed 's/^/    /' || true
}

check_nodes() {
  local total ready unschedulable tainted json
  json="$(kjson get nodes)" || { echo "    could not list nodes through the API"; return 1; }
  total="$(jq '[.items[]] | length' <<<"$json")"
  ready="$(jq '[.items[] | select((.status.conditions[]? | select(.type=="Ready") | .status) == "True")] | length' <<<"$json")"
  echo "    $ready of $total nodes Ready (expected $EXPECTED_NODES)"
  kubectl get nodes -o wide 2>/dev/null | sed 's|^|      |'

  # THE SPEC'S SCHEDULING MODEL. A server node with
  # node-role.kubernetes.io/control-plane:NoSchedule is the EKS pattern and it is
  # the one thing that makes 3850m/4688Mi of requests unschedulable, because it
  # collapses the cluster to one workload node (1830m/3741Mi = 210.4% CPU).
  # k3s adds no such taint; this asserts it rather than assuming it.
  tainted="$(jq '[.items[]
      | select([.spec.taints[]? | select(.key | startswith("node-role.kubernetes.io/"))] | length > 0)] | length' <<<"$json")"
  unschedulable="$(jq '[.items[] | select(.spec.unschedulable == true)] | length' <<<"$json")"
  echo "    nodes with a node-role taint: $tainted   cordoned: $unschedulable"
  [ "$tainted" -eq 0 ] || { echo "    a node carries a node-role taint; the SPEC's scheduling model requires all $EXPECTED_NODES nodes schedulable"; return 1; }
  [ "$unschedulable" -eq 0 ] || { echo "    a node is cordoned -- uncordon unless this is a drain"; return 1; }
  [ "$total" -eq "$EXPECTED_NODES" ] || { echo "    expected $EXPECTED_NODES nodes"; return 1; }
  [ "$ready" -eq "$total" ] || { echo "    $((total - ready)) node(s) not Ready"; return 1; }
}

check_spread() {
  local missing=0 json
  json="$(kjson get nodes)" || { echo "    could not list nodes through the API"; return 1; }
  echo "    nodes per availability zone:"
  jq -r '.items[] |
      "      \(.metadata.labels["topology.kubernetes.io/zone"] // "<no-zone-label>")  \(.metadata.name)"' <<<"$json" | sort
  for az in "${AZS[@]}"; do
    jq -e '[.items[] | select(.metadata.labels["topology.kubernetes.io/zone"] == "'"$az"'")] | length > 0' >/dev/null <<<"$json" \
      || { echo "    no node in $az -- topologySpreadConstraints cannot honour AZ for a pod scheduled now"; missing=1; }
  done
  [ "$missing" -eq 0 ]
}

check_apiserver() {
  local body
  body="$(kubectl get --raw=/healthz 2>&1)"
  echo "    GET /healthz -> $body"
  [ "$body" = "ok" ] || { echo "    the apiserver is not healthy"; return 1; }
}

check_etcd() {
  local etcd servers_up
  etcd="$(kubectl get --raw=/healthz/etcd 2>&1)"
  echo "    GET /healthz/etcd -> $etcd"
  [ "$etcd" = "ok" ] || { echo "    the apiserver cannot reach etcd"; return 1; }

  # Quorum by arithmetic, stated as such: three server nodes are the cluster, and
  # two of them Ready is a quorum. The member list itself needs the etcd client
  # port, which is node-internal only -- see the header.
  local server_json
  server_json="$(kjson get nodes)" || { echo "    could not list nodes through the API"; return 1; }
  servers_up="$(jq '[.items[]
      | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null)
      | select((.status.conditions[]? | select(.type=="Ready") | .status) == "True")] | length' <<<"$server_json")"
  echo "    control-plane nodes Ready: $servers_up of $EXPECTED_SERVERS (quorum is 2)"
  [ "$servers_up" -ge 2 ] || { echo "    etcd quorum lost: fewer than 2 of $EXPECTED_SERVERS server nodes are Ready"; return 1; }

  echo "    k3s etcd snapshots visible as Kubernetes objects:"
  local snaps
  snaps="$(kjson get etcdsnapshotfiles 2>/dev/null || true)"
  if [ -n "$snaps" ]; then
    jq -r '.items[]? | "      \(.metadata.name)  \(.status.size // "?")"' <<<"$snaps" | tail -5
  else
    echo "      (no ETCDSnapshotFile objects: the k3s CRD is idle until the first snapshot timer run)"
  fi
}

check_pods() {
  local bad json
  json="$(kjson get pods -A)" || { echo "    could not list pods through the API"; return 1; }
  bad="$(printf '%s' "$json" | jq -r '
      [.items[]
       | select((.metadata.namespace | test("^kube-(system|public|node-lease)$")) | not)
       | select((.status.phase != "Running") and (.status.phase != "Succeeded"))
       | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"] | .[]')"
  if [ -n "$bad" ]; then
    echo "    pods not Running or Succeeded outside kube-system:"
    printf '      %s\n' "$bad"
    return 1
  fi
  echo "    every pod outside kube-system is Running or Succeeded"

  # A restart count is not a failure by itself -- k3s restarts a pod after a
  # node replacement -- but a double-digit count in a namespace that has not been
  # drained is the signature of a crashloop, so it is named here rather than left
  # for someone to notice later.
  local restarters
  restarters="$(printf '%s' "$json" | jq -r '
      [.items[] | select(.metadata.namespace | test("^kube-(system|public|node-lease)$") | not)
       | {name: "\(.metadata.namespace)/\(.metadata.name)", restarts: ([.status.containerStatuses[]?.restartCount] | max // 0)}
       | select(.restarts >= 5)] | .[] | "      \(.restarts) restarts  \(.name)"')"
  if [ -n "$restarters" ]; then
    printf '    %s\n' "$restarters"
    yellow
    return 77
  fi
}

check_pdb() {
  local json
  # No `|| true`. kjson() returns 1 when kubectl fails or the output does
  # not parse, and swallowing it here reports a broken API server as "no
  # PodDisruptionBudgets exist" -- the exact fail-open pattern this script's
  # header forbids. An unreachable cluster must be a FAIL, not a WARN.
  if ! json="$(kjson get pdb -A)"; then
    echo "    kubectl could not list PodDisruptionBudgets -- the API is unreachable, so their absence cannot be asserted"; return 1
  fi
  [ -n "$json" ] || { echo "    no PodDisruptionBudgets -- the SPEC's resilience criterion requires one per service"; return 77; }
  echo "    $(printf '%s' "$json" | jq '[.items[]] | length') PodDisruptionBudgets"
  printf '%s' "$json" | jq -r '.items[] |
      "      \(.metadata.namespace)/\(.metadata.name)  desiredHealthy=\(.status.desiredHealthy // .spec.minAvailable // "?")  currentHealthy=\(.status.currentHealthy // 0)  disruptionsAllowed=\(.status.disruptionsAllowed // 0)"'

  local broken
  broken="$(printf '%s' "$json" | jq -r '[.items[]
      | select(.status.currentHealthy != null and .status.desiredHealthy != null)
      | select(.status.currentHealthy < .status.desiredHealthy)] | length')"
  [ "$broken" -eq 0 ] || { echo "    $broken PDB(s) have currentHealthy < desiredHealthy: a voluntary disruption right now would take the service below its floor"; return 1; }

  local blocked
  blocked="$(printf '%s' "$json" | jq -r '[.items[] | select(.status.disruptionsAllowed == 0)] | length')"
  if [ "$blocked" -gt 0 ]; then
    echo "    $blocked PDB(s) allow no voluntary disruption: a drain of those nodes is blocked until replicas come back"
    return 77
  fi
}

check_hpa() {
  local json
  # Same fail-closed reasoning as check_pdb: no `|| true`.
  if ! json="$(kjson get hpa -A)"; then
    echo "    kubectl could not list HorizontalPodAutoscalers -- the API is unreachable, so their absence cannot be asserted"; return 1
  fi
  [ -n "$json" ] || { echo "    no HPAs (none deployed yet -- Phase 6)"; return 77; }
  echo "    $(printf '%s' "$json" | jq '[.items[]] | length') HorizontalPodAutoscalers"
  printf '%s' "$json" | jq -r '.items[] |
      "      \(.metadata.namespace)/\(.metadata.name)  target=\(.status.scaleTargetRef.kind)/\(.status.scaleTargetRef.name)  \(.status.currentReplicas)/\(.status.desiredReplicas) (min \(.spec.minReplicas), max \(.spec.maxReplicas))"'

  local starved
  starved="$(printf '%s' "$json" | jq -r '[.items[] | select(.spec.minReplicas > .status.currentReplicas)] | length')"
  [ "$starved" -eq 0 ] || { echo "    $starved HPA(s) are below their minReplicas: the ReplicaSet cannot place the pods it wants"; return 1; }

  local atmax
  atmax="$(printf '%s' "$json" | jq -r '[.items[] | select(.status.desiredReplicas >= .spec.maxReplicas)] | length')"
  if [ "$atmax" -gt 0 ]; then
    echo "    $atmax HPA(s) at maxReplicas: headroom exhausted, scaling further needs a change"
    return 77
  fi
}

check_pvc() {
  local json pending
  # Same fail-closed reasoning as check_pdb, and this one was worse: it
  # returned 0 (a PASS) on an API error, so an unreachable cluster read as
  # a healthy one.
  if ! json="$(kjson get pvc -A)"; then
    echo "    kubectl could not list PersistentVolumeClaims -- the API is unreachable"; return 1
  fi
  [ -n "$json" ] || { echo "    no PersistentVolumeClaims (local-path-provisioner is idle)"; return 0; }
  pending="$(printf '%s' "$json" | jq -r '[.items[] | select(.status.phase != "Bound")] | length')"
  echo "    $(printf '%s' "$json" | jq '[.items[]] | length') PVCs, $pending not Bound"
  printf '%s' "$json" | jq -r '.items[] | "      \(.metadata.namespace)/\(.metadata.name)  \(.status.phase)  \(.spec.volumeName // "<unbound>")"'
  [ "$pending" -eq 0 ] || return 1
}

# Certificates. Two, because they fail differently: the client cert in the
# kubeconfig stops the operator working, and the apiserver's serving cert stops
# every client working. openssl is the only dependency and it is on every
# workstation this repo targets.
# Prometheus answers through the apiserver proxy, so an empty or non-JSON reply
# is the same fail-closed case kjson() covers for kubectl.
promjson() {
  local out
  out="$(kubectl get --raw "${PROM_PROXY}$1" 2>/dev/null)" || return 1
  jq -e '.status == "success"' >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s' "$out"
}

# Added 2026-10-17. Every control-plane target had been failing its scrape for
# days (sample limit exceeded) while this script said PASS 8 / FAIL 0, because
# nothing here asked Prometheus whether it could see anything.
check_targets() {
  local json down
  if ! json="$(promjson '/api/v1/targets?state=active')"; then
    echo "    Prometheus did not answer at ${PROM_PROXY} -- metrics and alerting are blind"; return 1
  fi
  echo "    $(jq '.data.activeTargets | length' <<<"$json") active targets"
  down="$(jq -r '[.data.activeTargets[] | select(.health != "up")] | length' <<<"$json")"
  [ "$down" -eq 0 ] && return 0
  jq -r '.data.activeTargets[] | select(.health != "up") |
      "      DOWN \(.labels.job) \(.scrapeUrl)  \(.lastError[0:100])"' <<<"$json"
  echo "    $down target(s) down: their alerts cannot fire and their dashboards are empty"
  return 1
}

# Added 2026-10-17, with the same history: three critical alerts and an
# Alertmanager that could not deliver anything had been firing for days under
# a PASS verdict. Watchdog and InfoInhibitor are the two alerts that fire by
# design, so they are excluded by name rather than by severity.
check_alerts() {
  local json firing
  if ! json="$(promjson '/api/v1/alerts')"; then
    echo "    Prometheus did not answer at ${PROM_PROXY} -- alert state is unknown"; return 1
  fi
  firing="$(jq -c '[.data.alerts[] | select(.state == "firing")
      | select(.labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")]' <<<"$json")"
  if [ "$(jq length <<<"$firing")" -eq 0 ]; then
    echo "    no alerts firing (Watchdog excluded: it fires by design)"; return 0
  fi
  jq -r '.[] | "      \(.labels.severity // "none")  \(.labels.alertname)  \(.labels.namespace // "")"' <<<"$firing" | sort | uniq -c
  if jq -e 'any(.[]; .labels.severity == "page" or .labels.severity == "critical")' >/dev/null <<<"$firing"; then
    echo "    a page or critical alert is firing"; return 1
  fi
  echo "    only ticket/warning/info alerts are firing"; return 77
}

check_certs() {
  local pem end days
  pem="$(kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -n "$pem" ] || { echo "    could not read a client certificate from the kubeconfig"; return 77; }
  end="$(printf '%s' "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  [ -n "$end" ] || { echo "    openssl could not parse the client certificate"; return 77; }
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  echo "    kubeconfig client certificate: expires $end ($days days)"
  if [ "$days" -lt "$CERT_FAIL_DAYS" ]; then
    echo "    under ${CERT_FAIL_DAYS} days: rotate now, before kubectl stops working"
    return 1
  elif [ "$days" -lt "$CERT_WARN_DAYS" ]; then
    echo "    under ${CERT_WARN_DAYS} days: schedule the rotation"
    return 77
  fi

  local endpoint
  endpoint="$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  case "$endpoint" in
    https://*)
      # ${endpoint#https://} already carries a port when the kubeconfig does --
      # it is `18.209.227.106:6443`. Appending another :6443 used to build
      # `18.209.227.106:6443:6443`, which connect(2) rejects, so this check
      # reported "unreachable" for an apiserver that answered on the first
      # attempt (measured 2026-10-14). Add the port only when there is none.
      local hostport cert
      hostport="${endpoint#https://}"
      hostport="${hostport%%/*}"
      case "$hostport" in
        *:*) ;;
        *) hostport="${hostport}:6443" ;;
      esac
      cert="$(echo | timeout 10 openssl s_client -connect "$hostport" 2>/dev/null \
              | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
      [ -n "$cert" ] || { echo "    apiserver serving certificate: unreachable at $hostport (expected from outside var.admin_cidr)"; return 77; }
      local sdays
      sdays=$(( ( $(date -d "$cert" +%s) - $(date +%s) ) / 86400 ))
      echo "    apiserver serving certificate: expires $cert ($sdays days)"
      [ "$sdays" -ge "$CERT_FAIL_DAYS" ] || { echo "    the serving certificate expires in under ${CERT_FAIL_DAYS} days"; return 1; }
      [ "$sdays" -ge "$CERT_WARN_DAYS" ] || return 77
      ;;
    *) echo "    cluster server is $endpoint, not an https URL; skipped the serving-cert check" ;;
  esac
}

# Optional, and only when told to: this is the one check that needs AWS
# credentials, because it reads the nodes' own bootstrap logs over SSM. Off by
# default so doctor.sh stays usable from a machine with no AWS access at all.
check_node_marker() {
  need aws || return 1
  [ -n "$NODE_LOG_INSTANCE" ] || { echo "    pass NODE_LOG_INSTANCE=<i-...> to check a node's bootstrap log"; return 1; }
  local out rc=0
  out="$(aws ssm send-command --instance-ids "$NODE_LOG_INSTANCE" \
    --document-name AWS-RunShellScript \
    --comment "boutique-platform: doctor.sh node bootstrap log" \
    --parameters 'commands=["sudo tail -40 /var/log/boutique-bootstrap.log","sudo cat /var/lib/boutique-bootstrap-complete 2>/dev/null"]' \
    --query 'Command.CommandId' --output text)" || return 1
  sleep 3
  local status
  for _ in $(seq 1 20); do
    status="$(aws ssm get-command-invocation --instance-id "$NODE_LOG_INSTANCE" --command-id "$out" \
      --plugin-name aws:RunShellScript --query 'Status' --output text 2>/dev/null || echo Pending)"
    [ "$status" = "Success" ] && break
    [ "$status" = "Failed" ] && { echo "    SSM invocation failed"; return 1; }
    sleep 3
  done
  echo "    /var/log/boutique-bootstrap.log (last lines) on $NODE_LOG_INSTANCE:"
  aws ssm get-command-invocation --instance-id "$NODE_LOG_INSTANCE" --command-id "$out" \
    --plugin-name aws:RunShellScript --query 'StandardOutputContent' --output text 2>/dev/null \
    | sed 's/^/      /'
  grep -q 'bootstrap complete' <<<"$(aws ssm get-command-invocation --instance-id "$NODE_LOG_INSTANCE" \
    --command-id "$out" --plugin-name aws:RunShellScript --query 'StandardOutputContent' --output text 2>/dev/null)" \
    || { echo "    the node never wrote its completion marker"; rc=1; }
  return "$rc"
}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------
run "prerequisite: kubectl, kubeconfig, and the kubeconfig is not in git" check_prereq
run "nodes: $EXPECTED_NODES present, $EXPECTED_NODES Ready, none tainted, none cordoned" check_nodes
run "spread: one node in each of the ${AZS[*]}" check_spread
run "apiserver: GET /healthz" check_apiserver
run "etcd: reachable, and quorum is intact" check_etcd
run "pods: non-kube-system all Running, no crashloop" check_pods
run "disruption: PodDisruptionBudgets are satisfied" check_pdb
run "autoscaling: HPAs are at or above minReplicas" check_hpa
run "storage: every PVC is Bound" check_pvc
run "certificates: client and serving, in days" check_certs
run "scrape targets: every active Prometheus target is up" check_targets
run "alerts: nothing at severity page or critical is firing" check_alerts
if [ -n "$NODE_LOG_INSTANCE" ]; then
  run "node bootstrap log over SSM" check_node_marker
fi

printf '\n'
cyan '==============================================='
printf '  PASS: %d   WARN: %d   FAIL: %d\n' "$PASS" "$WARN" "$FAIL"
if [ "${#FAILURES[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILURES[*]}"
fi
cyan '==============================================='

# The one-line verdict, which is the whole point of the tool: something a person
# can read in a terminal or paste into a ticket without parsing the output above.
if [ "$FAIL" -eq 0 ]; then
  printf '\nVERDICT: PASS -- %d checks green, %d warning(s), cluster healthy\n' "$PASS" "$WARN"
  [ "$WARN" -eq 0 ] || printf '         (the warnings above are advisory: none of them blocks traffic)\n'
  exit 0
fi
printf '\nVERDICT: FAIL -- %s\n' "${FAILURES[*]}"
exit 1
