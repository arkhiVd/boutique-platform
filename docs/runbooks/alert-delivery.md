# Runbook — alerts are firing but nobody gets them

**Last verified: 2026-10-17** — every fenced command below was executed by
`scripts/check-runbooks.py` against the live cluster: reads run for real, writes as
server-side dry-runs (output in `docs/evidence/phase-13/runbook-check.txt`). The
end-to-end path was proven the same day: an `amtool` test alert reached the
subscribed inbox.

The path is **Prometheus → Alertmanager → SNS topic `boutique-platform-alerts` →
email**. Alertmanager signs to SNS with the nodes' instance profile (no stored
credential). Every hop has failed once, silently:

| hop | how it failed (2026-10-17) | the check below that catches it |
|---|---|---|
| Alertmanager → SNS | 403: node role had no `sns:Publish`, and the topics it named never existed | `alertmanager_notifications_failed_total{reason="authError"}` |
| SNS accepts the message | 400 `Invalid parameter: Subject`: the default subject is over 100 chars | `reason="clientError"` |
| SNS → inbox | 0 confirmed subscriptions: the email was a GitHub noreply address | `SubscriptionsConfirmed` |

## Diagnostic entry point

```bash
# 1. Is Alertmanager sending, and failing? (counters since its start)
kubectl -n observability exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  wget -qO- localhost:9093/metrics | grep -E '^alertmanager_notifications(_failed)?_total\{integration="sns"'

# 2. What does it say about the last failure?
kubectl -n observability logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --since=1h \
  | grep -iE "notify|sns|error" | tail -5

# 3. Does the topic have a confirmed subscriber?
TOPIC="$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':boutique-platform-alerts')].TopicArn" --output text)"
aws sns get-topic-attributes --topic-arn "$TOPIC" \
  --query 'Attributes.{Confirmed:SubscriptionsConfirmed,Pending:SubscriptionsPending}'

# 4. Can the nodes publish? (the statement Alertmanager's signature relies on)
aws iam get-role-policy --role-name boutique-platform-node --policy-name boutique-platform-node-inline \
  --query 'PolicyDocument.Statement[?Sid==`AlertPublish`]'
```

(The `exec` lines are interactive for `check-runbooks.py`: it confirms the verb and
pod, it does not run them.)

## Fixes

- **authError (403):** apply `platform/` (the `AlertPublish` statement in
  `platform/iam-nodes.tf`), then wait one notification cycle.
- **clientError (400):** the receivers must use the `boutique.sns.subject` template
  (`observability/kube-prometheus-stack/values.yaml`); SNS rejects a subject over 100
  characters, with a line break, or non-ASCII.
- **no confirmed subscriber:** set a real inbox as `alert_email` in
  `bootstrap/terraform.tfvars` (gitignored), `terraform -chdir=bootstrap apply`,
  and click the link SNS emails. A pending subscription expires after three days.

## Verify end to end

```bash
# A test alert through the real path. It resolves on its own; expect a FIRING
# email within about a minute and a RESOLVED one a few minutes later.
kubectl -n observability exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 alert add RunbookDeliveryTest \
  severity=ticket namespace=observability 'summary="alert-delivery runbook test"'
```
