# Runbook — certificate expiry

**Last verified: 2026-10-17** — every fenced command below was executed by
`scripts/check-runbooks.py` against the live cluster: reads run for real, writes as
server-side dry-runs (output in `docs/evidence/phase-13/runbook-check.txt`).

Two sets of certificates, with very different clocks:

| certificate | issued by | lifetime | renewed by |
|---|---|---|---|
| k3s internal (apiserver, kubelet, etcd, client certs) | k3s's own CAs | 1 year; CAs 10 years | k3s, on restart, once a certificate is inside its renewal window |
| the edge (`boutique.local`, on the ALB) | `scripts/tls/generate-selfsigned.sh`, imported to ACM | until 2029-01-16 | re-running the script and re-importing |

`scripts/doctor.sh` prints both client and serving expiry in days; it is the
first thing to run.

## Diagnostic entry point

```bash
scripts/doctor.sh

# The apiserver's serving certificate, from the outside of the tunnel:
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}'
echo | openssl s_client -connect 127.0.0.1:16443 2>/dev/null | openssl x509 -noout -subject -enddate

# The edge certificate the ALB serves:
ALB="$(terraform -chdir=platform output -raw alb_dns_name)"
echo | openssl s_client -connect "$ALB:443" -servername boutique.local 2>/dev/null \
  | openssl x509 -noout -subject -enddate
aws acm describe-certificate --certificate-arn "$(terraform -chdir=platform output -raw edge_certificate_arn)" \
  --query 'Certificate.{Status:Status,NotAfter:NotAfter}'
```

## 1. k3s certificates close to expiry

k3s renews a certificate that is inside its renewal window when the server
restarts (`k3s certificate check` shows every date), so a rolling restart (one server at a time, `node-loss.md` section 2) renews them. To
renew explicitly, on each server in turn, in an SSM session:

```sh-node
k3s certificate check --output table
systemctl stop k3s
k3s certificate rotate
systemctl start k3s
```

Then refresh the operator kubeconfig: its client certificate is one of the ones
rotated. Copy `/etc/rancher/k3s/k3s.yaml` off the leader the way
`platform/README.md` describes and point its `server:` at
`https://127.0.0.1:16443`.

## 2. The edge certificate

```bash
# Regenerate and see what it would produce (the script prints its plan first).
bash -n scripts/tls/generate-selfsigned.sh
```

Re-import into the SAME ACM ARN so the ALB listener keeps its reference (`aws acm
import-certificate --certificate-arn ...`); a new ARN means a Terraform change to
the listener.

## Verify

```bash
scripts/doctor.sh
```
