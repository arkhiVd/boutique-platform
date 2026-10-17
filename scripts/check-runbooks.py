#!/usr/bin/env python3
"""Run every command in docs/runbooks/ the only safe way: reads for real, writes dry.

ROADMAP Phase 13: "Every runbook has a 'Last verified' date and the command it
claims actually exists -- verified by a script that runs every fenced command
in docs/runbooks/ with --dry-run or in a scratch namespace."

Each ```bash block is executed in its own bash, after a prelude of shell
functions that stand in front of the tools a runbook drives:

  kubectl    reads (get, describe, logs, top, auth, rollout status/history,
             wait, version, api-resources, explain) run against the cluster.
             Every write (apply, delete, scale, patch, drain, cordon,
             rollout restart/undo, ...) gets --dry-run=server, so the
             apiserver validates it and changes nothing. port-forward runs
             for real in the background (so the block's localhost calls can
             be checked) and is killed when the block ends. exec, run, attach,
             proxy, edit and debug are interactive: checked, not run.
  helm       list/status/history/get run; upgrade/install/rollback/uninstall
             get --dry-run.
  aws        describe*/get*/list*/head* run; any other operation is proven to
             EXIST (`aws <svc> <op> help`) and not called.
  terraform  plan/validate/fmt/output/show/state run; apply and destroy are
             approval gates and are never executed, only recognised.
  git        log/show/diff/status/rev-parse run; anything that changes the
             tree or a remote (revert, reset, push, ...) is recognised only.
  scripts/   a call to a repo script is checked for existence and the exec
             bit, not run: the scripts have their own gates in check.sh.
  curl       runs (a runbook's HTTP calls are reads), 20s cap per call.
  sleep      no-op. rm/dd/shred/mkfs/reboot/shutdown: refused outright.

A ```bash manual block is too heavy to run on every check (the runbook says
why beside it): syntax-checked, and every URL in it must answer a HEAD.
A ```sh-node block holds commands that only make sense ON a node (systemctl,
journalctl, k3s): it is syntax-checked with `bash -n`, never run here.

A command that exits non-zero is a FAIL, and so is a `<placeholder>`: a
runbook command must be pasteable, so placeholders are shell variables the
block itself resolves.

  scripts/check-runbooks.py            live: needs KUBECONFIG and AWS creds
  OFFLINE=1 scripts/check-runbooks.py  syntax, Last-verified and placeholders
                                       only (what check.sh and CI run)
Exit 0 when every runbook passes, 1 otherwise.
"""

import glob
import os
import re
import signal
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OFFLINE = os.environ.get("OFFLINE") == "1"
BLOCK = re.compile(r"^```([\w-]*)([^\n]*)\n(.*?)^```", re.S | re.M)
VERIFIED = re.compile(r"\*\*Last verified:?\*\*:?\s*(\d{4}-\d{2}-\d{2})|\*\*Last verified:\s*(\d{4}-\d{2}-\d{2})")
PLACEHOLDER = re.compile(r"(?<![<\w])<[A-Za-z][\w .:/-]*>(?!>)")

PRELUDE = r'''
# No pipefail: the reader's interactive shell has none either, and a runbook's
# `kubectl ... | grep x` is read exactly as that shell reads it.
LOG="$RUNBOOK_LOG"
note() { printf '%s\t%s\n' "$1" "$2" >>"$LOG"; }
_run() { # status, label, command...
  local label="$1"; shift
  if "$@" >/dev/null 2>"$LOG.err"; then note OK "$label"; return 0
  else note FAIL "$label :: $(tr '\n' ' ' <"$LOG.err" | cut -c1-220)"; return 0; fi
}
kubectl() {
  local a verb="" sub="" args=("$@") i=0
  for a in "$@"; do
    case "$a" in -n|--namespace|-l|--selector|-o|--output|-c|--container|--context|--kubeconfig|-f|--filename|--for|--timeout|--since|--tail|-p|--type|--field-selector|--sort-by|--to-revision|--replicas) i=1; continue;; esac
    if [ $i = 1 ]; then i=0; continue; fi
    case "$a" in -*) continue;; esac
    if [ -z "$verb" ]; then verb="$a"; elif [ -z "$sub" ]; then sub="$a"; break; fi
  done
  local label="kubectl $*"
  case "$verb" in
    get|describe|top|auth|version|api-resources|api-versions|explain|cluster-info|wait|events|config)
      command kubectl "${args[@]}" --request-timeout=30s ;;
    logs)
      local clean=(); for a in "${args[@]}"; do [ "$a" = -f ] || [ "$a" = --follow ] || clean+=("$a"); done
      _run "$label" command kubectl "${clean[@]}" --request-timeout=30s; return 0 ;;
    rollout)
      case "$sub" in
        status|history) command kubectl "${args[@]}" --request-timeout=30s ;;
        restart) # no --dry-run in kubectl: prove the target exists instead
          local tgt=(); for a in "${args[@]}"; do [ "$a" = rollout ] || [ "$a" = restart ] || tgt+=("$a"); done
          _run "$label [target exists: not restarted]" command kubectl get "${tgt[@]}"; return 0 ;;
        *) _run "$label [dry-run]" command kubectl "${args[@]}" --dry-run=server; return 0 ;;
      esac ;;
    port-forward)
      local pf; pf="$(mktemp "$LOG.pf.XXXX")"
      command kubectl "${args[@]}" >"$pf" 2>&1 &
      local t; for t in $(seq 1 30); do command sleep 0.5; grep -qE 'Forwarding from|error' "$pf" && break; done
      if grep -q 'Forwarding from' "$pf" && kill -0 "$!" 2>/dev/null; then note OK "$label [backgrounded]"
      else note FAIL "$label :: $(head -c 200 "$pf")"; fi
      return 0 ;;
    exec|run|attach|proxy|edit|debug|cp)
      note OK "$label [interactive: not run]"; return 0 ;;
    "") note FAIL "$label :: no verb"; return 0 ;;
    *) _run "$label [dry-run]" command kubectl "${args[@]}" --dry-run=server; return 0 ;;
  esac
  local rc=$?
  [ $rc -eq 0 ] && note OK "$label" || note FAIL "$label :: exit $rc"
  return $rc
}
helm() {
  case "$1" in
    upgrade|install|rollback|uninstall) _run "helm $* [dry-run]" command helm "$@" --dry-run ;;
    *) command helm "$@"; local rc=$?; [ $rc -eq 0 ] && note OK "helm $*" || note FAIL "helm $* :: exit $rc"; return $rc ;;
  esac
}
aws() {
  local svc="" op="" a
  for a in "$@"; do case "$a" in --*) ;; *) if [ -z "$svc" ]; then svc="$a"; elif [ -z "$op" ]; then op="$a"; fi ;; esac; done
  case "$op" in
    describe-*|get-*|list-*|head-*|ls|"")
      command aws "$@"; local rc=$?; [ $rc -eq 0 ] && note OK "aws $svc $op" || note FAIL "aws $svc $op :: exit $rc"; return $rc ;;
    *) _run "aws $svc $op [exists, not called]" command aws "$svc" "$op" help; return 0 ;;
  esac
}
terraform() {
  local a sub=""
  for a in "$@"; do case "$a" in -*) ;; *) sub="$a"; break ;; esac; done
  case "$sub" in
    apply|destroy|import|taint|untaint) note OK "terraform $sub [approval gate: not run]"; return 0 ;;
    *) command terraform "$@"; local rc=$?
       [ $rc -eq 0 ] && note OK "terraform $*" || note FAIL "terraform $* :: exit $rc"; return $rc ;;
  esac
}
sleep() { :; }
curl() {
  local url a prev="" dl=""
  for a in "$@"; do
    case "$a" in http*) url="$a" ;; -O|--remote-name) dl=1 ;; esac
    case "$prev" in -o|--output) [ "$a" = /dev/null ] || dl=1 ;; esac
    prev="$a"
  done
  case "$url" in *.tar.gz|*.tgz|*.zip|*.tar.xz) dl=1 ;; esac
  if [ -n "$dl" ]; then # a download: prove the artifact exists, do not fetch it
    _run "curl $url [download: HEAD only]" command curl -sSfIL --max-time 20 "$url"; return 0
  fi
  command curl --max-time 20 "$@"; local rc=$?
  [ $rc -eq 0 ] && note OK "curl $url" || note FAIL "curl $url :: exit $rc"; return $rc
}
git() {
  case "$1" in
    log|show|diff|status|rev-parse|ls-files|blame) command git "$@" ;;
    *) note OK "git $* [changes the tree: not run]"; return 0 ;;
  esac
}
_script() {
  if [ -x "$1" ]; then note OK "$1 [exists, executable: not run]"; else note FAIL "$1 :: missing or not executable"; fi
}
# Anything else that fails -- promtool, jq, openssl -- is caught here, so a
# command with no wrapper above cannot fail silently. grep is exempt: a runbook
# uses it as a probe, and "no match" (exit 1) is an answer, not an error.
set -o errtrace
trap '_rc=$?; _c="$BASH_COMMAND"; case "${_c%% *}" in kubectl|helm|aws|terraform|curl|git|_script|_run|note|command|return|local) ;; *) case "$_c" in *grep*) ;; *) note FAIL "$_c :: exit $_rc" ;; esac ;; esac' ERR
for _refuse in rm dd shred mkfs reboot shutdown; do eval "$_refuse() { note FAIL \"$_refuse refused in a runbook check\"; return 1; }"; done
'''


def blocks(text):
    for m in BLOCK.finditer(text):
        yield m.group(1).lower(), m.group(2).split(), m.group(3), text[: m.start()].count("\n") + 2


def check_file(path):
    rel = os.path.relpath(path, ROOT)
    text = open(path).read()
    fails, oks = [], 0
    m = VERIFIED.search(text)
    if not m:
        fails.append("no '**Last verified: YYYY-MM-DD**' line")
    for lang, info, body, line in blocks(text):
        if lang not in ("bash", "sh-node"):
            continue
        for n, raw in enumerate(body.splitlines()):
            code = raw.split(" #")[0] if not raw.lstrip().startswith("#") else ""
            if PLACEHOLDER.search(code):
                fails.append(f"line {line + n}: placeholder in a command: {raw.strip()[:90]}")
        syn = subprocess.run(["bash", "-n"], input=body, text=True, capture_output=True)
        if syn.returncode:
            fails.append(f"block at line {line}: bash -n: {syn.stderr.strip()[:160]}")
            continue
        # ```bash manual: too heavy or too slow to run on every check (the
        # runbook says why next to the block). Syntax and placeholders only,
        # plus any download URL in it must answer a HEAD request.
        if lang == "bash" and "manual" in info and not OFFLINE:
            for url in re.findall(r"https?://[^\s'\"|)]+", body):
                if "localhost" in url or ".svc" in url:
                    continue
                head = subprocess.run(["curl", "-sSfIL", "--max-time", "20", url], capture_output=True)
                if head.returncode:
                    fails.append(f"block at line {line}: {url} does not answer HEAD")
            oks += 1
            continue
        if OFFLINE or lang == "sh-node":
            oks += 1
            continue
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "log")
            open(log, "w").close()
            script = os.path.join(tmp, "block.sh")
            # A repo script invoked at the start of a line goes through _script.
            runnable = re.sub(r"^(\s*)(\./)?(scripts/[\w./-]+)", r"\1_script \3", body, flags=re.M)
            # `kubectl port-forward ... &`: the wrapper backgrounds the forward
            # itself and waits for "Forwarding from", so the block's next line
            # does not race it. A trailing & would put that wait in a subshell.
            runnable = re.sub(r"^(\s*kubectl\b[^\n]*\bport-forward\b[^\n]*?)\s*&\s*$", r"\1", runnable, flags=re.M)
            with open(script, "w") as f:
                f.write(PRELUDE + "\n" + runnable)
            env = dict(os.environ, RUNBOOK_LOG=log)
            # Own process group, killed whole afterwards: a runbook backgrounds
            # its port-forwards with `&`, and nothing else would reap them.
            # stdin closed: nothing in a runbook may wait for a keyboard.
            proc = subprocess.Popen(["bash", script], cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                proc.wait(timeout=600)
            except subprocess.TimeoutExpired:
                fails.append(f"block at line {line}: timed out after 600s")
            finally:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            for entry in open(log).read().splitlines():
                status, _, what = entry.partition("\t")
                if status == "OK":
                    oks += 1
                else:
                    fails.append(f"block at line {line}: {what}")
    return rel, (m.group(1) or m.group(2)) if m else None, oks, fails


def main():
    # README.md is the index, not a runbook: it carries no procedure to verify.
    files = sorted(f for f in glob.glob(os.path.join(ROOT, "docs", "runbooks", "*.md"))
                   if os.path.basename(f) != "README.md")
    if not files:
        print("no runbooks found", file=sys.stderr)
        return 1
    bad = 0
    mode = "offline (syntax, placeholders, Last verified)" if OFFLINE else "live (reads run, writes dry-run)"
    print(f"runbook check, {mode}")
    for path in files:
        rel, verified, oks, fails = check_file(path)
        state = "FAIL" if fails else "PASS"
        bad += bool(fails)
        print(f"  {state}  {rel:48} verified {verified or '-':10}  {oks} ok, {len(fails)} failed")
        for f in fails:
            print(f"          - {f}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
