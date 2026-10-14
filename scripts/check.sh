#!/usr/bin/env bash
# The single local gate. An agent runs this before reporting done.
# Reports pass/fail per tool with real output. Never silently skips a check:
# a missing tool is reported as MISSING and counts against the run.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

PASS=0; FAIL=0; MISSING=0
FAILED=(); ABSENT=()

cyan() { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$2"); }
gone() { printf '  \033[1;33mMISS\033[0m  %s (not installed)\n' "$1"; MISSING=$((MISSING+1)); ABSENT+=("$1"); }

score() { if [[ $1 -eq 0 ]]; then ok "$2"; else bad "$2 (exit $1)" "$2"; fi; }

# A soft warning: printed loudly, not counted as a FAIL. Used for the two cases
# where a red line would be wrong rather than right — an honest gap whose fix is
# not on this branch, and a number that is recorded rather than passable. Without
# a soft level those two have to be either silently ignored or permanently red,
# and a permanently red line trains people to stop reading the output.
warn() { printf '  \033[1;33mWARN\033[0m  %s\n' "$1"; }

# check <label> -- <cmd...>
check() {
  local label="$1"; shift; [[ "${1:-}" == "--" ]] && shift
  cyan "$label"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    ok "$label"
  else
    bad "$label (exit $rc)" "$label"
    printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
  fi
  return 0
}

# check_always_show: like `check`, but prints the command's output whether it
# passes or fails. Used for the node capacity budget: that number is the most
# important one in the repo and hiding it behind a green PASS is exactly how a
# finding becomes invisible.
check_show() {
  local label="$1"; shift; [[ "${1:-}" == "--" ]] && shift
  cyan "$label"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/        /'
  if [[ $rc -eq 0 ]]; then ok "$label"; else bad "$label (exit $rc)" "$label"; fi
  return 0
}

need() { command -v "$1" >/dev/null 2>&1 || { gone "$2"; return 1; }; }

# Install providers for one Terraform root without ever touching a backend.
# `-backend=false` is essential: a real `terraform init` here would try to reach
# the S3 state bucket, which does not exist until bootstrap/ is applied, and
# would fail with NoSuchBucket — indistinguishable from a broken config.
local_init() {
  terraform -chdir="$1" init -backend=false -no-color >/dev/null 2>&1 || \
  terraform -chdir="$1" init -backend=false -no-color -input=false
}

cyan "== whitespace and conflict markers =="
rc=0; git diff --check 2>/dev/null || rc=$?; score "$rc" "git diff --check"
if grep -rIl -e '^<<<<<<< ' -e '^>>>>>>> ' --exclude-dir=.git . 2>/dev/null | grep -q .; then
  bad "conflict markers found" "conflict markers"; grep -rIl -e '^<<<<<<< ' -e '^>>>>>>> ' --exclude-dir=.git . 2>/dev/null | sed 's/^/        /'
else
  ok "no conflict markers"
fi

cyan "== terraform =="
TF_ROOTS="$(find . -name versions.tf -not -path './.terraform/*' -exec dirname {} \; 2>/dev/null | sort)"
export PATH="$HOME/.local/bin:$HOME/.local/share/omarchy/bin:/usr/local/bin:$PATH"
if need terraform terraform && [[ -n "$TF_ROOTS" ]]; then
  check "terraform fmt -recursive -check" -- terraform fmt -recursive -check -diff
  if need tflint tflint; then
    tflint --init >/dev/null 2>&1 || true
    check "tflint --recursive" -- tflint --recursive --format compact
  fi
  while IFS= read -r dir; do
    # `terraform validate` cannot run before providers are installed: it fails with
    # "there is no package for ... cached in .terraform/providers", which looks
    # exactly like a broken configuration. `init -backend=false` installs the
    # providers from the lock file without touching any state or backend.
    local_init "$dir"
    check "terraform validate ($dir)" -- terraform -chdir="$dir" validate
  done <<< "$TF_ROOTS"
else
  ok "terraform: nothing to check"; PASS=$((PASS+1))
fi

cyan "== security =="
if need gitleaks gitleaks; then
  check "gitleaks detect --no-git" -- gitleaks detect --no-git --source "$ROOT" --redact
fi
if need checkov checkov && [[ -n "$TF_ROOTS" ]]; then
  # Per TF root, not one repo-wide run. Checkov loads exactly one config file
  # per invocation and searches the scanned directory first, then the cwd:
  #   checkov/common/util/config_utils.py, get_default_config_paths()
  # So a single `checkov -d .` never sees platform/.checkov.yaml or
  # bootstrap/.checkov.yaml, and a root-level copy of either one would leak
  # one stack's suppressions into the other's results. Same loop shape as the
  # validate loop above.
  while IFS= read -r dir; do
    check "checkov -d $dir" -- checkov -d "$dir" --framework terraform --quiet --compact
  done <<< "$TF_ROOTS"
fi

cyan "== kubernetes manifests =="
# What is NOT a Kubernetes manifest, and why each exclusion exists:
#
#   values.yaml, Chart.yaml, Chart.lock, charts/*  -- Helm chart inputs and the
#     vendored subcharts. kubeconform rejects them with "missing 'kind' key",
#     which looks exactly like a real schema failure. They are validated by
#     `helm lint` and `helm template` below instead.
#
#   observability/rules/, observability/slos/  -- bare Prometheus rule files.
#     `promtool check rules` accepts only a file whose sole top-level key is
#     `groups:`, so they carry no apiVersion/kind and cannot be schema-checked.
#     (kube-prometheus-stack/rules and /slos are symlinks to them; find does
#     not follow symlinked directories by default, so they are excluded twice
#     over.)
#
#   observability/loki/alerts.yaml  -- same shape, and it lives inside the Loki
#     chart so `.Files` can load it.
#
#   any chart's templates/  -- Go template text, not YAML. kubeconform fails on
#     the first `{{- if }}` with an unhelpful parse error, and the three
#     templates in this repo (kube-prometheus-stack/templates/platform-rules.yaml,
#     loki/templates/prometheusrules.yaml,
#     blackbox/templates/external-probe.yaml) are each VALIDATED BY RENDERING —
#     `helm lint --strict` and `helm template` below both expand them, and a
#     schema check belongs to the rendered output, which is exactly what
#     `kubeconform` gets for every non-template file here.
HELM_SOURCES='(values\.yaml|Chart\.ya?ml|Chart\.lock)'
BARE_RULE_FILES='(/rules/|/slos/|alerts\.yaml$)'
CHART_TEMPLATES='/templates/'
# `cluster/` is the Phase 3/4 policy layer: RBAC, PDBs, NetworkPolicies,
# ResourceQuotas, LimitRanges, PriorityClasses. It is shorter than the app
# overlay but it is the layer that decides what the cluster REFUSES to run, so it
# goes through the same schema and policy gates rather than being read by eye.
MANIFESTS="$(find apps ci cluster observability -name '*.yaml' -not -path '*charts*' 2>/dev/null \
  | grep -Ev "$HELM_SOURCES" | grep -Ev "$BARE_RULE_FILES" | grep -Ev "$CHART_TEMPLATES" | sort)"
# SCHEMA SOURCES AND WHY THEY ARE NOT WHAT kubeconform PICKS BY DEFAULT
#
# Two of kubeconform's own defaults were wrong for this gate, and each was
# measured rather than read off a README:
#
# 1. The version. Without `-kubernetes-version`, kubeconform resolves "latest"
#    at run time against a live endpoint. The rendered-chart pass below has
#    pinned 1.36.3 since Phase 6 and the raw pass did not, so the two halves of
#    the same gate could validate against different API schemas.
#
# 2. The default schema host, `kubernetesjsonschema.dev`. It does not resolve
#    to a reachable address from this network (curl returns 000 in ~0.1s, and
#    the host maps to an AWS ap-southeast-1 address), but kubeconform's HTTP
#    client waits on it far longer than curl does: a single `namespace.yaml`
#    spent 111s blocked in `epoll_wait` with the gate stalled. A gate that can
#    hang forever is worse than a gate that fails, because the reviewer sees
#    nothing. The yannh/kubernetes-json-schema mirror is the same schema set
#    served from GitHub raw — the same origin the CRDs catalog already uses,
#    and both return 200 here.
#
# 3. `-cache`: schemas are downloaded once into a gitignored directory. Every
#    run after the first is local, which is what makes the gate reproducible
#    when the network is not.
#
# 4. `timeout`: the remaining failure mode. A hang becomes a visible FAIL with
#    exit 124 instead of an infinite wait.
K8S_VERSION='1.36.3'
API_SCHEMAS='https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/{{.NormalizedKubernetesVersion}}-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json'
# CRD schemas are not in the core schema set, so PrometheusRule, ServiceMonitor,
# IngressRoute and the rest would fail with "could not find schema". The CRDs
# catalog is the community-maintained schema set and it is the same one used
# since Phase 6.
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
SCHEMA_CACHE="$ROOT/.kubeconform-cache"
# kc is the one entry point for every kubeconform invocation in this file, so
# the version, the sources, the cache and the timeout can only ever change in
# one place. `check` invokes it as a command, and a shell function resolves
# under `"$@"` exactly like a binary does.
kc() {
  # kubeconform refuses to create the cache folder itself, and a missing folder
  # is reported as "failed opening cache folder" — a confusing error that reads
  # like a broken schema source. Created here so a fresh clone behaves the same
  # as a warm one.
  mkdir -p "$SCHEMA_CACHE"
  # ONE RETRY, AND ONLY ON exit 124.
  #
  # 124 is `timeout`'s own status: it means the run was killed before it could
  # finish, which on this gate can only be a stalled schema download. A real
  # finding — a manifest that violates its schema under -strict — comes back as
  # exit 1, quickly, with the violations printed. So retrying 124 can never
  # turn a red result green; it only absorbs the network, and it reports on the
  # second failure rather than silently looping.
  #
  # The reason this exists at all: a ServiceMonitor file must miss the core
  # schema location (yannh has no CRDs) before it hits the CRD catalog, so the
  # CRD-bearing files do one uncached round trip per run. On 2026-10-14 that
  # round trip stalled twice out of five within a single gate run, while the
  # identical kind in an adjacent file passed.
  local rc=0
  timeout 60 kubeconform -strict -summary \
    -kubernetes-version "$K8S_VERSION" \
    -cache "$SCHEMA_CACHE" \
    -schema-location "$API_SCHEMAS" \
    -schema-location "$CRD_SCHEMAS" "$@" && return 0
  rc=$?
  if [[ $rc -eq 124 ]]; then
    printf 'kubeconform timed out once, retrying\n' >&2
    timeout 60 kubeconform -strict -summary \
      -kubernetes-version "$K8S_VERSION" \
      -cache "$SCHEMA_CACHE" \
      -schema-location "$API_SCHEMAS" \
      -schema-location "$CRD_SCHEMAS" "$@"
    return $?
  fi
  return "$rc"
}
if need kubeconform kubeconform && [[ -n "$MANIFESTS" ]]; then
  while IFS= read -r f; do
    check "kubeconform $f" -- kc "$f"
  done <<< "$MANIFESTS"
fi
if need conftest conftest && [[ -d policy ]]; then
  # Only pass directories that exist. ci/ and observability/ are later phases;
  # passing a missing path makes conftest exit on a stat error, which would look
  # exactly like a policy failure and would be a false FAIL.
  CONFTEST_TARGETS=()
  for d in apps cluster ci observability; do
    [[ -d "$d" ]] && CONFTEST_TARGETS+=("$d")
  done
  # Two categories of file are excluded by path, deliberately:
  #
  #   apps/boutique/upstream-kubernetes-manifests.yaml — the verbatim upstream
  #     baseline. It is the control, not the product: it fails this policy by
  #     construction, which is the point. The negative fixtures under
  #     policy/tests/should-fail/ are what prove the policy has teeth; testing
  #     the control here too would be a tautological failure.
  #
  #   apps/boutique/chaos/ — strategic-merge patch fragments. A fragment is not
  #     a complete object, so validating one against a whole-resource policy
  #     reports failures that do not exist.
  #   observability/*/templates/, and every values.yaml / Chart.yaml — Helm
  #     source, not a manifest. `{{- if }}` is not YAML, so conftest fails at the
  #     parser with a message that looks like a policy failure. These are checked
  #     where they are actually valid: `helm lint --strict`, `helm template`, and
  #     kubeconform over the rendered output.
  #   observability/rules/, slos/, loki/alerts.yaml — bare Prometheus rule files
  #     with no kind, already excluded by kind-check below.
  CONFTEST_IGNORE='apps/boutique/(upstream-kubernetes-manifests\.yaml|chaos/)|/templates/|(values\.yaml|Chart\.ya?ml|Chart\.lock)$|/rules/|/slos/|alerts\.yaml$'
  if [[ ${#CONFTEST_TARGETS[@]} -gt 0 ]]; then
    check "conftest test ${CONFTEST_TARGETS[*]}" -- \
      conftest test "${CONFTEST_TARGETS[@]}" -p policy/ --ignore "$CONFTEST_IGNORE"
    # --combine hands the policy every document at once. That is the only mode in
    # which a Deployment can be checked against its own HPA, because a Deployment
    # and its HorizontalPodAutoscaler are two separate YAML documents. See the
    # header of policy/resources.rego.
    check "conftest test ${CONFTEST_TARGETS[*]} --combine" -- \
      conftest test "${CONFTEST_TARGETS[@]}" -p policy/ --ignore "$CONFTEST_IGNORE" --combine
  fi
fi

cyan "== helm =="
if need helm "helm"; then
  while IFS= read -r f; do
    d="$(dirname "$f")"
    # charts/*/charts/ is gitignored on purpose, so the dependency tree has to be
    # resolved locally. `helm lint` refuses a chart whose dependencies are not
    # in charts/ — without this, the gate would fail on every chart for a
    # reason that has nothing to do with the chart.
    check "helm dependency build $d" -- helm dependency build "$d"
    check "helm lint --strict $d" -- helm lint --strict "$d"
    # A render is a different check from a lint: it evaluates every template,
    # including the `.Files.Glob` loops that load the Prometheus rules, and it
    # fails on a `required` or a `fail` in a template.
    check "helm template $(basename "$d") $d" -- helm template "$(basename "$d")" "$d"

    # A render is also the only thing that can be schema-validated for a chart
    # whose manifests are Go template text: kubeconform cannot parse `{{- if }}`
    # and reports an unhelpful parse error that looks like a policy failure.
    # This check caught two real violations on the Traefik CRDs during Phase 5 —
    # a `port` typed as a number where the middleware CRD wants a string, and a
    # `sourceCriterion` nested one level above where the schema allows it. Both
    # would have been rejected by the API server at apply time, so the gate has
    # to run on the rendered output, not the template.
    if [[ -f "$d/Chart.yaml" ]] && grep -q 'name: traefik' "$d/Chart.yaml" 2>/dev/null; then
      # Capture the status explicitly; `$?` after an assignment is the status of
      # the assignment, not of the command inside it.
      render_err=""
      render_rc=0
      render_err="$(helm template "$(basename "$d")" "$d" \
        --namespace traefik \
        --set frontendHost=boutique.example \
        --set grafanaHost=grafana.example \
        --set jenkinsHost=jenkins.example \
        --set tlsSecretName=tls-example 2>&1)" || render_rc=$?
      if [[ $render_rc -eq 0 && -n "$render_err" ]]; then
        printf '%s\n' "$render_err" > /tmp/kubeconform-render.yaml
        check "kubeconform (rendered $d)" -- kc /tmp/kubeconform-render.yaml
        rm -f /tmp/kubeconform-render.yaml
      else
        bad "helm template (rendered $d)" "$(basename "$d") render"
        printf '%s\n' "$render_err" | tail -15 | sed 's/^/        /'
        FAIL=$((FAIL+1))
      fi
    fi
  done < <(find . -name Chart.yaml -not -path './.terraform/*' | sort)
fi

cyan "== fluent-bit config =="
# WHY THIS IS NOT COVERED BY THE HELM CHECKS ABOVE:
# the fluent-bit chart renders a configuration that CANNOT START, and
# `helm lint --strict` and `helm template` both pass it. Five distinct
# fatal errors were shipped into observability/fluent-bit/ and survived every
# existing gate: a `Format none` parser, an Oniguruma-invalid `(?s:...)` regex,
# `Parser_Cri On` on a filter that does not accept it, `Batch_Size` on an output
# that does not accept it, and — the one that mattered most — NO `[OUTPUT]` at
# all, so the chart fell back to its own default of two elasticsearch outputs.
#
# The consequence of every one of them is the same and it is total: Fluent Bit
# refuses to start, the DaemonSet CrashLoops, and no log line from any of the 11
# Boutique services reaches Loki. A config file is validated as a whole, so one
# bad key is not "one service's logs are ugly".
#
# So the gate is the fluent-bit BINARY itself. scripts/check-fluentbit-config.py
# renders the chart, reassembles the config that would land on the pod
# (including the parsers ConfigMap the chart mounts separately), runs
# `fluent-bit --dry-run` in the pinned image, and additionally asserts the
# cardinality bound at the structural level: exactly three labels and `pod` in
# structured metadata. Without docker on PATH it reports that the binary check
# did NOT run rather than passing — a missing tool is a reported gap.
if need docker "docker" && need python3 python3; then
  TMP_FB="$(mktemp -d)"
  helm template fb observability/fluent-bit --namespace observability \
    >"$TMP_FB/rendered.yaml" 2>/dev/null
  check "fluent-bit --dry-run on the rendered config (image 5.1.3)" -- \
    python3 scripts/check-fluentbit-config.py "$TMP_FB/rendered.yaml"
  rm -rf "$TMP_FB"
else
  gone "fluent-bit --dry-run (needs docker and python3)"
fi

cyan "== prometheus rules =="
if need promtool promtool; then
  # The chart adds the PrometheusRule wrapper at render time, so the rule files
  # are bare (`groups:` only) and this is the only way they get checked.
  while IFS= read -r f; do
    check "promtool check rules $f" -- promtool check rules "$f"
  done < <(find observability -name '*.yaml' -path '*/rules/*' -o -name '*.yaml' -path '*/slos/*' -o -name alerts.yaml | sort)
  # The synthetic fixtures assert that the 14.4x page fires and the 6x and 1x
  # tickets do NOT, on one input series. An empty exp_alerts is the assertion.
  while IFS= read -r f; do
    check "promtool test rules $f" -- promtool test rules "$f"
  done < <(find observability/synthetic-tests -name '*.yml' 2>/dev/null | sort)
fi

cyan "== grafana dashboards =="
# A dashboard ConfigMap that does not parse is a dashboard that silently loads
# nothing. Grafana will not tell anyone.
if need python3 python3; then
  while IFS= read -r f; do
    check "grafana json parses in $f" -- python3 scripts/check-dashboards.py "$f"
  done < <(find observability/dashboards -name '*.yaml' 2>/dev/null | sort)
fi

cyan "== node capacity budget =="
# The most important number in the repo: does the whole platform fit on the one
# t3.medium in SPEC.md. Renders every chart, sums resources.requests across the
# rendered manifests, and prints the comparison.
#
# The OVER-COMMIT IS A RECORDED FINDING, NOT A CHECK FAILURE. docs/resource-budget.md
# holds the arithmetic: 3600m / 4048Mi of requests against 1830m / 3741Mi
# schedulable, of which 2820m is the `boutique` namespace that no observability
# change can fix. Failing the gate on a number nobody is allowed to change trains
# people to stop reading the gate — which is the exact failure mode
# observability/rules/boutique-alerts.yaml is written to avoid.
#
# So the script is given a real bound instead: `--accept-over-commit 250` makes it
# exit 0 at or below 250% of schedulable and exit 1 above it, which still fails on
# a regression that makes the situation materially worse.
#
# `--node-count 1`, NOT 4. A DaemonSet schedules one pod per node, and the budget
# has to answer "does it fit on the ONE t3.medium" — node-exporter and fluent-bit
# each contribute one replica here, not four. `--node-count 4` answers a different
# question (the cluster-wide total) and would silently double those two.
if need python3 python3 && [[ -d observability ]]; then
  TMP_RENDER="$(mktemp -d)"
  trap 'rm -rf "$TMP_RENDER"' EXIT
  ok_render=1
  while IFS= read -r f; do
    d="$(dirname "$f")"
    helm template "budget.$(basename "$d")" "$d" --namespace observability \
      >"$TMP_RENDER/$(basename "$d").yaml" 2>/dev/null || ok_render=0
  done < <(find observability -name Chart.yaml -not -path '*charts*' | sort)

  if [[ -f apps/boutique/Kustomization ]]; then
    # Present on the app branch. kubectl kustomize pulls in apps/boutique/base
    # AND the observability overlay, so the OTel collector's 200m/256Mi is counted
    # here and must NOT also be passed through --extra.
    kubectl kustomize apps/boutique/ >"$TMP_RENDER/boutique.yaml" 2>/dev/null || ok_render=0
  else
    # Not a silent skip. This branch has no apps/boutique, so the boutique
    # namespace's 2820m/2312Mi and the OTel collector's 200m/256Mi are NOT in the
    # total below and the printed number is an UNDER-COUNT. docs/resource-budget.md
    # carries the real figure and how it was produced.
    #
    # WARN, not FAIL: the gap is real and it is not fixable from this branch, and a
    # line that is red for a reason nobody can remove would make the whole gate
    # ignorable. The line is printed in yellow and the number above it is the
    # observability-only figure, so it cannot be mistaken for the total.
    warn "apps/boutique is not on this branch: the number below is an UNDER-COUNT — no boutique, no OTel collector"
    warn "the real total is 3600m / 4048Mi = 196.7% CPU and 108.2% RAM of schedulable (see docs/resource-budget.md)"
  fi

  if [[ $ok_render -eq 1 ]]; then
    check_show "node capacity budget (rendered observability + boutique)" -- \
      python3 scripts/resource-budget.py --node-count 1 \
      --config-reloader 10m/16Mi \
      --accept-over-commit 250 \
      --extra ci:jenkins-controller:100m:512Mi \
      "$TMP_RENDER"/*.yaml
  else

    bad "node capacity budget (a chart failed to render)" "resource budget"
  fi
fi

cyan "== shell =="
if need shellcheck shellcheck; then
  # scripts/ AND platform/: the Phase 3 cloud-init bootstrap and the Phase 4 etcd
  # snapshot script render INTO the launch template's user_data, so a shellcheck
  # finding in them is a finding that will run on every node on every boot.
  while IFS= read -r f; do check "shellcheck $f" -- shellcheck -x "$f"; done \
    < <(find scripts platform -name '*.sh' -not -path '*/.terraform/*' | sort)
fi
while IFS= read -r f; do check "bash -n $f" -- bash -n "$f"; done < <(find . -name '*.sh' -not -path './.git/*' | sort)

cyan "== github actions =="
if need actionlint actionlint && [[ -d .github/workflows ]]; then
  for f in .github/workflows/*.y*ml; do
    [[ -e "$f" ]] || continue
    check "actionlint $f" -- actionlint "$f"
  done
fi

cyan "== python =="
if need python3 python3 && [[ -d scripts ]]; then
  check "python3 -m compileall scripts" -- python3 -m compileall -q scripts
fi

echo
cyan "==============================================="
printf '  PASS: %d   FAIL: %d   MISSING: %d\n' "$PASS" "$FAIL" "$MISSING"
[[ ${#FAILED[@]}  -gt 0 ]] && printf '  failed:       %s\n' "${FAILED[*]}"
[[ ${#ABSENT[@]}  -gt 0 ]] && printf '  not installed: %s\n' "${ABSENT[*]}"
cyan "==============================================="
[[ $FAIL -eq 0 && $MISSING -eq 0 ]]
