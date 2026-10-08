# ADR-0002 — Two-layer edge: AWS ALB in front of in-cluster Traefik

- **Status:** accepted
- **Date:** 2026-10-08

## Context

Google's own production deployment of Online Boutique
(`.github/release-cluster/` in `GoogleCloudPlatform/microservices-demo`) is shaped as **two
layers**: an external HTTP(S) load balancer that terminates TLS, applies a security policy, and
hands off to an in-cluster ingress that does the routing. The Google doc
"Exposing service mesh applications through GKE Ingress" calls this "from edge to mesh", and
notes that **each layer needs its own health check** and that the edge hop is encrypted by
default while the second layer adds application-level visibility.

AWS offers two ways to reproduce it:

1. **One ALB, one layer.** The ALB talks directly to pods (via IP targets or a TargetGroup
   Binding from the AWS Load Balancer Controller). Cheaper and simpler.
2. **Two layers.** ALB → NodePort → in-cluster ingress (Traefik, already shipped by k3s), which
   then routes by Host and owns its own health checks and middleware.

Google's own manifests use the two-layer shape, and the platform's claim is a like-for-like
comparison with it.

## Decision

**Two layers.** An AWS ALB terminates TLS and applies the Web ACL, then forwards to a
target group on the Traefik NodePort across all nodes. Traefik routes by Host
(`frontend`, `grafana`, `jenkins`) and owns in-cluster health checks, retries and timeouts.

This is also the only option that works: the account **cannot create Network Load Balancers**
(`network-load-balancer-capacity-units = 0`; NLBs fail with
`OperationNotPermitted: This AWS account currently does not support load balancers`), so any
L4 entry is out.

## Consequences

- Two health checks to keep honest, exactly as the Google doc warns. Recorded as an explicit
  exit criterion in Phase 5: if the Traefik health check is wrong, the ALB marks targets
  unhealthy and the site goes down even though every pod is running.
- The ALB is the largest single cost line: $0.0225/hour + LCUs ≈ **$28/month**. Phase 5 and
  Phase 14 both treat it as destroyable, and the teardown plan removes it first.
- Both layers get access logs: ALB to S3, Traefik to Loki. Nothing about a request is
  invisible.
- No NAT gateway exists in this account (it would cost $32+/month), so the nodes and the ALB
  are both on public subnets. That is a Cost decision that pushes work onto the security layer:
  node security groups are explicit and narrow, and the Web ACL is the real DDoS control.

## Rejected

- **One ALB with pod IP targets:** abandons the second layer Google uses, and the AWS Load
  Balancer Controller has to be installed and maintained for no benefit when Traefik already
  exists.
- **Direct node-IP / NodePort entry, no ALB:** saves ~$28/month but loses TLS termination at a
  single auditable place, the Web ACL (so no SQLi blocking and no rate limiting), and access
  logs. Kept as the documented fallback if the budget needs it.
