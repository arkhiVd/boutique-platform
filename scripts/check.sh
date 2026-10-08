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

need() { command -v "$1" >/dev/null 2>&1 || { gone "$2"; return 1; }; }

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
  check "checkov -d . (terraform)" -- checkov -d "$ROOT" --framework terraform --quiet --compact
fi

cyan "== kubernetes manifests =="
MANIFESTS="$(find apps ci observability -name '*.yaml' -not -path '*charts*' 2>/dev/null | sort)"
if need kubeconform kubeconform && [[ -n "$MANIFESTS" ]]; then
  while IFS= read -r f; do
    check "kubeconform $f" -- kubeconform -strict -summary "$f"
  done <<< "$MANIFESTS"
fi
if need conftest conftest && [[ -d policy ]]; then
  # Only pass directories that exist. ci/ and observability/ are later phases;
  # passing a missing path makes conftest exit on a stat error, which would look
  # exactly like a policy failure and would be a false FAIL.
  CONFTEST_TARGETS=()
  for d in apps ci observability; do
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
  CONFTEST_IGNORE='apps/boutique/(upstream-kubernetes-manifests\.yaml|chaos/)'
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
    check "helm lint --strict $d" -- helm lint --strict "$d"
  done < <(find . -name Chart.yaml -not -path './.terraform/*' | sort)
fi

cyan "== shell =="
if need shellcheck shellcheck; then
  while IFS= read -r f; do check "shellcheck $f" -- shellcheck -x "$f"; done < <(find scripts -name '*.sh' | sort)
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
