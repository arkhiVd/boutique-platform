# Runbook — the bill is higher than it should be

**Last verified: 2026-10-17** — every fenced command below was executed by
`scripts/check-runbooks.py` against the live account: reads run for real, writes
recognised and not run (output in `docs/evidence/phase-13/runbook-check.txt`).

The guard is the `boutique-platform-monthly` Budget ($30), which emails the
`boutique-platform-alerts` topic. The expected spend for the running shape is
`scripts/cost-estimate.sh` (about $129/month, covered by credits); a spike is the
difference between what Cost Explorer says and what that script says.

## Diagnostic entry point

```bash
# What the shape SHOULD cost, priced from this repo.
scripts/cost-estimate.sh

# What the Budget has seen this month, against its limit.
aws budgets describe-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget-name boutique-platform-monthly \
  --query 'Budget.{Limit:BudgetLimit.Amount,Actual:CalculatedSpend.ActualSpend.Amount,Forecast:CalculatedSpend.ForecastedSpend.Amount}'

# The last seven days, by service, unblended (what is actually charged).
aws ce get-cost-and-usage \
  --time-period "Start=$(date -u -d '-7 days' +%F),End=$(date -u +%F)" \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[-1].Groups[?to_number(Metrics.UnblendedCost.Amount)>`0.01`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output table
```

## 1. Find what is running that the shape does not include

```bash
# Instances: the shape is exactly four (1 x c7i-flex.large + 3 x t3.small).
aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Name`]|[0].Value]' --output table

# Volumes not attached to anything still bill.
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table

# Elastic IPs bill when they are NOT attached.
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table

# Snapshots pile up silently.
aws ec2 describe-snapshots --owner-ids self --query 'length(Snapshots)'
```

## 2. The usual causes on this platform

| symptom | cause | fix |
|---|---|---|
| EC2 higher than the estimate | a t3 node ran above its CPU baseline on **unlimited** credits | find it with `CPUSurplusCreditsCharged` below; the c7i-flex leader is the node that should carry load |
| EBS higher | a PVC was resized, or a released PV left its volume behind | `describe-volumes` above; delete only volumes no PV references |
| CloudWatch Logs higher | WAF logs in a burst of traffic | the log group's retention is set in `platform/edge.tf` |

```bash
# Surplus credits charged per t3 node over the last day (non-zero = billed CPU).
for id in $(aws ec2 describe-instances --filters Name=instance-type,Values=t3.small Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text); do
  echo "$id $(aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUSurplusCreditsCharged \
    --dimensions Name=InstanceId,Value="$id" --start-time "$(date -u -d '-1 day' +%FT%TZ)" \
    --end-time "$(date -u +%FT%TZ)" --period 86400 --statistics Sum --query 'Datapoints[0].Sum' --output text)"
done
```

## 3. Stop the spend now

The fastest lever that loses nothing: stop the load generator, which is what
drives CPU on an idle shop.

```bash
kubectl -n boutique scale deploy loadgenerator --replicas=0
```

The final lever is Phase 14's teardown: `terraform destroy` on `platform/` and
`bootstrap/`, behind its approval gate (ROADMAP "Approval gates").

## Verify

```bash
aws ce get-cost-and-usage --time-period "Start=$(date -u -d '-2 days' +%F),End=$(date -u +%F)" \
  --granularity DAILY --metrics UnblendedCost --query 'ResultsByTime[].[TimePeriod.Start,Total.UnblendedCost.Amount]' --output table
```
