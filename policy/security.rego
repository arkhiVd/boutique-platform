package main

# ---------------------------------------------------------------------------
# security.rego — the container hardening contract for this platform.
#
# This is the CI-side twin of the Pod Security Admission `restricted` label on
# apps/boutique/namespace.yaml. Admission enforces it at apply time; this file
# enforces it at review time, which is the only place a portfolio repo can
# actually show the rejection. Both directions matter: a policy nobody reads is
# decoration, and a manifest that only ever gets checked by a cluster it is
# already deployed into is a surprise.
#
# Every control here was verified ABSENT from the vendored upstream baseline in
# apps/boutique/upstream-kubernetes-manifests.yaml, and every one is present in
# apps/boutique/base/. `scripts/check.sh` runs both the passing and the
# deliberately-failing sets; the fixtures in policy/tests/should-fail/ are the
# receipts.
#
# Note on evaluation shape: `documents` below normalises the two ways conftest
# hands us input. By default `input` is ONE document; with `--combine` it is an
# array of every document. Both work, which is what lets resources.rego check a
# Deployment against its HPA without them being in the same document.
# ---------------------------------------------------------------------------

documents contains doc if {
	not is_array(input)
	doc := input
}

# conftest's `--combine` mode does not hand the policy an array of bare
# documents. It hands it an array of `{path: <file>, contents: <document>}`
# wrappers, one per document (verified: 57 wrappers for 57 documents). Without
# unwrapping, every rule below becomes a silent no-op in combined mode and the
# cross-document checks in resources.rego pass by doing nothing — which is the
# worst possible failure mode for a policy. The default keeps the second
# definition working if a future conftest passes bare documents.
documents contains doc if {
	is_array(input)
	wrapper := input[_]
	object.get(wrapper, "contents", null) == null
	doc := wrapper
}

documents contains doc if {
	is_array(input)
	wrapper := input[_]
	object.get(wrapper, "contents", null) != null
	doc := object.get(wrapper, "contents", null)
}

# ---------------------------------------------------------------------------
# Object traversal helpers
# ---------------------------------------------------------------------------

# A workload is a Pod, or any object with spec.template.spec.containers — that
# covers Deployment, StatefulSet, DaemonSet, ReplicaSet and Job. Anything else
# (a Service, a ServiceAccount, a NetworkPolicy, a Namespace, a ResourceQuota,
# a LimitRange, a PriorityClass) has no pod spec, so these rules simply do not
# fire on it rather than erroring.
pod_spec_of(doc) := doc.spec if {
	doc.kind == "Pod"
}

pod_spec_of(doc) := doc.spec.template.spec if {
	doc.kind != "Pod"
	doc.spec.template.spec
}

workloads contains workload if {
	some doc in documents
	pod_spec_of(doc)
	workload := {
		"kind": doc.kind,
		"name": object.get(doc, ["metadata", "name"], "<unnamed>"),
		"namespace": object.get(doc, ["metadata", "namespace"], "cluster-scoped"),
		"spec": pod_spec_of(doc),
	}
}

# Container groups, in the order the API validates them.
container_groups := ["initContainers", "containers", "ephemeralContainers"]

owned_containers contains pair if {
	some workload in workloads
	some group in container_groups
	some container in object.get(workload.spec, group, [])
	pair := {
		"owner": workload,
		"container": container,
		"group": group,
	}
}

container_name(pair) := object.get(pair.container, "name", "<unnamed>")

where(pair) := sprintf("%s/%s (%s)", [pair.owner.namespace, pair.owner.name, pair.owner.kind])

# Container securityContext wins over pod securityContext where both set the
# field; that is the Kubernetes merge order, and getting it wrong here would
# reject manifests that the API server accepts.
sc_value(pair, field) := object.get(
	pair.container, ["securityContext", field],
	object.get(pair.owner.spec, ["securityContext", field], null),
)

# ---------------------------------------------------------------------------
# 9. automountServiceAccountToken must be disabled
# ---------------------------------------------------------------------------
# A projected service-account token inside a pod is a bearer credential. In a
# namespace where nothing calls the Kubernetes API — which is this one, and most
# application namespaces — the token is an attack surface with no consumer. It
# can also be revoked at the ServiceAccount level, which is what
# apps/boutique/base/ does, but a manifest that sets the pod-level flag does not
# depend on the ServiceAccount being configured correctly.
deny_service_account_token_mounted contains msg if {
	some workload in workloads
	object.get(workload.spec, "automountServiceAccountToken", null) != false
	msg := sprintf(
		"[security] %s: pod spec sets automountServiceAccountToken to something other than false. Nothing in this namespace calls the Kubernetes API, so the projected token is a credential with no consumer. Upstream omits this flag on all 13 of its workloads.",
		[where({"owner": workload})],
	)
}

# ---------------------------------------------------------------------------
# 10. every pod must reference a ServiceAccount other than `default`
# ---------------------------------------------------------------------------
# `default` is the namespace's shared identity. Once two workloads share it, RBAC
# written for one of them applies to both by accident. Upstream leaves redis-cart
# on `default` because it is the only workload with no ServiceAccount of its own.
deny_default_service_account contains msg if {
	some workload in workloads
	service_account_name := object.get(workload.spec, "serviceAccountName", "default")
	service_account_name == "default"
	msg := sprintf(
		"[security] %s: pod spec uses the namespace's `default` ServiceAccount. Give it a dedicated one (see apps/boutique/base/redis-cart.yaml, which is the one upstream workload that had none).",
		[where({"owner": workload})],
	)
}

# ---------------------------------------------------------------------------
# 1. readOnlyRootFilesystem
# ---------------------------------------------------------------------------
deny_readonly_root_filesystem contains msg if {
	some pair in owned_containers
	sc_value(pair, "readOnlyRootFilesystem") != true
	msg := sprintf(
		"[security] %s: container %q has securityContext.readOnlyRootFilesystem != true. A writable root filesystem is a writable /tmp, /etc and /var for anything that gets code execution in this pod.",
		[where(pair), container_name(pair)],
	)
}

# ---------------------------------------------------------------------------
# 2. runAsNonRoot
# ---------------------------------------------------------------------------
deny_run_as_non_root contains msg if {
	some pair in owned_containers
	sc_value(pair, "runAsNonRoot") != true
	msg := sprintf(
		"[security] %s: container %q does not run as a non-root user. Set runAsNonRoot: true at container or pod level; the API server accepts either, this policy checks the merge.",
		[where(pair), container_name(pair)],
	)
}

# ---------------------------------------------------------------------------
# 3. allowPrivilegeEscalation
# ---------------------------------------------------------------------------
deny_privilege_escalation contains msg if {
	some pair in owned_containers
	object.get(pair.container, ["securityContext", "allowPrivilegeEscalation"], null) != false
	msg := sprintf(
		"[security] %s: container %q has securityContext.allowPrivilegeEscalation != false. Without this, a setuid binary in the image can regain the root the drop already took away.",
		[where(pair), container_name(pair)],
	)
}

# ---------------------------------------------------------------------------
# 4. capabilities: drop ALL
# ---------------------------------------------------------------------------
deny_capabilities_not_dropped contains msg if {
	some pair in owned_containers
	dropped := object.get(pair.container, ["securityContext", "capabilities", "drop"], [])
	not "ALL" in dropped
	msg := sprintf(
		"[security] %s: container %q does not drop ALL capabilities. Either capabilities.drop is missing, or it names a subset instead of the whole set.",
		[where(pair), container_name(pair)],
	)
}

# ---------------------------------------------------------------------------
# 5. privileged
# ---------------------------------------------------------------------------
deny_privileged contains msg if {
	some pair in owned_containers
	object.get(pair.container, ["securityContext", "privileged"], false) == true
	msg := sprintf(
		"[security] %s: container %q has securityContext.privileged: true. This is root on the host with every capability, and it is unrestricted access to the kubelet socket.",
		[where(pair), container_name(pair)],
	)
}

# ---------------------------------------------------------------------------
# 6. host namespaces
# ---------------------------------------------------------------------------
deny_host_namespaces contains msg if {
	some workload in workloads
	some field in ["hostNetwork", "hostPID", "hostIPC"]
	object.get(workload.spec, field, false) == true
	msg := sprintf(
		"[security] %s: pod spec sets %s: true. Sharing a host namespace gives the pod visibility of every process or interface on that node, not just its own.",
		[where({"owner": workload}), field],
	)
}

# ---------------------------------------------------------------------------
# 7. seccompProfile == RuntimeDefault
# ---------------------------------------------------------------------------
deny_seccomp_profile contains msg if {
	some pair in owned_containers
	sc_value(pair, "seccompProfile") == null
	msg := sprintf(
		"[security] %s: container %q has no seccompProfile.type. Unconfined seccomp means the full syscall surface of the kernel is reachable; set seccompProfile.type: RuntimeDefault at pod or container level (this is the one control upstream omits on all 13 of its workloads).",
		[where(pair), container_name(pair)],
	)
}

deny_seccomp_profile contains msg if {
	some pair in owned_containers
	profile := sc_value(pair, "seccompProfile")
	profile != null
	object.get(profile, "type", null) != "RuntimeDefault"
	msg := sprintf(
		"[security] %s: container %q has seccompProfile.type != RuntimeDefault.",
		[where(pair), container_name(pair)],
	)
}

# ---------------------------------------------------------------------------
# 8. resource requests must exist
# ---------------------------------------------------------------------------
# The scheduler is a scheduler *given requests*. A container with none is
# admitted with no reservation, so under pressure it is the first thing the
# kubelet kills and the last thing a ResourceQuota can see.
deny_missing_resource_requests contains msg if {
	some pair in owned_containers
	resources := object.get(pair.container, "resources", {})
	requests := object.get(resources, "requests", {})
	not requests.cpu
	msg := sprintf(
		"[security] %s: container %q has no resources.requests.cpu. Without a CPU request the scheduler has nothing to place it against and the ResourceQuota cannot count it.",
		[where(pair), container_name(pair)],
	)
}

deny_missing_resource_requests contains msg if {
	some pair in owned_containers
	resources := object.get(pair.container, "resources", {})
	requests := object.get(resources, "requests", {})
	not requests.memory
	msg := sprintf(
		"[security] %s: container %q has no resources.requests.memory. Memory is the resource that OOM-kills; a container without a request is invisible to eviction ordering and to the quota.",
		[where(pair), container_name(pair)],
	)
}
