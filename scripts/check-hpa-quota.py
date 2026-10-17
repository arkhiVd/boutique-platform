#!/usr/bin/env python3
"""Prove every HPA in a namespace can reach maxReplicas inside its ResourceQuota.

An HPA whose ceiling the quota cannot hold is a silent lie: the controller asks
for the replica, the ReplicaSet's create fails with `exceeded quota`, and the
only trace is an event nobody reads. Found live on 2026-10-17 — the boutique
HPAs summed to 6470m of CPU requests against a 3000m quota, so most of them
could never scale past their floor.

Reads a rendered manifest stream (`kubectl kustomize apps/boutique`) on stdin or
from a path, and for every quota'd resource sums each workload at the replica
count it can reach: maxReplicas for an HPA target, spec.replicas otherwise.
Per-pod figures follow the quota's own accounting: the larger of the sum of
the app containers and the largest single init container.

Exit 0 when every resource fits, 1 when any does not, 2 on unusable input.
"""

import argparse
import sys

import yaml

RESOURCES = ("requests.cpu", "requests.memory", "limits.cpu", "limits.memory")


def parse_cpu(q):
    q = str(q)
    return float(q[:-1]) if q.endswith("m") else float(q) * 1000


def parse_mem(q):
    q = str(q)
    units = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024,
             "k": 1000 / 1048576, "M": 1e6 / 1048576, "G": 1e9 / 1048576}
    for suffix in sorted(units, key=len, reverse=True):
        if q.endswith(suffix):
            return float(q[: -len(suffix)]) * units[suffix]
    return float(q) / 1048576


def parse(resource, q):
    return parse_cpu(q) if resource.endswith("cpu") else parse_mem(q)


def container_value(container, resource):
    kind, name = resource.split(".")
    value = container.get("resources", {}).get(kind, {}).get(name)
    if value is None:
        raise ValueError(f"container {container.get('name')!r} sets no {resource}")
    return parse(resource, value)


def pod_value(pod_spec, resource):
    app = sum(container_value(c, resource) for c in pod_spec.get("containers", []))
    init = max((container_value(c, resource) for c in pod_spec.get("initContainers", [])), default=0)
    return max(app, init)


def fmt(resource, value):
    return f"{value:.0f}m" if resource.endswith("cpu") else f"{value:.0f}Mi"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("manifest", nargs="?", help="rendered YAML stream (default: stdin)")
    ap.add_argument("--namespace", default="boutique")
    args = ap.parse_args()

    stream = open(args.manifest) if args.manifest else sys.stdin
    docs = [d for d in yaml.safe_load_all(stream) if d]
    ns = args.namespace
    in_ns = [d for d in docs if d.get("metadata", {}).get("namespace", ns) == ns]

    quotas = [d for d in in_ns if d.get("kind") == "ResourceQuota"]
    if len(quotas) != 1:
        print(f"error: expected exactly one ResourceQuota in {ns}, found {len(quotas)}", file=sys.stderr)
        return 2
    hard = quotas[0]["spec"]["hard"]

    hpa_max = {}
    for d in in_ns:
        if d.get("kind") == "HorizontalPodAutoscaler":
            spec = d["spec"]
            if spec["minReplicas"] > spec["maxReplicas"]:
                print(f"FAIL: HPA {d['metadata']['name']}: minReplicas > maxReplicas")
                return 1
            hpa_max[spec["scaleTargetRef"]["name"]] = spec["maxReplicas"]

    workloads = [d for d in in_ns if d.get("kind") in ("Deployment", "StatefulSet")]
    if not workloads:
        print(f"error: no Deployment or StatefulSet in {ns}", file=sys.stderr)
        return 2

    rows = []
    totals = {r: 0.0 for r in RESOURCES}
    pods = 0
    for w in sorted(workloads, key=lambda d: d["metadata"]["name"]):
        name = w["metadata"]["name"]
        floor = w["spec"].get("replicas", 1)
        ceiling = hpa_max.get(name, floor)
        spec = w["spec"]["template"]["spec"]
        try:
            per_pod = {r: pod_value(spec, r) for r in RESOURCES}
        except ValueError as exc:
            print(f"error: {w['kind']} {name}: {exc}", file=sys.stderr)
            return 2
        for r in RESOURCES:
            totals[r] += per_pod[r] * ceiling
        pods += ceiling
        rows.append((name, floor, ceiling, per_pod))

    print(f"{'workload':24}{'min':>4}{'max':>4}  {'req.cpu':>8}{'req.mem':>9}{'lim.cpu':>9}{'lim.mem':>9}")
    for name, floor, ceiling, p in rows:
        print(f"{name:24}{floor:>4}{ceiling:>4}  "
              + "".join(f"{fmt(r, p[r]):>9}" if i else f"{fmt(r, p[r]):>8}" for i, r in enumerate(RESOURCES)))

    failed = False
    print(f"\nat every HPA's maxReplicas, namespace {ns}:")
    for r in RESOURCES:
        if r not in hard:
            continue
        cap = parse(r, hard[r])
        ok = totals[r] <= cap
        failed |= not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {r:16} {fmt(r, totals[r]):>8} of {fmt(r, cap):>8}  ({100 * totals[r] / cap:.0f}%)")
    if "pods" in hard:
        ok = pods <= int(hard["pods"])
        failed |= not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {'pods':16} {pods:>8} of {int(hard['pods']):>8}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
