# Runbook — restore the cluster from an etcd snapshot

**Last verified: 2026-10-17** — every fenced command below was executed by
`scripts/check-runbooks.py` against the live cluster: reads run for real, writes as
server-side dry-runs (output in `docs/evidence/phase-13/runbook-check.txt`). The full
restore was run end to end the same day with `scripts/etcd-restore-local.sh`: the
real S3 snapshot restored, 21/21 shop pods Ready and the home page served in
**555 s** (`docs/evidence/phase-13/etcd-restore-local.txt`).

**Restore is destructive by construction.** `k3s server --cluster-reset` moves the
current database aside and leaves a one-member cluster; the other servers must
then be wiped and rejoined. Only do it when the cluster has lost quorum (two
servers gone) or its data is wrong. Losing ONE server is `node-loss.md`, not this.

## The two facts that decide whether a restore works

1. **The token.** A snapshot's bootstrap data is encrypted with the cluster token
   in force when it was taken. Snapshots from **2026-10-17T20:23Z onwards** use the
   decrypted value of `/boutique-platform/k3s/token`. Snapshots taken **before**
   that use the parameter's KMS ciphertext as the token (the bootstrap script read
   it without `--with-decryption` until then; the cluster was rotated with
   `k3s token rotate`). Wrong token = `bootstrap data already found and encrypted
   with different token`.
2. **The version.** Restore with the same k3s build (`v1.36.5+k3s1`).

## Diagnostic entry point

```bash
# Is quorum actually lost? "ok" means it is NOT -- stop and use node-loss.md.
kubectl get --raw /healthz/etcd

# The snapshots that exist, newest last.
BUCKET="$(terraform -chdir=platform output -raw etcd_snapshot_bucket)"
aws s3 ls "s3://$BUCKET/etcd-snapshots/" | tail -5

# The snapshots k3s itself knows about (CRDs written by the etcd snapshot controller).
kubectl get etcdsnapshotfiles.k3s.cattle.io --sort-by=.spec.snapshotName 2>/dev/null | tail -5
```

## 1. Prove a snapshot restores, without touching the cluster

Run this first, every time: it is the same restore, into a local k3s container,
and it ends with the shop answering. If this fails, the real restore will too.

```bash manual
scripts/etcd-restore-local.sh
```

(`bash manual`: it takes about ten minutes and pulls eleven images, so
`check-runbooks.py` checks it is present rather than running it. Its own run is
the evidence above.)

The snapshot-only check, quicker and runnable on a schedule:

```bash
BUCKET="$(terraform -chdir=platform output -raw etcd_snapshot_bucket)"
BOUTIQUE_ETCD_SNAPSHOT_BUCKET="$BUCKET" scripts/etcd-restore-drill.sh --help
```

## 2. The real restore (quorum lost)

On the **leader** (`terraform -chdir=platform output -raw leader_instance_id`),
in an SSM session:

```sh-node
# Stop k3s on ALL three servers first (each one, through its own session).
systemctl stop k3s

# On the leader only: fetch the snapshot and restore with the matching token.
SNAP=on-demand-boutique-leader-i-01a7966000fabecf4-1792269007.zip
aws s3 cp "s3://boutique-platform-etcd-snapshots-348032171026/etcd-snapshots/$SNAP" /var/tmp/
export K3S_TOKEN="$(aws ssm get-parameter --region us-east-1 --name /boutique-platform/k3s/token \
  --with-decryption --query Parameter.Value --output text)"
k3s server --cluster-reset --cluster-reset-restore-path="/var/tmp/$SNAP"
systemctl start k3s

# On each follower: move the old datastore aside and rejoin.
mv /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/db.pre-restore
systemctl start k3s
```

## Verify

```bash
kubectl get nodes
kubectl get --raw /healthz/etcd
kubectl -n boutique get deploy
scripts/doctor.sh
```
