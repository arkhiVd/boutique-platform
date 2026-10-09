#!/usr/bin/env python3
"""Validate a RENDERED Fluent Bit config against the plugin's own property lists.

WHAT THIS IS FOR, AND WHY IT IS NOT EITHER OF THE EXISTING GATES
---------------------------------------------------------------
`helm lint --strict` and `helm template` both render this chart happily with a
Fluent Bit configuration that CANNOT START. Three distinct fatal errors were
found in it, all of which passed both gates:

  1. `Format none` in a [PARSER] block          -> "Invalid format none"
  2. `(?<message>(?s:.*))` in a parser Regex   -> "Invalid regex pattern"
  3. `Parser_Cri On` in a parser [FILTER]       -> "unknown configuration
                                                   property 'parser_cri'"
  4. No `[OUTPUT]` at all. With no `config.outputs`
     key, the fluent-bit chart falls back to its own values.yaml, whose default
     is TWO ELASTICSEARCH outputs pointing at `elasticsearch-master`.

Every one of those is fatal at runtime, and every one of them has the same
consequence: the DaemonSet CrashLoops, so NO log line from ANY of the 11
Boutique services reaches Loki. A Fluent Bit config is validated as a whole, so
one bad key is not "one service's logs are ugly" — it is "the log pipeline does
not exist".

That class of failure is exactly what a render check is supposed to catch, and
it is why the fluent-bit binary is the check rather than another YAML schema.

USAGE
-----
    scripts/check-fluentbit-config.py RENDERED.yaml [more.yaml ...] [OPTIONS]

RENDERED.yaml is the output of

    helm template fb observability/fluent-bit -n observability

The script finds the chart's own config ConfigMap (fluent-bit.conf, plus the
chart's custom_parsers.conf), reassembles the config that would land on the pod,
and checks it. The Boutique parsers are a SEPARATE ConfigMap —
observability/fluent-bit/boutique-parsers.yaml — mounted by the chart at
/fluent-bit/etc/parsers, so they are supplied by `--parsers` (which defaults to
that path relative to the repo root).

When `docker` is available it ALSO runs the pinned image and reports the binary's
own verdict — that is the authoritative check. When docker is absent it reports
that explicitly rather than passing quietly; the structural checks below run
either way.

Exit 0 when the config is valid, 1 when it is not.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("check-fluentbit-config.py needs PyYAML")

# The image the chart pins through `appVersion`. Must stay in step with
# observability/fluent-bit/Chart.yaml.
FLUENT_BIT_IMAGE = "fluent/fluent-bit:5.1.3"

# Fluent Bit `[PARSER]` Format values accepted by the 5.1.x binary. There is no
# `none`; a parser must declare a format.
VALID_PARSER_FORMATS = {"regex", "json", "logfmt", "ltsv", "klog"}

# Properties the `parser` FILTER accepts. Taken from the 5.1.3 binary's own
# diagnostic: "unknown configuration property 'X'. The following properties are
# allowed: Key_Name, Parser, Preserve_Key, Reserve_Data, and Unescape_key."
# Properties shared by EVERY plugin (and therefore accepted by the parser filter):
# `Name`, `Match`, plus the global options in `fluent-bit -F parser -h`.
SHARED_FILTER_PROPERTIES = {
    "name", "match", "match_regex", "alias", "log_level", "log_suppress_interval",
}
PARSER_FILTER_PROPERTIES = (
    {"key_name", "parser", "preserve_key", "reserve_data", "unescape_key"}
    | SHARED_FILTER_PROPERTIES
)

# Properties the `loki` OUTPUT accepts, verbatim from the same diagnostic in
# fluent-bit 5.1.3. `batch_size` and `batch_wait` are NOT here, which is the
# single most surprising entry: they are scheduler properties and the loki
# output does its own chunk accumulation.
LOKI_OUTPUT_PROPERTIES = {
    "uri", "tenant_id", "tenant_id_key", "tenant_id_key_error_handling",
    "labels", "structured_metadata", "structured_metadata_map_keys",
    "auto_kubernetes_labels", "drop_single_key", "label_keys", "remove_keys",
    "line_format", "label_map_path", "http_user", "http_passwd", "buffer_size",
    "bearer_token", "header", "compress",
}

# Properties the loki output accepts from the CORE plugin/property layer rather
# than from its own list. Verified one at a time against the 5.1.3 binary.
LOKI_OUTPUT_CORE_PROPERTIES = {
    "host", "port", "workers", "retry_limit", "match", "name",
    "match_regex", "alias", "log_level", "log_suppress_interval",
}

# Inline regex flag groups that Oniguruma — the engine Fluent Bit compiles parser
# regexes with — does not accept. `(?s:...)`, `(?i:...)`, `(?m:...)`.
ONIGURUMA_UNSUPPORTED_INLINE_FLAGS = re.compile(r"\(\?[a-zA-Z]{1,2}:")

SECTION_HEADER = re.compile(r"^\[([A-Za-z][A-Za-z0-9_]*)\]$")
# Fluent Bit property keys are `Name`-style and contain dots, digits and
# hyphens — `K8S-Logging.Parser`, `multiline.parser`, `HTTP_Server`. The hyphen
# is the one that is easy to miss and that makes the whole parse fail.
KEY_VALUE = re.compile(r"^([A-Za-z][A-Za-z0-9_.\-]*)\s+(.+)$")


class Config:
    """A parsed classic-mode Fluent Bit config: an ordered list of sections."""

    def __init__(self, text: str):
        self.sections = []          # list of (section_name, {key: value})
        self.current_name = None
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            header = SECTION_HEADER.match(line)
            if header:
                self.current_name = header.group(1).upper()
                self.sections.append((self.current_name, {}))
                continue
            kv = KEY_VALUE.match(line)
            if kv and self.current_name:
                self.sections[-1][1].setdefault(kv.group(1).lower(), kv.group(2))
                continue
            raise ValueError(f"line is neither a section, a comment nor a Key Value pair: {line!r}")

    def all_named(self, section_name: str):
        for name, props in self.sections:
            if name == section_name:
                yield props

    def outputs(self):
        yield from self.all_named("OUTPUT")

    def filters(self):
        yield from self.all_named("FILTER")

    def parsers(self):
        yield from self.all_named("PARSER")


def load_rendered(path: str) -> tuple[str, str]:
    """Pull the chart's own config text out of a `helm template` render."""
    texts: dict[str, str] = {}
    with open(path, encoding="utf-8") as handle:
        for doc in yaml.safe_load_all(handle):
            if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
                for key, value in (doc.get("data") or {}).items():
                    texts.setdefault(key, value)
    if "fluent-bit.conf" not in texts:
        sys.exit(
            f"!! {path}: expected the rendered fluent-bit chart to carry a "
            f"ConfigMap key `fluent-bit.conf` — found {sorted(texts)}. Render with "
            f"`helm template fb observability/fluent-bit -n observability`."
        )
    return texts["fluent-bit.conf"], texts.get("custom_parsers.conf", "")


def assemble_mount(conf_text: str, boutique_parsers: str) -> str:
    """Rewrite the three Parsers_File paths so a real binary can load them."""
    # Three DIFFERENT files in the image, so three different paths here. Pointing
    # two of them at one file makes the binary report
    # "parser named 'docker_no_time' already exists" and abort, which is a
    # property of this test harness and not of the chart.
    out = conf_text
    out = re.sub(r"^(\s*)Parsers_File\s+/fluent-bit/etc/parsers\.conf.*$",
                 r"\1Parsers_File /cfg/chart-parsers.conf", out, flags=re.MULTILINE)
    out = re.sub(r"^(\s*)Parsers_File\s+/fluent-bit/etc/conf/custom_parsers\.conf.*$",
                 r"\1Parsers_File /cfg/custom-parsers.conf", out, flags=re.MULTILINE)
    out = re.sub(r"^(\s*)Parsers_File\s+/fluent-bit/etc/parsers/boutique-parsers\.conf.*$",
                 r"\1Parsers_File /cfg/boutique-parsers.conf", out, flags=re.MULTILINE)
    return out


def check_structural(conf_text: str, parsers_text: str) -> list[str]:
    """The checks that need no binary. Returns a list of failure strings."""
    problems: list[str] = []
    try:
        conf = Config(conf_text)
        parsers = Config(parsers_text)
    except ValueError as exc:
        return [f"config does not parse: {exc}"]

    # --- 1. a loki output exists at all ------------------------------------
    outputs = list(conf.outputs())
    if not outputs:
        problems.append(
            "no [OUTPUT] section at all. The fluent-bit chart's own default is two "
            "elasticsearch outputs pointing at `elasticsearch-master`, which this "
            "cluster does not have: the render succeeds and the DaemonSet ships "
            "nowhere."
        )
    loki = [o for o in outputs if o.get("name", "").lower() == "loki"]
    if not loki:
        problems.append(
            "no [OUTPUT] with Name loki. Nothing would reach Loki; this is the "
            "regression that motivated writing this script."
        )
        return problems

    # --- 2. no elasticsearch leftover --------------------------------------
    for out in outputs:
        if out.get("name", "").lower() in ("es", "elasticsearch"):
            problems.append(
                f"an elasticsearch output is still present (Host="
                f"{out.get('host', '?')}); it ships every record to a service that "
                f"does not exist in this cluster."
            )

    for out in loki:
        # --- 3. property names the loki output rejects ---------------------
        for key in out:
            if key not in LOKI_OUTPUT_PROPERTIES and key not in LOKI_OUTPUT_CORE_PROPERTIES:
                problems.append(
                    f"[OUTPUT] Name loki has property `{key}`, which the 5.1.3 binary "
                    f"rejects as an unknown configuration property for the loki output "
                    f"plugin. Allowed: {sorted(LOKI_OUTPUT_PROPERTIES)} plus the core "
                    f"set {sorted(LOKI_OUTPUT_CORE_PROPERTIES)}."
                )

        # --- 4. the cardinality bound, asserted rather than commented -------
        labels = out.get("labels", "")
        label_names = sorted(
            p.strip().split("=", 1)[0] for p in labels.split(",") if "=" in p
        )
        if label_names != ["app", "container", "namespace"]:
            problems.append(
                f"loki output Labels are {label_names}, not the bounded three "
                f"[app, container, namespace]. The 90-stream bound in "
                f"observability/loki/values.yaml is only real if `pod` is not a label."
            )
        structured = out.get("structured_metadata", "")
        if "pod" not in structured:
            problems.append(
                f"loki output Structured_Metadata is {structured!r} and does not carry "
                f"`pod`. Without structured metadata the only place to put the pod name "
                f"is a label, which is the cardinality failure."
            )
        if "kubernetes" not in out.get("remove_keys", ""):
            problems.append(
                "loki output does not remove the `kubernetes` map, so the whole "
                "Kubernetes metadata object is JSON-dumped inside every log line."
            )

    # --- 5. every parser a filter references exists -------------------------
    defined = {p.get("name") for p in parsers.parsers()}
    for filt in conf.filters():
        for referenced in (filt.get("parser"),):
            if referenced and referenced not in defined:
                problems.append(
                    f"filter references parser {referenced!r}, which is not defined in "
                    f"the parsers ConfigMap. Fluent Bit fails to start on that."
                )

    # --- 6. parser property mistakes ---------------------------------------
    for filt in conf.filters():
        name = filt.get("name", "")
        if name == "parser":
            for key in filt:
                if key not in PARSER_FILTER_PROPERTIES:
                    problems.append(
                        f"filter `Name parser` has property `{key}`, which is not one of "
                        f"the five the 5.1.3 binary accepts for that filter "
                        f"({sorted(PARSER_FILTER_PROPERTIES)}). `Parser_Cri` belongs to "
                        f"the tail INPUT plugin, not here."
                    )

    # --- 7. parser internals ------------------------------------------------
    for parser in parsers.parsers():
        pname = parser.get("name", "<unnamed>")
        fmt = (parser.get("format") or "").lower()
        if not fmt:
            problems.append(f"parser {pname!r} declares no Format. Fluent Bit requires one.")
        elif fmt not in VALID_PARSER_FORMATS:
            problems.append(
                f"parser {pname!r} has Format {fmt!r}. There is no `none` format; the "
                f"valid set the binary accepts is {sorted(VALID_PARSER_FORMATS)}."
            )
        regex = parser.get("regex")
        if regex:
            hit = ONIGURUMA_UNSUPPORTED_INLINE_FLAGS.search(regex)
            if hit:
                problems.append(
                    f"parser {pname!r} uses inline regex group flags {hit.group(0)} in "
                    f"{regex!r}. Oniguruma rejects them: `fluent-bit --dry-run` fails "
                    f"with `Invalid regex pattern`, which is a startup failure that "
                    f"stops the whole pipeline, not just this parser. Use [\\s\\S] "
                    f"instead of (?s:.)."
                )
    return problems


def check_with_binary(conf_text: str, chart_parsers: str, boutique_parsers: str) -> str | None:
    """Run the pinned image's own `--dry-run`.

    Returns None when the binary validates, a diagnostic string when it does
    not, or a message prefixed with '!!' when the check could not be run at all.
    """
    if not shutil.which("docker"):
        return "!! the fluent-bit binary check did NOT run — docker is not on PATH"

    mounted = assemble_mount(conf_text, boutique_parsers)
    with tempfile.TemporaryDirectory() as tmp:
        cfg = os.path.join(tmp, "cfg")
        os.makedirs(cfg)
        with open(os.path.join(cfg, "fluent-bit.conf"), "w", encoding="utf-8") as handle:
            handle.write(mounted)
        # The chart's own parsers.conf is the minimal docker/cri set. It can
        # legitimately be empty — the Boutique parsers live in their own file —
        # but the file must EXIST, because Fluent Bit aborts on a missing
        # Parsers_File default.
        # The chart's own parsers.conf (the minimal docker/cri set). It can
        # legitimately be empty — the Boutique parsers live in their own file —
        # but the file must EXIST, because Fluent Bit aborts on a missing
        # Parsers_File. It is written separately from custom_parsers.conf because
        # two Parsers_File lines pointing at one file make the binary report
        # "parser named 'docker_no_time' already exists" and abort.
        with open(os.path.join(cfg, "chart-parsers.conf"), "w", encoding="utf-8") as handle:
            handle.write("")
        with open(os.path.join(cfg, "custom-parsers.conf"), "w", encoding="utf-8") as handle:
            handle.write(chart_parsers)
        with open(os.path.join(cfg, "boutique-parsers.conf"), "w", encoding="utf-8") as handle:
            handle.write(boutique_parsers)
        try:
            proc = subprocess.run(
                ["docker", "run", "--rm", "-v", f"{cfg}:/cfg:ro", FLUENT_BIT_IMAGE,
                 "--config=/cfg/fluent-bit.conf", "--dry-run"],
                capture_output=True, text=True, timeout=180,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            return f"!! could not run {FLUENT_BIT_IMAGE}: {exc}"

    log = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode == 0:
        return None
    diagnostic = "; ".join(
        line.strip() for line in log.splitlines()
        if "[error]" in line or "[help]" in line or "aborting" in line
    )
    return (
        f"fluent-bit {FLUENT_BIT_IMAGE} --dry-run FAILED (exit {proc.returncode}): "
        f"{diagnostic or log.strip()[-400:]}"
    )


def load_parsers(path: str) -> str:
    """The Boutique parsers ConfigMap, which the chart mounts as its own volume."""
    with open(path, encoding="utf-8") as handle:
        for doc in yaml.safe_load_all(handle):
            if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
                data = doc.get("data") or {}
                for key in data:
                    if key.endswith("boutique-parsers.conf"):
                        return data[key]
    sys.exit(
        f"!! {path}: no `boutique-parsers.conf` key in that ConfigMap. Expected the "
        f"file the chart mounts at /fluent-bit/etc/parsers."
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("paths", nargs="+", help="rendered `helm template` output")
    parser.add_argument(
        "--parsers",
        default="observability/fluent-bit/boutique-parsers.yaml",
        help="the Boutique parsers ConfigMap the chart mounts at /fluent-bit/etc/parsers",
    )
    args = parser.parse_args()

    failures: list[str] = []
    binary_backed = False
    try:
        parsers_text = load_parsers(args.parsers)
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 1

    for path in args.paths:
        conf_text, chart_parsers = load_rendered(path)

        for problem in check_structural(conf_text, parsers_text):
            failures.append(f"{path}: {problem}")

        verdict = check_with_binary(conf_text, chart_parsers, parsers_text)
        if verdict is None:
            binary_backed = True
            print(f"ok: {os.path.basename(path)} parses under fluent-bit {FLUENT_BIT_IMAGE}")
        elif verdict.startswith("!!"):
            print(f"!! {path}: {verdict[2:].strip()}")
            failures.append(f"{path}: fluent-bit binary check not run")
        else:
            failures.append(f"{path}: {verdict}")

    if failures:
        for failure in failures:
            print(f"!! {failure}", file=sys.stderr)
        return 1
    if not binary_backed:
        return 1
    print("ok: fluent-bit config is valid at the structural and binary levels")
    return 0


if __name__ == "__main__":
    sys.exit(main())
