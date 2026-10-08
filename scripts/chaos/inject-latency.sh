#!/usr/bin/env bash
# Inject EXTRA_LATENCY into productcatalogservice, hold it for a window, remove it.
#
#   scripts/chaos/inject-latency.sh <duration>          e.g. 90s, 5m, 2h
#   NAMESPACE=boutique DEPLOYMENT=productcatalogservice scripts/chaos/inject-latency.sh 90s
#
# Docs: docs/chaos-experiments.md
#
# This is the ONLY fault flag that exists in Online Boutique. Verified absent
# upstream: adServiceFailure, recommendationCacheFailure (checked across
# v0.1.4 .. v0.10.7). Do not invent more.
set -euo pipefail

readonly DEFAULT_NAMESPACE="boutique"
readonly DEFAULT_DEPLOYMENT="productcatalogservice"
readonly FLAG="EXTRA_LATENCY"

NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
DEPLOYMENT="${DEPLOYMENT:-$DEFAULT_DEPLOYMENT}"
USAGE="usage: $(basename "$0") <duration>   # duration: 90s, 5m, 1h30m"

if [[ $# -lt 1 || $# -gt 1 ]]; then
  echo "$USAGE" >&2
  exit 2
fi
DURATION="$1"

# The duration is passed straight to `sleep`, so validate the shape here rather
# than letting sleep fail three minutes into an experiment.
if [[ ! "$DURATION" =~ ^[0-9]+(\.[0-9]+)?(s|m|h|d)$ ]]; then
  echo "inject-latency: duration '$DURATION' does not look like a Go/GNU duration (e.g. 90s, 5m, 1h30m)" >&2
  exit 2
fi

log() { printf '[%s] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }

# ---------------------------------------------------------------------------
# Preflight. Every step below is a live command against a cluster, so fail here
# rather than half-way through an experiment.
# ---------------------------------------------------------------------------
if ! kubectl -n "$NAMESPACE" get "deploy/$DEPLOYMENT" >/dev/null 2>&1; then
  echo "inject-latency: cannot reach deploy/$DEPLOYMENT in namespace $NAMESPACE" >&2
  echo "                 export KUBECONFIG, and check NAMESPACE/DEPLOYMENT" >&2
  exit 1
fi

IMAGE="$(kubectl -n "$NAMESPACE" get "deploy/$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
log "target   : $NAMESPACE/deploy/$DEPLOYMENT ($IMAGE)"
log "duration : $DURATION"

# The loadgenerator's own error counter is the assertion. Sample before the
# injection so the run has a baseline rather than only an ending.
loadgen_errors() {
  # `Aggregated` is the line locust prints; `Error` counts the requests that
  # failed. A missing loadgenerator is reported, not swallowed.
  if ! kubectl -n "$NAMESPACE" logs "deploy/loadgenerator" --tail=2000 2>/dev/null \
      | grep -E 'Aggregated' | tail -1; then
    echo "loadgenerator: no Aggregated line found in the last 2000 lines"
  fi
}

log "--- loadgenerator, BEFORE ---"
loadgen_errors

# ---------------------------------------------------------------------------
# Inject
# ---------------------------------------------------------------------------
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
log "injecting $FLAG=$DURATION"
kubectl -n "$NAMESPACE" set env "deploy/$DEPLOYMENT" "$FLAG=$DURATION"
kubectl -n "$NAMESPACE" rollout status "deploy/$DEPLOYMENT" --timeout="$ROLLOUT_TIMEOUT"
log "injected; holding for $DURATION"

sleep "$DURATION"

# ---------------------------------------------------------------------------
# Remove. The `VAR-` form is what deletes an environment variable; leaving it set
# is the single most likely way to turn a chaos experiment into an incident.
# ---------------------------------------------------------------------------
log "removing $FLAG"
kubectl -n "$NAMESPACE" set env "deploy/$DEPLOYMENT" "$FLAG-"
kubectl -n "$NAMESPACE" rollout status "deploy/$DEPLOYMENT" --timeout="$ROLLOUT_TIMEOUT"
log "removed"

log "--- loadgenerator, AFTER ---"
loadgen_errors

log "done. Expected result: the same Aggregated error count, unchanged."
log "For a latency experiment you want the p95 column to move and the error"
log "count not to; if the errors moved, the latency exceeded the client timeout."
