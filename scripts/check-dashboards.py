#!/usr/bin/env python3
"""Check that every Grafana dashboard ConfigMap's JSON actually parses.

Grafana silently ignores a dashboard whose JSON does not parse, and the sidecar
does not report it. This script is the difference between "four dashboards are
provisioned" and "four files exist".

Usage:
    scripts/check-dashboards.py FILE_OR_DIR...

A file is checked if it is a YAML (or JSON) Kubernetes manifest of
kind: ConfigMap whose data values parse as JSON. Non-manifest files are ignored.
Exits 1 on the first unparseable value.
"""

from __future__ import annotations

import json
import os
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("check-dashboards.py needs PyYAML")


def iter_files(paths):
    for path in paths:
        if os.path.isdir(path):
            for root, _dirs, files in os.walk(path):
                for name in sorted(files):
                    if name.endswith((".yaml", ".yml", ".json")):
                        yield os.path.join(root, name)
        else:
            yield path


def main() -> int:
    checked = 0
    failures = []
    for path in iter_files(sys.argv[1:] or ["."]):
        try:
            with open(path, encoding="utf-8") as handle:
                docs = list(yaml.safe_load_all(handle))
        except (yaml.YAMLError, OSError) as exc:
            failures.append(f"{path}: {exc}")
            continue
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
                continue
            data = doc.get("data") or {}
            if not data:
                continue
            name = (doc.get("metadata") or {}).get("name", "<unnamed>")
            for key, value in data.items():
                if not isinstance(value, str) or "{" not in value[:4]:
                    continue
                try:
                    json.loads(value)
                except json.JSONDecodeError as exc:
                    failures.append(f"{path}: {name}/{key}: {exc}")
                else:
                    checked += 1
    if failures:
        for failure in failures:
            print(f"!! {failure}", file=sys.stderr)
        return 1
    print(f"ok: {checked} dashboard JSON document(s) parse")
    return 0


if __name__ == "__main__":
    sys.exit(main())
