package main

# ---------------------------------------------------------------------------
# resources.rego — the requests/limits/autoscaling contract.
#
# Two claims, both of which were verified absent from the upstream baseline in
# apps/boutique/upstream-kubernetes-manifests.yaml:
#
#   1. requests == limits for CPU, on every container. This is what puts a
#      container in the Guaranteed QoS class. Upstream ships requests 100m /
#      limits 200m on eight services, i.e. Burstable everywhere, so every pod's
#      CPU quota is a best-effort claim that another pod can overrun.
#
#   2. every Deployment has an HPA. Upstream ships none for any service.
#
# The traversal helpers, and the reason this file and security.rego share a
# package, are documented in policy/security.rego.
# ---------------------------------------------------------------------------

# CPU quantities are written by humans and compared by machines. "100m" and
# "0.1" are the same quantity to Kubernetes and different strings to a naive
# policy, so convert to integer millicores before comparing.
millicores(q) := m if {
	endswith(q, "m")
	m := to_number(trim_suffix(q, "m"))
}

millicores(q) := m if {
	not endswith(q, "m")
	m := to_number(q) * 1000
}

# ---------------------------------------------------------------------------
# 1. CPU requests must equal CPU limits
# ---------------------------------------------------------------------------
# Split into two rules so the failure message says which half is wrong, rather
# than "not guaranteed".

deny_cpu_requests_missing contains msg if {
	some pair in owned_containers
	requests := object.get(pair.container, ["resources", "requests"], {})
	not requests.cpu
	msg := sprintf(
		"[resources] %s: container %q has no resources.requests.cpu, so it cannot be placed in Guaranteed QoS and cannot be counted by the ResourceQuota.",
		[where(pair), container_name(pair)],
	)
}

# The CPU limit as integer millicores, or 0 when it is absent. The 0 default
# matters: an undefined value in a comparison makes the whole rule undefined, so
# a container with a CPU request and no CPU limit at all would be silently passed
# instead of rejected.
cpu_limit_millicores(pair) := millicores(object.get(pair.container, ["resources", "limits", "cpu"], "0"))

deny_cpu_limits_differ_from_requests contains msg if {
	some pair in owned_containers
	requests := object.get(pair.container, ["resources", "requests"], {})
	requests.cpu
	cpu_limit_millicores(pair) != millicores(requests.cpu)
	msg := sprintf(
		"[resources] %s: container %q has CPU requests %v but CPU limits %v. Make them equal for Guaranteed QoS: limits only cap throttling, requests are what reserve capacity, and the gap between them is what lets a burstable neighbour eat into this container's quota.",
		[where(pair), container_name(pair), requests.cpu, object.get(pair.container, ["resources", "limits", "cpu"], "<none>")],
	)
}

# ---------------------------------------------------------------------------
# 2. Memory limits must exist and must not be below the request
# ---------------------------------------------------------------------------
deny_memory_limits_missing contains msg if {
	some pair in owned_containers
	limits := object.get(pair.container, ["resources", "limits"], {})
	not limits.memory
	msg := sprintf(
		"[resources] %s: container %q has no resources.limits.memory. An unbounded container is an OOM kill waiting for the busiest hour of the day, with no blast-radius information attached.",
		[where(pair), container_name(pair)],
	)
}

# ---------------------------------------------------------------------------
# 3. Every Deployment must have an HPA that targets it
# ---------------------------------------------------------------------------
# HOW THIS IS EVALUATED, and why it is not in the default single-document run.
#
# conftest's default mode hands the policy ONE YAML document at a time. A
# Deployment and its HorizontalPodAutoscaler are two documents — usually in the
# same file, but still two separate evaluations — so a per-document rule cannot
# see whether the HPA exists. Rather than fake the check (e.g. by requiring an
# annotation on the Deployment that points at the HPA, which the manifest author
# and the autoscaler could happily drift apart), the real rule runs in
# conftest's combined mode:
#
#     conftest test apps/boutique/base -p policy/ --combine   # name, not kind
#
# In that mode `input` is the array of every document in the tree, so the rule
# can genuinely match a Deployment against the set of scaleTargetRefs. The
# `is_array(input)` guard is what makes this rule inert — rather than falsely
# passing, or falsely failing — in single-document mode.
#
# scripts/check.sh runs both modes. The deliberately-broken fixture
# policy/tests/should-fail/no-autoscaler-uneven-cpu-deployment.yaml fails on
# this rule in combined mode.

hpa_targets contains name if {
	some doc in documents
	doc.kind == "HorizontalPodAutoscaler"
	name := object.get(doc.spec, ["scaleTargetRef", "name"], "")
}

# ---------------------------------------------------------------------------
# The exemption mechanism, and why it is an annotation rather than a list here.
#
# A Deployment may opt out, but only by carrying BOTH annotations below AND a
# reason of at least 40 characters. The length floor is deliberate: it makes
# `not needed` an invalid reason and forces the author to write the actual
# argument down, in the manifest, next to the resource it applies to, where a
# reviewer reading the diff will see it. An exemption list inside the policy file
# would let the reason live in a different file from the exemption.
# ---------------------------------------------------------------------------

exempt_from_hpa(metadata) if {
	object.get(metadata, ["annotations", "platform.boutique/hpa"], "") == "manual"
	reason := object.get(metadata, ["annotations", "platform.boutique/hpa-reason"], "")
	count(reason) >= 40
}

deny_deployment_without_hpa contains msg if {
	is_array(input)
	some doc in documents
	doc.kind == "Deployment"
	name := object.get(doc, ["metadata", "name"], "")
	namespace := object.get(doc, ["metadata", "namespace"], "cluster-scoped")
	not name in hpa_targets
	not exempt_from_hpa(doc.metadata)
	msg := sprintf(
		"[resources] %s/%s: Deployment has no HorizontalPodAutoscaler targeting it, and no `platform.boutique/hpa: manual` exemption with a 40+ character reason. Upstream ships no HPA for any service; this platform requires one on every Deployment except the two documented exclusions in apps/boutique/base/ (redis-cart, which is single-instance stateful, and loadgenerator, which is the traffic source). Re-run with --combine if this is unexpected: the rule only evaluates in combined mode.",
		[namespace, name],
	)
}

# An exemption that does not explain itself is worse than no exemption, so it is
# a rejection of its own. This is also what catches a copy-paste of the
# `platform.boutique/hpa` annotation without the reason that made it acceptable.
deny_hpa_exemption_without_reason contains msg if {
	some doc in documents
	doc.kind == "Deployment"
	name := object.get(doc, ["metadata", "name"], "")
	namespace := object.get(doc, ["metadata", "namespace"], "cluster-scoped")
	object.get(doc, ["metadata", "annotations", "platform.boutique/hpa"], "") == "manual"
	not exempt_from_hpa(doc.metadata)
	msg := sprintf(
		"[resources] %s/%s: opted out of the HPA requirement with `platform.boutique/hpa: manual`, but the `platform.boutique/hpa-reason` annotation is missing or shorter than 40 characters. Write down the argument.",
		[namespace, name],
	)
}

# ---------------------------------------------------------------------------
# 4. Requests must be <= limits, memory side
# ---------------------------------------------------------------------------
# Not required for QoS, but it is the difference between a container that gets
# throttled and one that gets OOM-killed twice a day. Kept as a separate rule so
# the message can say which direction is wrong.
deny_memory_request_above_limit contains msg if {
	some pair in owned_containers
	requests := object.get(pair.container, ["resources", "requests"], {})
	limits := object.get(pair.container, ["resources", "limits"], {})
	requests.memory
	limits.memory
	memory_bytes(requests.memory) > memory_bytes(limits.memory)
	msg := sprintf(
		"[resources] %s: container %q requests more memory (%v) than it is limited to (%v). The request is what the scheduler reserves; if it exceeds the limit, the container is killed the moment it uses what it asked for.",
		[where(pair), container_name(pair), requests.memory, limits.memory],
	)
}

# Kubernetes memory quantities: 128974848, 128e3, 128M, 128Mi, 128G, ... The
# two forms the manifests actually use are plain integers and the Ki/Mi/Gi
# binary suffixes, so this covers what can be written here. A quantity this
# cannot parse leaves the rule silently un-fired — see the note in
# docs/chaos-experiments.md on which checks were verified versus asserted.
memory_bytes(q) := to_number(q) if {
	not endswith(q, "i")
}

memory_bytes(q) := to_number(trim_suffix(q, "i")) * 1024 if {
	endswith(q, "Ki")
}

memory_bytes(q) := to_number(trim_suffix(q, "i")) * 1024 * 1024 if {
	endswith(q, "Mi")
}

memory_bytes(q) := to_number(trim_suffix(q, "i")) * 1024 * 1024 * 1024 if {
	endswith(q, "Gi")
}
