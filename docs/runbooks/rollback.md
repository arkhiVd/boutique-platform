# Runbook — roll back a bad change

**Last verified: 2026-10-17** — every fenced command below was executed by
`scripts/check-runbooks.py` against the live cluster: reads run for real, writes as
server-side dry-runs, `terraform apply` recognised and never run (output in
`docs/evidence/phase-13/runbook-check.txt`).

Three layers, three rollbacks. Find which layer changed last, roll back that one,
and only that one.

| layer | how it changes | how it rolls back |
|---|---|---|
| the shop (`apps/boutique`) | `kubectl apply -k`, or the Jenkins deploy stage | `kubectl rollout undo`, then fix in git |
| the platform charts (observability, ci, traefik, ebs-csi) | `helm upgrade` | `helm rollback` to the last good revision |
| AWS (`platform/`, `bootstrap/`) | `terraform apply` from `main` | `git revert` + plan + apply |

## Diagnostic entry point

```bash
# What changed most recently, per layer?
kubectl -n boutique get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,GEN:.metadata.generation
helm list -A
git log --oneline -10
```

## 1. The shop

```bash
# The revisions Kubernetes kept for one Deployment.
kubectl -n boutique rollout history deploy/frontend

# Back one revision, and watch it land.
kubectl -n boutique rollout undo deploy/frontend
kubectl -n boutique rollout status deploy/frontend --timeout=300s
```

`rollout undo` is a hot fix, not the end state: the next `kubectl apply -k
apps/boutique` re-applies whatever git holds. Revert the commit as well.

## 2. A platform chart

```bash
# The release history, newest last; STATUS deployed is what runs now.
helm history kube-prometheus-stack -n observability

# The last release before the current one that was healthy:
REV="$(helm history kube-prometheus-stack -n observability -o json \
  | jq -r '[.[] | select(.status=="superseded")][-1].revision')"
helm rollback kube-prometheus-stack "$REV" -n observability --wait --timeout 10m
```

The same three lines work for `loki`, `tempo`, `fluent-bit`, `blackbox`
(namespace `observability`), `ci` (namespace `ci`), `traefik` and `ebs-csi`
(namespace `kube-system`).

## 3. AWS

```bash
# The commit to undo: the newest one under platform/.
BAD="$(git log -1 --format=%H -- platform/)"
git show --stat "$BAD"
git revert --no-edit "$BAD"

export TF_VAR_k3s_token="$(aws ssm get-parameter --name /boutique-platform/k3s/token \
  --with-decryption --query Parameter.Value --output text)"
terraform -chdir=platform plan       # read every destroy and replace before applying
terraform -chdir=platform apply
```

A plan that wants to replace `aws_instance.*` is a node replacement: do it one node
at a time (`node-loss.md`, section 4), never as a side effect of a rollback.

## Verify

```bash
kubectl -n boutique get deploy
helm list -A
scripts/doctor.sh
```
