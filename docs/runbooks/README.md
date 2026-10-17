# Runbooks

Start with `scripts/doctor.sh`: one command, one verdict, and the failing check
names the runbook to open. All runbooks assume the SSM-tunnelled kubeconfig
(`platform/README.md`) and AWS credentials for the account.

| when | runbook |
|---|---|
| a node is NotReady, k3s keeps restarting, or a node must be drained or replaced | [node-loss.md](node-loss.md) |
| etcd has lost quorum, or the cluster's data is wrong | [etcd-restore.md](etcd-restore.md) |
| a change made things worse | [rollback.md](rollback.md) |
| a certificate is close to expiry | [cert-expiry.md](cert-expiry.md) |
| the bill is higher than the estimate | [cost-spike.md](cost-spike.md) |
| Loki is filling up or dropping lines | [loki-full.md](loki-full.md) |
| Prometheus restarts, is Pending, or is blind | [prometheus-restart.md](prometheus-restart.md) |
| alerts fire but no email arrives | [alert-delivery.md](alert-delivery.md) |
| traces are missing or Tempo is unhealthy | [traces.md](traces.md) |
| a checkout failed and you have the request | [find-the-failing-checkout.md](find-the-failing-checkout.md) |
| the ALB, the Web ACL or Traefik | [edge.md](edge.md) |
| Jenkins, its agents, or a stuck build | [ci.md](ci.md) |

## How these are kept true

`scripts/check-runbooks.py` executes every ` ```bash ` block the only safe way:

- `kubectl` reads run against the cluster; every write gets `--dry-run=server`, so
  the apiserver validates it and nothing changes. `port-forward` runs for real in
  the background so the block's `localhost` calls can be checked.
- `helm` writes get `--dry-run`; `aws` reads run and any other operation is
  proven to exist with `aws <svc> <op> help`; `terraform apply`/`destroy` are
  recognised and never run; `git` that would change the tree is not run.
- anything else that exits non-zero (promtool, jq, openssl) is a failure, and a
  `<placeholder>` in a command is a failure: a runbook command must paste and run.
- ` ```sh-node ` blocks run ON a node (in an SSM session) and are syntax-checked
  only; ` ```bash manual ` blocks are too heavy to run on every check (each says
  why) and are syntax-checked, with any download URL proven to answer.

```bash manual
scripts/check-runbooks.py                    # live: about ten minutes
OFFLINE=1 scripts/check-runbooks.py          # what scripts/check.sh runs
```

Each runbook's **Last verified** date is the day its commands last passed the
live check. The latest run is `docs/evidence/phase-13/runbook-check.txt`.
