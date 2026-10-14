#!/usr/bin/env bash
# ===========================================================================
# create-grafana-secret.sh -- provision the Secret kube-prometheus-stack reads
# the Grafana admin credentials from.
#
# WHY THIS EXISTS
#
# observability/kube-prometheus-stack/values.yaml sets
#
#     grafana.admin.existingSecret: grafana-admin
#     userKey: admin-user
#     passwordKey: admin-password
#
# which means the chart renders NO Secret of its own: it reads one that has to
# exist first. That contract was written down in a comment ("`scripts/` owns
# that step") while the script that owned it was never written, so on a fresh
# cluster every Grafana pod sits in CreateContainerConfigError forever:
#
#   Warning Failed kubelet spec.containers{grafana-sc-dashboard}:
#     Error: secret "grafana-admin" not found
#
# Observed 2026-10-14 as 781 restarts of pod 0/3 over 172 minutes on a cluster
# where Prometheus, Alertmanager and node-exporter were all healthy — the
# classic one-missing-file outage that looks like a Grafana bug and is not one.
# This script is the missing half of that contract.
#
# RULES, in the same spirit as scripts/tls/generate-selfsigned.sh
#
#   1. The password is NEVER written to stdout, to a file, or into this repo.
#      It exists only in the cluster's own Secret. Retrieving it is one
#      `kubectl get` that the operator chooses to run, which means it lands in
#      shell history only if they type it.
#
#   2. The password comes from $GRAFANA_ADMIN_PASSWORD when set — that is how
#      an automated deploy supplies one it already holds — and is generated
#      from /dev/urandom (256 bits, alphanumeric, no shell-unsafe characters)
#      when not. Nothing about the credential is ever assumed or defaulted.
#
#   3. Idempotent. Re-running against an existing Secret is a no-op that says
#      so, rather than silently rotating the operator out of their dashboard.
#      `--rotate` rotates deliberately, and then restarts Grafana so the new
#      credential takes effect in the same shell call.
#
#   4. A Secret that is created is reported with its name and namespace only.
#      No key material is echoed, so this script's output is safe to paste into
#      a ticket or a log.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="observability"
SECRET_NAME="grafana-admin"
USER_KEY="admin-user"
PASSWORD_KEY="admin-password"

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/boutique-prod.yaml}"
[ -r "$KUBECONFIG_PATH" ] || {
  echo "no readable kubeconfig at $KUBECONFIG_PATH; run scripts/bootstrap-cluster.sh" >&2
  exit 1
}
export KUBECONFIG="$KUBECONFIG_PATH"

command -v kubectl >/dev/null || { echo "kubectl not on PATH" >&2; exit 1; }
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "namespace $NAMESPACE does not exist; apply apps/boutique/observability/namespace.yaml" >&2
  exit 1
}

ROTATE=0
if [ "${1:-}" = "--rotate" ]; then
  ROTATE=1
fi

EXISTS=0
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  EXISTS=1
  if [ "$ROTATE" -eq 0 ]; then
    echo "secret $NAMESPACE/$SECRET_NAME already exists; nothing to do"
    echo "  to replace the password, re-run with --rotate (Grafana restarts)"
    exit 0
  fi
fi

# Generate only what we do not have. `openssl rand` is bounded, and the producer
# and both consumers are too, so no stage closes its pipe early and `set -o
# pipefail` is not tripped by a SIGPIPE that a `head -c` would cause. The few
# characters `tr` strips (+ / =) are the ones that need quoting in a URL or a
# shell prompt; 96 bytes of base64 survive to ~72 alphanumerics, of which 48
# are kept.
if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  PASSWORD="$GRAFANA_ADMIN_PASSWORD"
else
  PASSWORD="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | cut -c 1-48)"
fi
[ -n "$PASSWORD" ] || { echo "generated an empty password; refusing to continue" >&2; exit 1; }

# The password is never on the command line: `kubectl create secret` receives
# a manifest on stdin, so it does not appear in `ps` output. `--dry-run=client`
# then `apply` is the create-or-update form, which keeps --rotate to one call
# instead of a delete followed by a create that would leave a window in which
# Grafana has no credential at all.
kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal="$USER_KEY=admin" \
  --from-literal="$PASSWORD_KEY=$PASSWORD" \
  --dry-run=client -o yaml |
  kubectl apply -f - >/dev/null

unset PASSWORD

if [ "$ROTATE" -eq 1 ]; then
  # The chart restarts the deployment on its own for the dashboard/config
  # sidecar, but the admin credential is read at container start, so a
  # rotation without this rollout leaves the new password on the next restart
  # rather than this one.
  kubectl rollout restart deployment/kube-prometheus-stack-grafana -n "$NAMESPACE"
fi

if [ "$EXISTS" -eq 1 ]; then
  echo "rotated $NAMESPACE/$SECRET_NAME"
else
  echo "created $NAMESPACE/$SECRET_NAME"
fi

echo
echo "The password is in the cluster Secret only. To read it:"
echo "  kubectl get secret $SECRET_NAME -n $NAMESPACE \\"
echo "    -o jsonpath='{.data.$PASSWORD_KEY}' | base64 -d; echo"
echo
echo "If you did not supply \$GRAFANA_ADMIN_PASSWORD, you have no record of this"
echo "value anywhere else — run the command above before closing this session."
