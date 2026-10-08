# ADR-0003 — No service mesh; the mTLS gap is named, not hidden

- **Status:** accepted
- **Date:** 2026-10-08

## Context

Google runs Online Boutique in production behind **Cloud Service Mesh** (Istio): namespace-label
based sidecar injection, a Gateway-API `Gateway` replacing the `frontend-external` LoadBalancer,
per-service `AuthorizationPolicy` in the Helm chart, and two `ServiceEntry` resources so egress
to `*.googleapis.com` and the metadata server survives the default egress lockdown. The mesh is
what gives them in-cluster mTLS and L7 authorization between services.

Reproducing that here would mean a sidecar per pod, an `istiod`, Envoy proxies, and roughly
150–250 MiB per pod of extra overhead.

The account's node budget is the constraint:

- Total RAM available on the recommended shape (3 × t3.small + 1 × t3.medium) is **10 GiB**
  against **~9.5 GiB** of workload requests — already tight before a sidecar is added.
- Total vCPU is 8.0, which is **the entire quota**.

A mesh would require either a larger node shape (taking the 6-month run rate to ~$180, 90% of
the credit) or dropping observability.

## Decision

**No service mesh.** In-cluster traffic is protected by NetworkPolicy instead: default-deny
with a per-service allow and an explicit DNS egress carve-out (which upstream *omits* — their
egress rules are `- {}`, wide open, in every policy except the deny-all).

Claiming otherwise would be false. The gap is recorded, with what would close it.

## Consequences — what is actually lost

| Capability | With Istio | Here | Closing it |
|---|---|---|---|
| mTLS between services | yes | **no** — pod-to-pod traffic is plaintext inside the VPC | Istio/Cilium mesh; needs a bigger node shape |
| L7 authorization between services | `AuthorizationPolicy` | port-level NetworkPolicy only | mesh, or a proxy sidecar per service |
| Traffic split for canary | VirtualService weights | Traefik weighted services (coarser) | Argo Rollouts, no mesh needed |
| mTLS from the internet | TLS at ALB | TLS at ALB, plaintext to the pod | TLS passthrough ALB → Traefik with a cert-manager cert |

## What mitigates it

- The VPC is the trust boundary, and the cluster is single-tenant: only one workload namespace
  plus CI and observability run here, with RBAC per namespace.
- The edge terminates TLS with a Web ACL, so the internet-facing path is as protected as
  Google's.
- Every pod runs non-root, read-only root filesystem, no privilege escalation, and no
  capabilities.
- NetworkPolicies mean a compromised `currencyservice` pod cannot reach `emailservice` or the
  CI namespace directly.

## Rejected

- **Istio sidecar:** needs ~200 MiB/pod extra. Boutique has 13 workloads. The node shape does
  not fit.
- **Ambient mesh / sidecarless Istio:** still needs a `ztunnel` per node plus the control plane,
  and the ambient APIs are not the same ones Google's manifests use.
- **mTLS only between edge and pod (TLS passthrough):** real but narrow, and it conflicts with
  the ALB health checks. Documented as a follow-up, not built here.
