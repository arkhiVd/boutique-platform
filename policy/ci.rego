package main

# ---------------------------------------------------------------------------
# ci.rego — namespace-aware enforcement profiles.
#
# policy/security.rego and policy/resources.rego enforce one contract: the
# `restricted` Pod Security profile plus Guaranteed-QoS requests. That contract
# is what apps/boutique/namespace.yaml is labelled with, and weakening it to
# make a Helm chart pass would be the whole exercise backwards — the policy
# exists to reject what the chart ships by default.
#
# The platform's own infrastructure namespaces (`ci`, `observability`) instead
# run charts whose container-level defaults we can override but whose topology
# we cannot: the Jenkins controller is a single StatefulSet that must call the
# Kubernetes API to build agent pods, and it must be allowed to burst on the
# node it shares. Those two namespaces get a documented `baseline` profile. Two
# rules are gated on the profile — no more:
#
#   policy/security.rego   deny_service_account_token_mounted    (rule 9)
#   policy/resources.rego  deny_cpu_limits_differ_from_requests  (rule 1)
#
# Everything else — privileged, host namespaces, capabilities, seccomp,
# readOnlyRootFilesystem, runAsNonRoot, allowPrivilegeEscalation, the default
# ServiceAccount, missing requests/limits — applies identically in both
# profiles, and is what the rendered ci/jenkins chart is checked against
# (see ci/jenkins/README.md for that run).
#
# Profile selection is by `metadata.namespace` on the workload, defaulting to
# `restricted`: a manifest that declares no namespace is cluster-scoped and
# gets no leniency, and a typo'd namespace falls on the strict side too,
# because `profile_for("ci2")` is `restricted`.
# ---------------------------------------------------------------------------

# Namespaces that hold platform infrastructure rendered from Helm charts
# rather than hand-written application workloads.
baseline_namespaces := {"ci", "observability"}

profile_for(ns) := "baseline" if {
	baseline_namespaces[ns]
}

profile_for(ns) := "restricted" if {
	not baseline_namespaces[ns]
}

# ---------------------------------------------------------------------------
# Justification for each baseline exception
# ---------------------------------------------------------------------------

# 1. deny_service_account_token_mounted (ci only)
#
# The Jenkins k8s plugin builds agent pods from inside the controller pod. It
# authenticates to the API server with the projected token of its own
# ServiceAccount — no token, no agents: the pod would come up and then fail
# every create call. The controller's identity is scoped in ci/rbac/, where the
# least-privilege Role is written and reviewed, and ci/jenkins/values.yaml sets
# `jenkins.rbac.create: false` so that single file is the whole story. Every
# other pod in the namespace keeps the rule: ci/backup/cronjob.yaml sets
# `automountServiceAccountToken: false` explicitly because it only reads the
# PVC and talks to S3.
#
# The chart cannot express "pod-level flag false, ServiceAccount-level true" —
# one value drives both — so this is a real exception, not a missing field.

# 2. deny_cpu_limits_differ_from_requests (ci and observability)
#
# Guaranteed QoS costs 2-3x the request of the Burstable shape these charts
# actually need, and the ci ResourceQuota (2000m/8Gi requested) has to hold the
# controller plus up to 8 concurrent agent pods: raising the controller alone
# from 120m requested to its 750m limit is 630m that no agent pod can have.
# Burstable with an enforced limit is the correct trade here — the limit is
# what stops a runaway build from taking the node, which is the property the
# rule is really after; the rule's own text argues for Guaranteed QoS, and the
# arithmetic above is why this namespace declines it. observability carries the
# same profile for symmetry: both are chart-rendered infrastructure, and
# neither is an application workload the PSA `restricted` label is about.
#
# Resource requests and limits still have to exist on every container (rules 3
# and 4 below, ungated), so a missing budget fails in both profiles.
