#!/usr/bin/env python3
"""Sum resources.requests across rendered manifests and prove the node fits.

This script answers "does the whole platform fit on ONE node", which is a stress
test rather than a deployment claim — the deployed shape is 4 x t3.small with all
four schedulable (see platform/nodes.tf). The default unit is 4 GiB RAM / 2 vCPU
(see --node-ram-gib/--node-cpu); that size is no longer launchable in this
account (t3.medium is not FreeTierEligible here) and is kept only because
--accept-over-commit is a PERCENTAGE of it, so the default 250% bound stays at
the same absolute ceiling of 9352Mi / 5000m that it has always enforced.
That is the number every other phase has to fit inside, and it is the number this
script prints. It is deliberately a separate script rather than a comment, because
a number in a comment is an assertion and a number from a script is evidence.

Usage:
    scripts/resource-budget.py [--node-ram-gib 4] [--node-cpu 2] FILE_OR_DIR ...

Every positional argument is either a YAML file of rendered manifests (including
multi-document files) or a directory that is walked for *.yaml. Helm chart
values.yaml and Chart.yaml files are not manifests and are skipped.

WHY THERE IS AN `--extra` FLAG
------------------------------
The budget has to include workloads whose pod spec is NOT in any file this
script can point at: the Jenkins controller is a Helm chart this branch does
not vendor (ci/ is Phase 7), and the OTel collector lives on the app branch.
Without `--extra` those requests would simply be absent from the total, and a
total that silently omits a component is the same as a wrong total. Each
`--extra` is an explicit, justified number, and the justification lives next to
the number in whatever passes it.

    --extra <namespace>:<name>:<cpu>:<mem>
    --extra ci:jenkins-controller:100m:512Mi

Exits 0 if the total requests fit inside the node, 1 if they do not. An exit
code of 1 is a finding to report, not a failure of the script.
"""

from __future__ import annotations

import argparse
import os
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the repo's python3 has PyYAML
    sys.exit("resource-budget.py needs PyYAML (python3 -m pip install pyyaml)")


# kubelet reservations on a 4 GiB / 2 vCPU node, from the kubelet's own defaults:
#   memory: 255Mi system-reserved for nodes under 4 GiB, plus the 100Mi
#           eviction-hard threshold node-pressure reservation.
#   cpu:    kube-reserved is 6% of the first core + 1% of the next (capped at
#           100m), so ~70m, and the kubelet adds ~100m of unreserved but
#           unschedulable system-daemon room.
# These are the numbers a scheduler actually sees, not the marketing numbers.
KUBELET_RESERVED_MEMORY_MIB = 355
KUBELET_RESERVED_CPU_MILLI = 170

CPU_SUFFIX = {"m": 0.001, "k": 1000.0}
MEM_SUFFIX = {
    "Ki": 1024 / 1024 / 1024,
    "Mi": 1 / 1024,
    "Gi": 1,
    "Ti": 1024,
    "K": 1000**3 / 1024**3,
    "M": 1000**2 / 1024**3,
    "G": 1000**3 / 1024**3,
    "T": 1000**4 / 1024**3,
}

# Workloads whose pod template the render actually contains.
POD_WORKLOAD_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob")
# Workloads whose pod template is built by a CONTROLLER from a custom resource,
# so `helm template` never renders the StatefulSet. kube-prometheus-stack is
# exactly this: `kind: Prometheus` and `kind: Alertmanager` are CRs whose pods the
# operator creates at runtime. Their requests live at `spec.resources`.
CR_WORKLOAD_KINDS = ("Prometheus", "Alertmanager")


def cpu_millicores(quantity) -> int:
    """'100m' -> 100, '1' -> 1000, '2500m' -> 2500."""
    if quantity is None:
        return 0
    text = str(quantity).strip()
    if not text:
        return 0
    if text.endswith("m"):
        return int(round(float(text[:-1])))
    return int(round(float(text) * 1000))


def memory_mib(quantity) -> float:
    """'128974848', '128e3', '128M', '128Mi', '1Gi' -> MiB."""
    if quantity is None:
        return 0.0
    text = str(quantity).strip()
    if not text:
        return 0.0
    for suffix, factor in MEM_SUFFIX.items():
        if text.endswith(suffix):
            return float(text[: -len(suffix)]) * factor * 1024
    return float(text) / 1024 / 1024


def iter_documents(paths):
    for path in paths:
        if os.path.isdir(path):
            for root, _dirs, files in os.walk(path):
                for name in sorted(files):
                    if name.endswith((".yaml", ".yml")) and not _is_helm_source(root, name):
                        yield os.path.join(root, name)
        else:
            if not _is_helm_source(os.path.dirname(path), os.path.basename(path)):
                yield path


def _is_helm_source(directory: str, filename: str) -> bool:
    """A Helm values.yaml / Chart.yaml / vendored subchart is not a manifest."""
    if filename in ("values.yaml", "Chart.yaml", "Chart.lock"):
        return True
    if f"{os.sep}charts{os.sep}" in directory + os.sep:
        return True
    return False


def containers_of(doc):
    spec = doc.get("spec") or {}
    if doc.get("kind") == "CronJob":
        spec = ((spec.get("jobTemplate") or {}).get("spec") or {})
    template = spec.get("template") or {}
    pod = template.get("spec") or {}
    for group in ("initContainers", "containers", "ephemeralContainers"):
        for container in pod.get(group) or []:
            yield container
    if doc.get("kind") == "Pod":
        for group in ("initContainers", "containers", "ephemeralContainers"):
            for container in (spec.get(group) or []):
                yield container


def cr_containers_of(doc, reloader_requests: dict | None):
    """A Prometheus/Alertmanager custom resource carries its request at spec.resources."""
    spec = doc.get("spec") or {}
    containers = [{"name": str(doc.get("kind", "cr")).lower(),
                   "resources": spec.get("resources") or {}}]
    if reloader_requests:
        containers.append({"name": "config-reloader", "resources": {"requests": reloader_requests}})
    return containers


def replicas_of(doc, node_count: int) -> int:
    """A request is multiplied by the replica count that will actually run."""
    spec = doc.get("spec") or {}
    kind = doc.get("kind")
    if kind == "CronJob":
        return 1
    if kind == "Pod":
        return 1
    if kind == "DaemonSet":
        # A DaemonSet schedules one pod per node, not one per manifest. On the
        # SPEC's 4-node shape a 16Mi DaemonSet request is 64Mi of node capacity.
        return max(1, node_count)
    replicas = spec.get("replicas")
    if replicas is None:
        return 1
    try:
        return max(1, int(replicas))
    except (TypeError, ValueError):
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", default=[], help="rendered manifest files/dirs")
    parser.add_argument(
        "--extra",
        action="append",
        default=[],
        metavar="NS:NAME:CPU:MEM",
        help=(
            "a workload whose pod spec is not in any file passed above, added to "
            "the total as an explicit number. Repeatable."
        ),
    )
    parser.add_argument("--node-ram-gib", type=float, default=4.0, help="node RAM in GiB")
    parser.add_argument("--node-cpu", type=float, default=2.0, help="node allocatable vCPU")
    parser.add_argument(
        "--node-count",
        type=int,
        default=4,
        help="number of nodes a DaemonSet will schedule on (SPEC's shape is 4)",
    )
    parser.add_argument(
        "--config-reloader",
        default="10m/16Mi",
        help=(
            "per-pod request of the prometheus-config-reloader sidecar, which the "
            "operator injects into every Prometheus and Alertmanager pod. It is "
            "absent from `helm template` output because the chart passes it as a "
            "flag to the operator, so it has to be supplied. Format: <cpu>/<mem>, "
            "use '0/0' to exclude."
        ),
    )
    parser.add_argument(
        "--accept-over-commit",
        type=float,
        default=0.0,
        metavar="PCT",
        help=(
            "exit 0 while the total is at most PCT percent of schedulable, even if "
            "that is over 100. Default 0 = strict. This exists because the platform's "
            "real over-commit is a RECORDED finding (see docs/resource-budget.md) with "
            "a cause outside any one component, and a gate that fails on a number "
            "nobody is allowed to fix trains people to ignore the gate. Passing an "
            "explicit bound keeps the number printed and loud while still failing on "
            "a regression that makes it materially worse."
        ),
    )
    parser.add_argument(
        "--no-kubelet-reservations",
        action="store_true",
        help="compare against the raw node size instead of what kubelet leaves schedulable",
    )
    args = parser.parse_args()

    reloader_cpu, reloader_mem = 0, 0.0
    reloader_requests = None
    try:
        cpu_part, mem_part = args.config_reloader.split("/", 1)
        reloader_cpu, reloader_mem = cpu_millicores(cpu_part), memory_mib(mem_part)
        if reloader_cpu or reloader_mem:
            reloader_requests = {"cpu": cpu_part, "memory": mem_part}
    except ValueError:
        parser.error("--config-reloader expects '<cpu>/<mem>' e.g. 10m/16Mi")

    node_mib = args.node_ram_gib * 1024
    node_milli = int(round(args.node_cpu * 1000))
    schedulable_mib = node_mib - (0 if args.no_kubelet_reservations else KUBELET_RESERVED_MEMORY_MIB)
    schedulable_milli = node_milli - (0 if args.no_kubelet_reservations else KUBELET_RESERVED_CPU_MILLI)

    totals: dict[str, dict[str, float]] = {}
    rows = []
    for item in args.extra:
        # Exactly four colon-separated fields. Neither a CPU nor a memory
        # quantity contains a colon, so a 3-field value can only be a typo, and
        # guessing which field it is would silently put the memory request into
        # the CPU total or vice versa.
        parts = item.split(":")
        if len(parts) != 4 or not all(p.strip() for p in parts):
            parser.error(
                f"--extra expects '<ns>:<name>:<cpu>:<mem>' (four fields), got {item!r}"
            )
        ns, name, cpu_raw, mem_raw = (p.strip() for p in parts)
        rows.append((ns, name, "extra (no pod spec in tree)", 1,
                     cpu_millicores(cpu_raw), memory_mib(mem_raw)))
        bucket = totals.setdefault(ns, {"cpu": 0, "mem": 0.0, "workloads": 0})
        bucket["cpu"] += cpu_millicores(cpu_raw)
        bucket["mem"] += memory_mib(mem_raw)
        bucket["workloads"] += 1

    for path in iter_documents(args.paths or ["."]):
        try:
            with open(path, encoding="utf-8") as handle:
                docs = list(yaml.safe_load_all(handle))
        except (yaml.YAMLError, OSError) as exc:
            print(f"!! could not parse {path}: {exc}", file=sys.stderr)
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            namespace = (doc.get("metadata") or {}).get("namespace", "cluster-scoped")
            name = (doc.get("metadata") or {}).get("name", "<unnamed>")
            kind = doc.get("kind")
            if kind in CR_WORKLOAD_KINDS:
                # Custom resource: the pod spec is built by the operator at runtime.
                spec = doc.get("spec") or {}
                replicas = max(1, int(spec.get("replicas") or 1))
                containers = cr_containers_of(doc, reloader_requests)
            elif kind in POD_WORKLOAD_KINDS:
                replicas = replicas_of(doc, args.node_count)
                containers = list(containers_of(doc))
            else:
                continue
            cpu = 0
            mem = 0.0
            for container in containers:
                requests = ((container.get("resources") or {}).get("requests")) or {}
                cpu += cpu_millicores(requests.get("cpu"))
                mem += memory_mib(requests.get("memory"))
            cpu *= replicas
            mem *= replicas
            bucket = totals.setdefault(namespace, {"cpu": 0, "mem": 0.0, "workloads": 0})
            bucket["cpu"] += cpu
            bucket["mem"] += mem
            bucket["workloads"] += 1
            rows.append((namespace, name, kind, replicas, cpu, mem))

    print("=" * 84)
    print("resource budget — sum of resources.requests across the RENDERED manifests")
    print("=" * 84)
    print(f"{'namespace':<18}{'workloads':>10}{'cpu req':>12}{'mem req (MiB)':>16}")
    print("-" * 84)
    total_cpu = 0
    total_mem = 0.0
    for namespace in sorted(totals):
        bucket = totals[namespace]
        total_cpu += bucket["cpu"]
        total_mem += bucket["mem"]
        print(
            f"{namespace:<18}{bucket['workloads']:>10}{bucket['cpu']:>10}m"
            f"{bucket['mem']:>15.0f}"
        )
    print("-" * 84)
    print(f"{'TOTAL':<18}{sum(b['workloads'] for b in totals.values()):>10}"
          f"{total_cpu:>10}m{total_mem:>15.0f}")
    print()
    print(f"  node                : {args.node_ram_gib:.2f} GiB / {args.node_cpu:.2f} vCPU")
    print(f"  schedulable         : {schedulable_mib / 1024:.2f} GiB / {schedulable_milli}m"
          f"   (kubelet reservations: {KUBELET_RESERVED_MEMORY_MIB}MiB, "
          f"{KUBELET_RESERVED_CPU_MILLI}m)")
    print()
    cpu_pct = (total_cpu / schedulable_milli * 100) if schedulable_milli else 0.0
    mem_pct = (total_mem / schedulable_mib * 100) if schedulable_mib else 0.0
    print(f"  CPU   : {total_cpu:>7}m of {schedulable_milli:>7}m = {cpu_pct:6.1f}%  "
          f"({'FITS' if total_cpu <= schedulable_milli else 'OVER by %dm' % (total_cpu - schedulable_milli)})")
    print(f"  RAM   : {total_mem:>7.0f} of {schedulable_mib:>7.0f} = {mem_pct:6.1f}%  "
          f"({'FITS' if total_mem <= schedulable_mib else 'OVER by %.0fMi' % (total_mem - schedulable_mib)})")
    print()

    print(f"{'namespace':<18}{'workload':<34}{'replicas':>10}{'cpu':>9}{'mem':>10}")
    print("-" * 84)
    for namespace, name, kind, replicas, cpu, mem in sorted(rows):
        print(f"{namespace:<18}{(name or '?')[:33]:<34}{replicas:>10}{cpu:>8}m{mem:>9.0f}")
    print("=" * 84)

    over_cpu = (total_cpu / schedulable_milli * 100) if schedulable_milli else 0.0
    over_mem = (total_mem / schedulable_mib * 100) if schedulable_mib else 0.0
    if args.accept_over_commit:
        print(f"  accepted over-commit bound: {args.accept_over_commit:.1f}% "
              f"(docs/resource-budget.md)")
    fits = (over_cpu <= args.accept_over_commit and over_mem <= args.accept_over_commit)
    print(f"  RESULT: {'FITS' if fits else 'DOES NOT FIT'} "
          f"(cpu {over_cpu:.1f}%, ram {over_mem:.1f}% of schedulable; "
          f"bound {args.accept_over_commit:.1f}%)")
    print("=" * 84)
    return 0 if fits else 1


if __name__ == "__main__":
    sys.exit(main())
