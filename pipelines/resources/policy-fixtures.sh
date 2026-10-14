#!/bin/sh
# The policy fixtures that must be REJECTED, run as a gate.
#
# Why this file exists instead of a one-liner in the Jenkinsfile: conftest's
# own image has no shell entrypoint, the loop needs a shell, and the two facts
# together mean the loop has to live in a file that `sh -c` can execute. The
# same reason sends every other piece of pipeline shell here -- see
# pipelines/resources/smoke.sh.
#
# Exit status: 0 only when every fixture in policy/tests/should-fail was
# rejected (conftest exit 1). Anything else -- a fixture that passed, a conftest
# crash, an empty fixture directory -- is a failure. A policy suite where the
# negative cases stopped failing looks identical to one where they never
# existed, which is exactly how a deny rule is quietly deleted and nobody
# notices: the dashboard stays green because the only thing being measured is
# whether the policy agrees with itself.
#
# POSIX sh on purpose: the alpine-based conftest image runs this, and bashisms
# would fail there with a message that reads like a conftest bug.

set -u

root="${1:-.}"
policy="${root}/policy"
fixtures="${root}/policy/tests/should-fail"
listing="${TMPDIR:-/tmp}/policy-fixtures.$$"

# SC2329: shellcheck does not follow `trap cleanup EXIT`, which is the only
# place this runs. Same suppression scripts/doctor.sh uses.
# shellcheck disable=SC2329
cleanup() { rm -f "$listing"; }
trap cleanup EXIT

if [ ! -d "$fixtures" ]; then
    echo "policy-fixtures: no fixture directory at $fixtures" >&2
    exit 1
fi

# A directory with no fixtures is not a passing suite, it is a missing one.
find "$fixtures" -name '*.yaml' -print | sort > "$listing" || exit 1
if [ ! -s "$listing" ]; then
    echo "policy-fixtures: no *.yaml fixtures under $fixtures" >&2
    exit 1
fi

status=0
# Reading from a file rather than a pipe keeps this loop in the current shell,
# so `status` survives it -- the subshell a pipe would create would discard
# every failure below.
while IFS= read -r f; do
    out="$(conftest test "$f" -p "$policy" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 1 ]; then
        printf 'rejects: %s\n' "$f"
    else
        printf 'NOT REJECTED: %s (conftest exit %s)\n' "$f" "$rc"
        printf '%s\n' "$out"
        status=1
    fi
done < "$listing"

exit "$status"
