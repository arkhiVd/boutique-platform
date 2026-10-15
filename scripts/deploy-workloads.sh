#!/usr/bin/env bash
# ===========================================================================
# deploy-workloads.sh — deploy every workload to a fresh cluster, in order.
#
# THE CONTRACT: this is the only command an operator runs after
# `terraform apply` and `scripts/bootstrap-cluster.sh`. It deploys the policy
# layer, the application, the observability stack and CI, waits for each stage
# to be Ready before the next, and ends with the doctor verdict. No step is
# manual, no value is hardcoded that belongs in a chart, and a failure stops
# the script at the step that failed rather than continuing into a cluster that
# is half-deployed and therefore harder to reason about.
#
# ORDER, AND WHY IT IS THIS ORDER
#   1. policies      RBAC, PDBs, quotas, priority classes. Everything below is
#                    admitted by these, so they go first.
#   2. boutique       The application, its namespace and the observability
#                    namespace. The collector ships inside this apply, so the
#                    namespace it lands in is decided here, not later.
#   3. ebs-csi       The gp3 StorageClass every observability PVC asks for.
#                    Without it those PVCs sit Pending forever, and a Pending
#                    PVC looks exactly like a chart bug.
#   4. grafana-secret  Must exist before kube-prometheus-stack, or every
#                    Grafana pod sits in CreateContainerConfigError.
#   5. kube-prometheus-stack  Prometheus, Alertmanager, Grafana, operator,
#                    node-exporter. The largest stage; everything after it is
#                    observed by it.
#   6. loki          Log store. Needs Prometheus running only for the alerts
#                    that prove ingestion, which is why it is after, not before.
#   7. fluent-bit    Ships container logs into Loki. The parser ConfigMap is
#                    applied here because the chart mounts it by name and the
#                    chart does not create it.
#   8. tempo         Trace store. Remote-writes into Prometheus, so it is after.
#   9. blackbox      Synthetic probes. Needs the edge, which is already up.
#  10. jenkins       CI. Last, because it is the stage most likely to be
#                    iterated on and the one whose failure should not block
#                    the platform's observability.
#
# WHAT IS DELIBERATELY NOT HERE: the platform itself (Terraform), the kubeconfig
# (bootstrap-cluster.sh) and the health verdict (doctor.sh). This script is the
# middle of three, and the split is what makes each part re-runnable on its own.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/boutique-prod.yaml}"
[ -r "$KUBECONFIG" ] || {
  echo "no readable kubeconfig at $KUBECONFIG; run scripts/bootstrap-cluster.sh" >&2
  exit 1
}

# NAMESPACES FIRST, because cluster/policies/ declares objects in every one of
# them and Kubernetes rejects a namespaced object whose namespace does not exist:
# `namespaces "boutique" not found`. The application apply below would create two
# of them, but relying on that means the policy layer depends on the application
# layer, and a policy failure then looks like an application failure.
for ns in boutique observability ci traefik; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# step <name> <command...> — runs a stage, prints its name, and stops the script
# on failure with the step named. `helm upgrade --install` is idempotent, so
# re-running this script after a failure resumes at the failed step rather than
# redeploying everything before it.
step() {
  local name="$1"; shift
  printf '\n=== %s ===\n' "$name"
  "$@"
  echo "--- $name: done"
}

step "policies" \
  kubectl apply -f cluster/rbac/ -f cluster/policies/ -f cluster/priority.yaml

step "traefik edge" \
  helm upgrade --install traefik cluster/traefik -n traefik

step "boutique application + observability namespace" \
  kubectl apply -k apps/boutique/

step "ebs-csi driver (gp3 StorageClass)" \
  helm upgrade --install ebs-csi cluster/ebs-csi -n kube-system

step "grafana admin secret" \
  ./scripts/create-grafana-secret.sh

step "jenkins secrets" \
  ./scripts/create-jenkins-secrets.sh

step "kube-prometheus-stack" \
  helm upgrade --install kube-prometheus-stack observability/kube-prometheus-stack -n observability

step "loki" \
  helm upgrade --install loki observability/loki -n observability

step "fluent-bit parser configmap" \
  kubectl apply -f observability/fluent-bit/boutique-parsers.yaml

# The step-7 lua filter's script, the same shape as the parser ConfigMap: a file
# in the repo applied before the chart that mounts it. Without it the DaemonSet
# fails pre_run with "filter cannot be loaded" (measured 2026-10-15).
step "fluent-bit k8s label configmap" \
  kubectl apply -f observability/fluent-bit/k8s-labels.yaml

step "fluent-bit" \
  helm upgrade --install fluent-bit observability/fluent-bit -n observability

step "tempo" \
  helm upgrade --install tempo observability/tempo -n observability

step "blackbox probe configmap" \
  kubectl apply -f observability/blackbox/probe-config.yaml

step "blackbox exporter" \
  helm upgrade --install blackbox observability/blackbox -n observability

step "jenkins rbac" \
  kubectl apply -f ci/rbac/

step "jenkins" \
  helm upgrade --install ci ci/jenkins/ -n ci --create-namespace -f ci/jenkins/values.yaml

# WAIT, AND WHY IT IS A WAIT AND NOT A SLEEP
# A fixed sleep is a guess about how long a rollout takes, and the guess is
# wrong in both directions: too short and the next stage deploys into a cluster
# that is not ready, too long and the operator waits for nothing. Each wait
# names the readiness condition it is waiting for, so a timeout says which
# component is slow rather than that "something" is slow.
printf '\n=== waiting for workloads ===\n'

kubectl -n observability rollout status deployment/kube-prometheus-stack-grafana --timeout=300s
kubectl -n observability rollout status deployment/kube-prometheus-stack-kube-state-metrics --timeout=180s
kubectl -n observability rollout status deployment/kube-prometheus-stack-operator --timeout=180s
kubectl -n observability rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=300s
kubectl -n observability rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager --timeout=300s
kubectl -n observability rollout status statefulset/loki --timeout=300s
kubectl -n observability rollout status statefulset/tempo --timeout=300s
kubectl -n kube-system rollout status daemonset/ebs-csi-node --timeout=300s
kubectl -n observability rollout status daemonset/kube-prometheus-stack-prometheus-node-exporter --timeout=300s
kubectl -n observability rollout status daemonset/fluent-bit --timeout=300s
kubectl -n ci rollout status statefulset/ci --timeout=300s

echo "all rollouts complete"

# THE VERDICT, FROM THE GATE THAT ALREADY EXISTS
# Not a new check: doctor.sh is the same gate the platform has always run, and
# its exit code is the script's exit code. A cluster this script cannot get to
# a PASS is a cluster the script failed to deploy, not one doctor.sh dislikes.
printf '\n=== doctor ===\n'
scripts/doctor.sh
