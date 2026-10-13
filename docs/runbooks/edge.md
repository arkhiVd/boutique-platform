# Runbook — the edge (Phase 5)

**Last verified:** not yet — Phase 5 has no cluster. Every command below is one that
will be run and its output pasted into `docs/evidence/` on the first deploy. Until then the
commands are correct and untested; that state is the honest one.

The edge is two layers: an AWS ALB (TLS, Web ACL, access logs, HTTP→HTTPS redirect) and an
in-cluster Traefik DaemonSet (host routing, middlewares). A failure can live in either, and the
first job is always to find out which one.

## Diagnostic entry point

```bash
# Which layers answer, and from where?
curl -sSI http://<alb-dns>/                          # expect 301 to https
curl -sSI https://<frontend-host>/                    # expect 200

# The ALB's view of its targets. Unhealthy here = the problem is outside the cluster.
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform -chdir=platform output -raw traefik_target_group_http_arn)"

# The cluster's view: does Traefik exist and is it Ready on every node?
kubectl get daemonset -n traefik -o wide
kubectl get pods -n traefik -o wide

# Traefik's own health endpoint, from inside the cluster.
kubectl exec -n traefik daemonset/traefik -- wget -qO- http://localhost:8080/ping
```

The rule: if `describe-target-health` shows unhealthy targets, the problem is the ALB or the
node port. If the targets are healthy and `curl` through the ALB still fails, the problem is
Traefik or the backend.

---

## 1. The ALB marks every target unhealthy

**Symptom:** `curl https://<host>/` times out or 502s. `kubectl get pods -n boutique` shows
every pod Running. The ALB console shows 0 healthy targets.

**Most likely cause, in order:**

1. The health check path is wrong.
2. Traefik is not listening on the NodePort.
3. The node security group does not allow the ALB in on that port.

**Diagnose:**

```bash
# What does the target group actually check?
aws elbv2 describe-target-groups \
  --target-group-arns "$(terraform -chdir=platform output -raw traefik_target_group_http_arn)" \
  --query 'TargetGroups[0].{Path:HealthCheckPath,Port:HealthCheckPort,Matcher:Matcher,Interval:HealthCheckInterval,Timeout:HealthCheckTimeout,Unhealthy:UnhealthyThreshold}'

# Is Traefik listening on the node? Run this ON a node through SSM, not ssh:
aws ssm start-session --target "$(terraform -chdir=platform output -raw leader_instance_id)"
#   then, inside the session:
ss -tlnp | grep 32080
curl -sSI http://localhost:32080/ping

# Is the ALB security group allowed in?
aws ec2 describe-security-groups --group-ids "$(terraform -chdir=platform output -raw edge_security_group_id)" \
  --query 'SecurityGroups[0].IpPermissions'
```

**Fix:** the health check must be `/ping` with matcher `200` on port `32080`. If
`describe-target-groups` shows anything else, that is the defect — the value is in
`platform/edge.tf`'s `aws_lb_target_group.traefik_http`. `/ping` is Traefik's own endpoint and
does not depend on any application being up, which is the whole point: a health check that
depends on the app makes the ALB report the cluster down whenever the app is down.

**Escalate to this if the check looks right:** Traefik's readiness and liveness probe paths.
If both probe `/ping` and `/ping` fails from inside the pod, Traefik itself is broken and that
is a Phase 5 `cluster/traefik` problem, not an ALB one.

## 2. The Web ACL blocks a legitimate request

**Symptom:** a specific page or a specific request pattern 403s, everything else works.

**First: confirm the WAF did it.** A 403 from the WACL has a distinctive body
(`Request blocked by AWS WAF`). A 403 from the app does not.

```bash
# Which rule fired, for this request? The CloudWatch log holds the matched rule name.
aws logs filter-log-events \
  --log-group-name "/aws/waf/boutique-platform-edge" \
  --filter-pattern '{ $.terminatingRuleId != "none" }' \
  --start-time "$(( ($(date +%s) - 3600) * 1000 ))"

# Per-rule counts, to see whether it is one rule or a pattern.
aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 \
  --metric-name BlockedRequests \
  --dimensions Name=WebACL,Value=boutique-platform-edge Name=Rule,Value=common \
  --period 3600 --statistics Sum \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

**Fix:** this is why `waf_action` defaults to `count`. In count mode a false positive is a log
line, not an outage. The specific Boutique trigger that matters: the common rule set flags
`'` (an apostrophe) in a query string as SQLi. A product search for `O'Brien` is the real
world test case. Two courses, in this order:

1. Move the rule that false-positives to count-only, keeping the rest of the group blocking
   — WAF supports per-rule overrides.
2. Only if that is not enough, reduce the rule set.

Do not "fix" a false positive by turning the Web ACL off. That removes protection from every
other rule to unblock one.

## 3. The certificate expires

**Symptom:** browser or `curl -v` reports an expired certificate. `openssl s_client` shows
`Verify return code: 10 (certificate has expired)`.

```bash
# What does the ALB actually serve, and when does it expire?
echo | openssl s_client -connect <alb-dns>:443 2>/dev/null | openssl x509 -noout -subject -dates

# What is in ACM?
aws acm describe-certificate --certificate-arn "$(terraform -chdir=platform output -raw edge_certificate_arn)" \
  --query 'Certificate.{Status:Status,NotAfter:NotAfter,InUse:InUseBy}'
```

**Fix:**

- `self-signed` mode: regenerate with `bash scripts/tls/generate-selfsigned.sh` and re-import,
  then update the Terraform variables. The cert is 825 days, so expiry is a problem only if
  the platform outlives it.
- `http01` mode: cert-manager renews it. If `NotAfter` is past and still serving, the
  `Certificate`'s `ready` condition is False:

  ```bash
  kubectl get certificate -n traefik
  kubectl describe certificate tls-edge -n traefik
  kubectl get challenges -A
  ```

  The usual cause is the ACME HTTP-01 solver failing because the ALB's port-80 redirect
  intercepts the `/.well-known/acme-challenge/` path. That is a real conflict: the fixed-action
  redirect on port 80 sends the solver to HTTPS, where the challenge does not exist. If
  Phase 5 ships the http01 path, it needs a listener rule that excepts
  `/.well-known/acme-challenge/*` from the redirect, and that rule is the first thing to check.

## 4. Plaintext HTTP still reaches the app

**Symptom:** a request to `http://<node-ip>:32080/` returns 200 from the app rather than a
redirect.

That is the backstop case, and it is why `cluster/traefik` carries a `redirectScheme` middleware
on the web entry point as well as the ALB's own redirect. If both have failed:

```bash
kubectl get ingressroute -n traefik -o yaml | grep -A3 redirectScheme
```

The ALB redirect is the primary control; Traefik's is the second layer. Losing both means the
edge DNS was bypassed by hitting a node directly. Restricting the Traefik NodePorts to the ALB
security group (which `platform/security-groups.tf` already does) is the structural fix — if a
node IP is reachable from outside the VPC, that rule has stopped working.

## Rollback

The edge is Terraform-managed, so rollback is the previous commit plus a plan:

```bash
git revert <edge-commit>
./scripts/check.sh
terraform -chdir=platform plan    # read the destroys and replaces line by line
terraform -chdir=platform apply
```

The one thing that must be expected rather than reverted: a WAF rule that turns count into block.
Reverting the `waf_action` variable change is the correct rollback, and it is a variable, so it
needs no code change.

## Cost note

The ALB is the single largest optional cost line (~$28/month). It is the first thing to destroy
if the budget alarm fires:

```bash
terraform -chdir=platform destroy -target aws_lb.edge -target aws_wafv2_web_acl_association.edge
```

The app stays reachable on the Traefik NodePort, just without the Web ACL, the ALB access logs
or the forced HTTPS redirect.
