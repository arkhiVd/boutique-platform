# ADR-0001 — k3s on EC2, not EKS

- **Status:** accepted
- **Date:** 2026-10-08
- **Deciders:** Aravind

## Context

The platform needs a Kubernetes control plane. EKS is available in this account
(`aws eks list-clusters` returns `[]`, so the API is reachable) but its control plane costs
$0.10/hour = **$73/month**. The account is a Free-plan account with a **$200 credit over 6
months** and roughly **43 days of that window left** (the account was created 2026-05-20, so
the window ends ~2026-11-20).

Alternatives considered:

| Option | Monthly | 6-month |
|---|---|---|
| EKS control plane | $73.00 | $438 |
| k3s on EC2 | $0 control plane | $0 |
| kubeadm on EC2 | $0 control plane | $0 |

EKS also does not solve the harder constraint: the 8.0 vCPU quota and the 750 free-tier
instance-hours, which are identical whichever distribution runs.

## Decision

**k3s, self-managed on EC2**, with three servers for etcd quorum and one dedicated workload node.

Rationale beyond cost:

- k3s ships the pieces that kubeadm would make us assemble and debug by hand — Flannel CNI,
  Traefik, local-path storage, metrics-server, and etcd snapshots — as one binary.
- k3s's etcd is a standard etcd, so the operational vocabulary (snapshots, defrag, member add/
  remove, restore) transfers to EKS/kubeadm unchanged. The decision is reversible in skill, not
  in vendor.
- The API surface is plain Kubernetes. Nothing we build here is k3s-specific: every manifest we
  write works on EKS unchanged.
- kubeadm's per-node overhead (separate CNI, CSI driver, metrics-server, ingress install) pushes
  the memory floor to t3.medium per node, doubleing the EC2 line.

## Consequences

- We own node patching, upgrades, and the etcd backup schedule. EKS would have taken those.
  Mitigated by: `INSTALL_K3S_CHANNEL` pinning, a documented upgrade runbook, and etcd snapshots
  to S3 tested by a real restore drill in Phase 13.
- The two-layer edge is ALB → Traefik, not ALB → AWS LB Controller. Traefik is already inside
  k3s; the AWS Load Balancer Controller would be a second, redundant ingress.
- If this ever moves to EKS, the manifests are unchanged; only the node bootstrap changes.

## Rejected

- **EKS:** 3.5× the remaining budget on a control plane alone. Cost, not capability.
- **EKS Auto Mode:** priced on top of the same control plane; no additional benefit here.
- **kind / minikube:** gives no AWS footprint, so there is no edge, no ALB, no VPC and no SLO to
  prove. Fine for manifest development, wrong for a platform.
