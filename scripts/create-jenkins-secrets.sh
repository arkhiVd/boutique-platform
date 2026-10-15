#!/usr/bin/env bash
# ===========================================================================
# create-jenkins-secrets.sh — provision the Secrets the Jenkins chart reads.
#
# The chart sets `admin.existingSecret: jenkins-admin` and mounts
# `jenkins-pipeline-credentials` as env vars in the pipeline pod template. Both
# must exist before the StatefulSet creates its pod, otherwise the pod is stuck
# at Init with `secret "..." not found` — the same failure mode as the Grafana
# admin Secret, and the same fix: a script that owns the out-of-band step.
#
# RULES (same as scripts/create-grafana-secret.sh):
#   1. Passwords are never printed, written to a file, or committed.
#   2. Values come from env vars when set; the admin password is generated when
#      not. The GitHub credentials are NOT generated — they are the operator's
#      own, and a placeholder would be worse than a missing Secret.
#   3. Idempotent: re-running is a no-op unless --rotate is passed.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="ci"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/boutique-prod.yaml}"
[ -r "$KUBECONFIG_PATH" ] || {
  echo "no readable kubeconfig at $KUBECONFIG_PATH; run scripts/bootstrap-cluster.sh" >&2
  exit 1
}
export KUBECONFIG="$KUBECONFIG_PATH"

command -v kubectl >/dev/null || { echo "kubectl not on PATH" >&2; exit 1; }
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "namespace $NAMESPACE does not exist; run scripts/deploy-workloads.sh" >&2
  exit 1
}

ROTATE=0
if [ "${1:-}" = "--rotate" ]; then
  ROTATE=1
fi

# --- jenkins-admin ---------------------------------------------------------

ADMIN_EXISTS=0
if kubectl get secret jenkins-admin -n "$NAMESPACE" >/dev/null 2>&1; then
  ADMIN_EXISTS=1
  if [ "$ROTATE" -eq 0 ]; then
    echo "secret $NAMESPACE/jenkins-admin already exists; nothing to do"
  fi
fi

if [ "$ADMIN_EXISTS" -eq 0 ] || [ "$ROTATE" -eq 1 ]; then
  if [ -n "${JENKINS_ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASSWORD="$JENKINS_ADMIN_PASSWORD"
  else
    ADMIN_PASSWORD="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | cut -c 1-48)"
  fi
  [ -n "$ADMIN_PASSWORD" ] || { echo "generated an empty password" >&2; exit 1; }

  kubectl create secret generic jenkins-admin -n "$NAMESPACE" \
    --from-literal=jenkins-admin-user=admin \
    --from-literal=jenkins-admin-password="$ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  unset ADMIN_PASSWORD
  echo "created/rotated $NAMESPACE/jenkins-admin"
fi

# --- jenkins-pipeline-credentials ------------------------------------------

# These are the operator's GitHub credentials for pipeline checkouts. They are
# NOT generated — a placeholder token would fail at the first pipeline run with
# an authentication error that looks like a code problem. If the env vars are
# not set, the Secret is skipped and the operator is told how to supply it.
if [ -n "${GITHUB_USERNAME:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  PIPE_EXISTS=0
  if kubectl get secret jenkins-pipeline-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
    PIPE_EXISTS=1
    if [ "$ROTATE" -eq 0 ]; then
      echo "secret $NAMESPACE/jenkins-pipeline-credentials already exists; nothing to do"
    fi
  fi

  if [ "$PIPE_EXISTS" -eq 0 ] || [ "$ROTATE" -eq 1 ]; then
    kubectl create secret generic jenkins-pipeline-credentials -n "$NAMESPACE" \
      --from-literal=github-username="$GITHUB_USERNAME" \
      --from-literal=github-password="$GITHUB_TOKEN" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "created/rotated $NAMESPACE/jenkins-pipeline-credentials"
  fi
else
  echo "skipping $NAMESPACE/jenkins-pipeline-credentials: set GITHUB_USERNAME and GITHUB_TOKEN to create it"
  echo "  the Jenkins pipelines need it for checkouts; without it they fail at the first run"
fi

echo
echo "The admin password is in the cluster Secret only. To read it:"
echo "  kubectl get secret jenkins-admin -n $NAMESPACE -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo"
