#!/bin/sh
# ---------------------------------------------------------------------------
# smoke.sh -- the smoke gate behind vars/smokeGate.groovy.
#
# Runs in the agent pod's dind container (it needs docker to run the curl
# image; the agent image has no curl and installing one per build is how a gate
# acquires an unpinned dependency).
#
# Contract:
#   * every sample must be a successful HTTP status (2xx/3xx)
#   * every sample must complete within LATENCY_MS
#   * transport failures (connection refused, DNS, TLS) count as errors
# Exit status is non-zero if either budget is breached. A budget of zero
# errors is Google's gate as ROADMAP Phase 8 states it: there is no "mostly
# fine" for a release.
#
# Inputs: SMOKE_URL, SMOKE_CURL_IMAGE required; SAMPLES, LATENCY_MS optional.
# ---------------------------------------------------------------------------
set -u

: "${SMOKE_URL:?SMOKE_URL is required}"
: "${SMOKE_CURL_IMAGE:?SMOKE_CURL_IMAGE is required}"
SAMPLES="${SAMPLES:-20}"
LATENCY_MS="${LATENCY_MS:-500}"

errors=0
slow=0
worst_ms=0
i=0

echo "smoke: ${SAMPLES} samples of ${SMOKE_URL}, ceiling ${LATENCY_MS}ms"

while [ "$i" -lt "$SAMPLES" ]; do
	i=$((i + 1))

	# -w prints "<http_code> <time_total>" to stdout once the body is
	# discarded, which is the whole measurement: code for the error budget,
	# time_total for the latency ceiling.
	out=$(docker run --rm "$SMOKE_CURL_IMAGE" \
		-s -o /dev/null -w '%{http_code} %{time_total}' \
		"$SMOKE_URL" 2>/dev/null)
	rc=$?

	if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
		errors=$((errors + 1))
		echo "sample ${i}/${SAMPLES}: transport failure (curl exit ${rc})"
		continue
	fi

	code=${out%% *}
	seconds=${out##* }
	ms=$(awk -v s="$seconds" 'BEGIN { printf "%d", (s * 1000) + 0.5 }')

	case "$code" in
	[23]*)
		;;
	*)
		errors=$((errors + 1))
		echo "sample ${i}/${SAMPLES}: HTTP ${code}"
		;;
	esac

	if [ "$ms" -gt "$worst_ms" ]; then
		worst_ms=$ms
	fi
	if [ "$ms" -gt "$LATENCY_MS" ]; then
		slow=$((slow + 1))
		echo "sample ${i}/${SAMPLES}: ${ms}ms over the ${LATENCY_MS}ms ceiling"
	fi
done

echo "smoke: ${SAMPLES} samples, errors=${errors}, slow=${slow}, worst=${worst_ms}ms"

if [ "$errors" -gt 0 ]; then
	echo "smoke: FAILED -- the error budget is zero and ${errors} sample(s) failed"
	exit 1
fi

if [ "$slow" -gt 0 ]; then
	echo "smoke: FAILED -- ${slow} sample(s) exceeded the ${LATENCY_MS}ms latency ceiling"
	exit 1
fi

echo "smoke: PASSED"
