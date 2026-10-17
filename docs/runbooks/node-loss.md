# Runbook — a node is lost, drained, or has to be replaced

**Last verified: 2026-10-17** — every fenced command below was executed by
`scripts/check-runbooks.py` against the live cluster: reads run for real, writes as
server-side dry-runs, `terraform apply` recognised and never run (output in
`docs/evidence/phase-13/runbook-check.txt`). The drain path was also run for real
that day: `docs/evidence/phase-13/drain.txt` and the three `doctor-*.txt` runs.

Four nodes: one `c7i-flex.large` leader and two `t3.small` followers (the three
etcd members, one per AZ), and one `t3.small` agent. etcd needs two of three
members, so **one server can be lost; two cannot**. The agent can be lost freely.

## Diagnostic entry point

```bash
# Which node, and what does Kubernetes think of it?
kubectl get nodes -o wide -L boutique.io/role,topology.kubernetes.io/zone

# Is etcd still in quorum? (ok = yes; the apiserver answers only through etcd)
kubectl get --raw /healthz/etcd

# What EC2 thinks: a NotReady node whose instance checks pass is a k3s or
# memory problem, not a hardware one.
aws ec2 describe-instance-status --include-all-instances \
  --instance-ids $(terraform -chdir=platform output -json node_instance_ids | jq -r '.. | strings') \
  --query 'InstanceStatuses[].[InstanceId,InstanceState.Name,SystemStatus.Status,InstanceStatus.Status]' --output table

# One verdict for the whole cluster:
scripts/doctor.sh
```

## 1. A node is NotReady but its instance is running

**What it looked like on 2026-10-17:** after a drain packed pods onto a 2 GB
follower, the node reached 36 MiB available, its SSM agent could no longer fetch
credentials, the kubelet stopped reporting (MemoryPressure `Unknown`), and the
cluster ran on two etcd members.

```bash
NODE="$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1; exit}')"
if [ -n "$NODE" ]; then
  kubectl describe node "$NODE" | sed -n '/Conditions/,/Addresses/p'
  # Memory: requests and limits the scheduler has handed out on it.
  kubectl describe node "$NODE" | sed -n '/Allocated resources/,/Events/p'
fi
```

**Fix:** reboot the instance. It touches no data (etcd's state is on the root
volume) and is how the follower above came back in 2.5 minutes:

```bash
NODE="$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1; exit}')"
if [ -n "$NODE" ]; then
  INSTANCE_ID="i-${NODE##*-i-}"
  aws ec2 reboot-instances --instance-ids "$INSTANCE_ID"
  kubectl wait --for=condition=Ready "node/$NODE" --timeout=600s
fi
```

The structural fix is in place: every node reserves memory for k3s and the OS
and evicts pods at 200Mi available
(`/etc/rancher/k3s/config.yaml.d/60-kubelet-reserved.yaml`, written by
`platform/cluster-bootstrap.sh`), and Prometheus prefers the agent.

## 2. A server's k3s keeps restarting

`leaderelection lost` is **fatal** in k3s: the controller-manager, scheduler and
apiserver share one process with etcd, so a missed lease renewal restarts the
whole server. The leases are 60s/40s
(`/etc/rancher/k3s/config.yaml.d/50-leader-election.yaml`); with the upstream
15s/10s, a drain killed the leader outright.

```bash
# Are the long leases actually in force? 60 = yes.
kubectl -n kube-system get lease kube-controller-manager kube-scheduler k3s-cloud-controller-manager \
  -o custom-columns=NAME:.metadata.name,SECONDS:.spec.leaseDurationSeconds,HOLDER:.spec.holderIdentity
```

On the node (open a shell with `aws ssm start-session --target <instance>` from
the `INSTANCE_ID` above):

```sh-node
systemctl show k3s -p NRestarts -p ActiveEnterTimestamp
journalctl -u k3s --since "-30 min" --no-pager | grep -E "leaderelection lost|no leader|Main process exited"
free -m
ls /etc/rancher/k3s/config.yaml.d/
```

## 3. Drain a node on purpose (maintenance, AMI rotation)

Drain one node at a time and wait for `doctor.sh` to pass before the next.
Pods do **not** move back after `uncordon`: rebalance afterwards (below), or the
servers stay packed.

**redis-cart blocks a drain on purpose.** It is one replica on an `emptyDir`, and
its PodDisruptionBudget (`minAvailable: 1`, `apps/boutique/base/redis-cart.yaml`)
refuses every eviction, because evicting it empties every cart in the shop. If
it is on the node being drained, the drain waits forever. Moving it is a
decision: delete the pod yourself, knowing the carts go, then drain the rest.

```bash
NODE="$(kubectl get nodes -l boutique.io/role=agent -o name | head -1)"
kubectl cordon "$NODE"
# Is the cart store on this node? If so, this is the "carts are emptied" step.
REDIS_POD="$(kubectl -n boutique get pods -l app=redis-cart -o name \
  --field-selector "spec.nodeName=${NODE#node/}")"
[ -z "$REDIS_POD" ] || kubectl -n boutique delete "$REDIS_POD"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s \
  --pod-selector='app!=redis-cart'
scripts/doctor.sh          # expect FAIL naming the cordoned node -- that is correct
kubectl uncordon "$NODE"
# Rebalance: restart the shop one Deployment at a time so the scheduler spreads it.
for d in $(kubectl -n boutique get deploy -o name); do kubectl -n boutique rollout restart "$d"; done
```

## 4. Replace a node (new AMI, or the instance is gone)

The instances ignore AMI and user-data drift on purpose: a new AL2023 image would
otherwise replace all four nodes, every etcd member, in one apply. Replace one
node deliberately; it boots the launch template's current image and bootstrap.

```bash
export TF_VAR_k3s_token="$(aws ssm get-parameter --name /boutique-platform/k3s/token \
  --with-decryption --query Parameter.Value --output text)"
# One node per apply. The agent first, then a follower, the leader last.
terraform -chdir=platform plan -replace='aws_instance.k3s_worker'
terraform -chdir=platform apply -replace='aws_instance.k3s_worker'
```

After the new node is Ready, delete the old Node object if it lingers:

```bash
kubectl get nodes --no-headers | awk '$2=="NotReady"{print $1}'
```

## Verify

```bash
kubectl get nodes
kubectl get --raw /healthz/etcd
scripts/doctor.sh
```
