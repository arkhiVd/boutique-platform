#!/bin/sh
# ---------------------------------------------------------------------------
# canary.sh -- the canary, the burn-rate check, and the automatic rollback
# behind vars/canaryAndRollback.groovy.
#
# Contract:
#   1. shift WEIGHT% of the traffic onto the canary through the Traefik
#      weighted service the application provides
#   2. sample a PromQL expression every INTERVAL seconds until OBSERVE_SECONDS
#      are up (or a sample breaches, which stops it early)
#   3. on the first breach, or on a sample Prometheus cannot answer, put all
#      the traffic back and roll the canary Deployment back -- with no human
#      step anywhere in that path. That is the exit criterion; a canary that
#      needs someone to notice is a canary that does not roll back.
#
# Why fail-closed on missing data: a query that returns nothing is either
# "metrics have not arrived yet" or "the canary is generating no traffic
# worth measuring". Both are reasons not to keep serving at 10%. The message
# says which case was hit, so the operator does not have to guess.
#
# Requires (all set by vars/canaryAndRollback.groovy):
#   CANARY_NAMESPACE, CANARY_DEPLOYMENT, CANARY_TRAEFIK_SERVICE,
#   STABLE_SERVICE, CANARY_SERVICE, PROM_URL, BURN_QUERY, KUBECTL_IMAGE,
#   CURL_IMAGE
# Optional:
#   WEIGHT (10), BURN_THRESHOLD (0), OBSERVE_SECONDS (300), INTERVAL (30)
# ---------------------------------------------------------------------------
set -u

: "${CANARY_NAMESPACE:?CANARY_NAMESPACE is required}"
: "${CANARY_DEPLOYMENT:?CANARY_DEPLOYMENT is required}"
: "${CANARY_TRAEFIK_SERVICE:?CANARY_TRAEFIK_SERVICE is required}"
: "${STABLE_SERVICE:?STABLE_SERVICE is required}"
: "${CANARY_SERVICE:?CANARY_SERVICE is required}"
: "${PROM_URL:?PROM_URL is required}"
: "${BURN_QUERY:?BURN_QUERY is required}"
: "${KUBECTL_IMAGE:?KUBECTL_IMAGE is required}"
: "${CURL_IMAGE:?CURL_IMAGE is required}"

WEIGHT="${WEIGHT:-10}"
BURN_THRESHOLD="${BURN_THRESHOLD:-0}"
OBSERVE_SECONDS="${OBSERVE_SECONDS:-300}"
INTERVAL="${INTERVAL:-30}"
STABLE_WEIGHT=$((100 - WEIGHT))

# The agent pod's projected ServiceAccount token and the cluster CA, which is
# all in-cluster kubectl needs. No kubeconfig is written anywhere.
kctl() {
	docker run --rm --network host -u 0 \
		-v /var/run/secrets/kubernetes.io/serviceaccount:/var/run/secrets/kubernetes.io/serviceaccount:ro \
		-e KUBERNETES_SERVICE_HOST -e KUBERNETES_SERVICE_PORT \
		"$KUBECTL_IMAGE" "$@"
}

set_weights() {
	kctl patch traefikservice "$CANARY_TRAEFIK_SERVICE" \
		-n "$CANARY_NAMESPACE" --type merge \
		-p "{\"spec\":{\"weighted\":{\"services\":[{\"name\":\"$STABLE_SERVICE\",\"weight\":$1},{\"name\":\"$CANARY_SERVICE\",\"weight\":$2}]}}}"
}

rollback() {
	echo "canary: restoring 100% of traffic to ${STABLE_SERVICE}"
	set_weights 100 0 || echo "canary: traffic restore failed -- see the error above"
	echo "canary: rolling back deployment/${CANARY_DEPLOYMENT}"
	kctl rollout undo "deployment/${CANARY_DEPLOYMENT}" -n "$CANARY_NAMESPACE" ||
		echo "canary: rollout undo failed -- see the error above"
	kctl rollout status "deployment/${CANARY_DEPLOYMENT}" -n "$CANARY_NAMESPACE" \
		--timeout=180s || true
}

# One PromQL sample, printed as a bare number. Exit 1 for "no answer", which
# the caller treats as a breach. There is no jq in any image this pipeline
# pulls, so the scalar is cut out of the vector response with grep/sed --
# deliberately crude, and checked by a shellcheck-clean path rather than by a
# parser nobody has installed.
prom_value() {
	body=$(docker run --rm "$CURL_IMAGE" -s -G \
		"$PROM_URL/api/v1/query" \
		--data-urlencode "query=$BURN_QUERY" 2>/dev/null) || return 1
	printf '%s' "$body" | grep -o '"status":"success"' >/dev/null || return 1
	printf '%s' "$body" |
		grep -o '"value":\[[^]]*\]' |
		head -n 1 |
		sed 's/.*,"\([^"]*\)".*/\1/' |
		grep -q . || return 1
	printf '%s' "$body" |
		grep -o '"value":\[[^]]*\]' |
		head -n 1 |
		sed 's/.*,"\([^"]*\)".*/\1/'
}

echo "canary: ${WEIGHT}% onto ${CANARY_SERVICE} in ${CANARY_NAMESPACE}"
set_weights "$STABLE_WEIGHT" "$WEIGHT"

elapsed=0
breaches=0
while [ "$elapsed" -lt "$OBSERVE_SECONDS" ]; do
	sleep "$INTERVAL"
	elapsed=$((elapsed + INTERVAL))

	if ! value=$(prom_value); then
		echo "canary: sample at ${elapsed}s: no data from Prometheus for"
		echo "        ${BURN_QUERY}"
		breaches=$((breaches + 1))
		rollback
		echo "canary: ROLLED BACK -- fail-closed on missing metrics"
		exit 1
	fi

	echo "canary: sample at ${elapsed}s: ${value} (threshold ${BURN_THRESHOLD})"
	if awk -v v="$value" -v t="$BURN_THRESHOLD" 'BEGIN { exit (v > t) ? 0 : 1 }'; then
		echo "canary: ${value} is over the ${BURN_THRESHOLD} threshold"
		breaches=$((breaches + 1))
		rollback
		echo "canary: ROLLED BACK automatically -- no human step was taken"
		exit 1
	fi
done

echo "canary: held for ${OBSERVE_SECONDS}s with ${breaches} breach(es);"
echo "        ${WEIGHT}% stays on ${CANARY_SERVICE} until promoteToProd"
