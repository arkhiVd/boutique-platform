# Final state, captured before and after teardown (2026-10-18)

Screenshots of the running platform, taken headless just before the Phase 14
teardown returned the account to $0. Every terminal shot is a real command run
against the live cluster at capture time (the prompt line is the command, as
typed), rendered to an image; the two marked *recorded* replay an earlier run's
saved output because a live re-run takes ten minutes or more. Browser shots are
headless Chromium against the real endpoints: the shop through the public ALB,
Grafana and Jenkins logged in through a local auth proxy, Prometheus and
Alertmanager through port-forwards.

## Terminal

| shot | shows |
|---|---|
| `terminal/01-nodes.png` | four nodes Ready across us-east-1a/b/c: three etcd servers, one agent |
| `terminal/02-ec2.png` | the same four instances in EC2: one c7i-flex.large, three t3.small |
| `terminal/03-boutique-pods.png` | every Online Boutique pod Running and Ready, spread across nodes |
| `terminal/04-helm.png` | the platform's Helm releases, all deployed |
| `terminal/05-doctor.png` | `scripts/doctor.sh`: PASS 9 / WARN 4 / FAIL 0 |
| `terminal/06-terraform-plan.png` | both Terraform stacks: no changes, the account matches the code |
| `terminal/07-check.png` | `scripts/check.sh`: lint, secret scan, policy, schema |
| `terminal/08-runbook-check.png` | *recorded*: every runbook command executed live, 12/12 pass |
| `terminal/09-etcd-restore.png` | *recorded*: the real S3 etcd snapshot restored, shop serving in 555 s |
| `terminal/10-edge.png` | the ALB: http→https, and the shop, Grafana and Jenkins host routes |
| `terminal/11-policy.png` | Pod Security `restricted` rejecting a privileged pod |
| `terminal/12-quota.png` | every HPA's ceiling fits its namespace ResourceQuota |
| `terminal/13-cost.png` | `scripts/cost-estimate.sh` for the running shape |
| `terminal/14-alert-delivery.png` | Alertmanager → SNS notifications sent; one confirmed subscriber |
| `terminal/15-trace.png` | one checkout trace in Tempo and the seven services it touched |
| `terminal/16-logs.png` | log lines per service shipped to Loki over 24 h |
| `terminal/17-metrics.png` | every scrape target up, node-exporter 4/4, edge SLO series live |
| `terminal/18-teardown-inventory.png` | the teardown's inventory: 135 Terraform resources, 6 CSI volumes, 4 buckets, 4 nodes |
| `terminal/19-teardown-run.png` | the final teardown run: platform and bootstrap destroyed, CI told |
| `terminal/20-account-empty.png` | afterwards: no instance, bucket, load balancer, volume, IP, VPC, role or OIDC provider left |

## Browser

| shot | shows |
|---|---|
| `browser/01-shop-home.png`, `02-shop-product.png` | the shop through the public ALB |
| `browser/10-grafana-platform-overview.png` | the platform overview dashboard |
| `browser/11-grafana-golden-signals.png` | edge golden signals, error budget and burn rate |
| `browser/12-grafana-traces.png` | Tempo service graph, RED from spans, pipeline health |
| `browser/13-grafana-cost-capacity.png` | cost and node capacity |
| `browser/14-grafana-ci-health.png` | Jenkins pipeline health |
| `browser/20-prometheus-alerts.png` | Prometheus alert rules and what was firing |
| `browser/21-alertmanager.png` | Alertmanager |
| `browser/22-jenkins.png`, `23-jenkins-config-as-code.png` | Jenkins, configured as code |

## Read with

- The latency-SLO ticket in `20-prometheus-alerts.png` is an artifact of the fix
  sequence on 2026-10-18: for a few minutes the 1.2 s bucket did not exist yet, so
  every edge request counted as slow, and that sits inside the 6 h and 3 d windows.
  Live edge p95 was about 0.2 s.
- The edge SLIs see only traffic that comes through the ALB; the load generator
  calls the frontend inside the cluster. With little edge traffic a 5-minute
  ratio can be empty (NaN) and a p95 is set by a handful of requests.
- `docs/evidence/README.md` lists, per exit criterion, what is proven and what is
  not.
