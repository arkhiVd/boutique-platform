# Service level objectives — Boutique platform

**Status: written 2026-10-09.** The SLIs, the PromQL, the windows and the policy
below are all present and machine-checked. What is NOT yet present is a live
measurement: no cluster exists, so every number here is a *definition*, not a
*measurement*. ROADMAP Phase 12's validation is where the firing alerts get
pasted. This document states which parts are which.

**Primary source:** Google SRE Workbook, Chapter 5, *Alerting on SLOs* —
<https://sre.google/workbook/alerting-on-slos/>

The workbook's own multiwindow multi-burn-rate table is the basis of
`observability/slos/`, and the error-budget policy below is modelled on
*Site Reliability Engineering* (the first book), Appendix B, *Postmortem
Culture: Learning from Failure* — specifically its error-budget policy framing.

---

## 1. The SLIs

Two SLIs per Boutique service. Both are measured at the **edge**, from Traefik's
per-service metrics, because that is the only place in this platform that sees
every request: the Boutique services have no `/metrics` endpoint (verified
absent across the vendored upstream `v0.10.7` tree — no Prometheus
instrumentation exists in any `src/`).

### SLI 1 — availability

| | |
|---|---|
| **Definition** | the fraction of HTTP requests to a Boutique service that complete with a status other than 5xx |
| **Numerator** | `sum by (job) (rate(traefik_service_requests_total{code!~"5..", service=~"^traefik-frontend-[0-9a-f]+@kubernetescrd$"}[5m]))` |
| **Denominator** | `sum by (job) (rate(traefik_service_requests_total{service=~"^traefik-frontend-[0-9a-f]+@kubernetescrd$"}[5m]))` |
| **Window** | 5m (the recording interval); 1h, 6h and 3d for the burn-rate alerts |
| **Target** | 99.9% over 30 days |
| **Error budget** | 0.1% over 30 days = 43m 12s of total outage |
| **Recorded as** | `sli:availability_good:ratio_rate5m` / `sli:availability_total:ratio_rate5m` in `observability/rules/boutique-slo-recording.yaml` |

**Why 4xx is excluded from both sides.** A 404 is a client mistake. Counting it
on the error side would let a broken script consume the availability budget with
zero user-visible impact, which is the fastest way to make an SLO worthless.
The same definition is used by `job:error_ratio:ratio` in the golden-signal
rules — two error definitions in one platform is how an SLO stops being
trusted.

**Why `job` and not `service` or `pod`.** The edge routes with IngressRoute CRDs,
so the Traefik `service` label is `<route-ns>-<route>-<hash>@kubernetescrd` (for
the shop: `traefik-frontend-<hash>@kubernetescrd`, measured 2026-10-18). The Traefik
ServiceMonitor sets `job` from the route name, so an SLI is a statement about a
*service*, not about a scrape target or a pod. The edge fronts one Boutique
service, so these SLIs are the frontend's: the user-facing request is the one an
SLO should be about. (Until 2026-10-18 the rules selected the Ingress provider's
`<ns>-<svc>-<port>@kubernetes` names, which this edge never emits, and every
SLI was empty.)

### SLI 2 — latency

| | |
|---|---|
| **Definition** | the fraction of HTTP requests to a Boutique service that complete in less than the latency objective |
| **Objective** | **1.2 seconds** |
| **Numerator** | `sum by (job, le) (rate(traefik_service_request_duration_seconds_bucket{le="1.2", service=~"^traefik-frontend-[0-9a-f]+@kubernetescrd$"}[5m]))` |
| **Denominator** | `sum by (job) (rate(traefik_service_requests_total{service=~"^traefik-frontend-[0-9a-f]+@kubernetescrd$"}[5m]))` |
| **Window** | 5m recording; 1h, 6h, 3d for the burn-rate alerts |
| **Target** | 99% of requests under 1.2s, over 30 days |
| **Error budget** | 1% over 30 days = 7h 12m |
| **Recorded as** | `sli:latency_good:ratio_rate5m` / `sli:latency_total:ratio_rate5m` |

**Why 1.2s, and this is the part to check first.** It is NOT a chosen number.
Traefik v3.7.13's default histogram buckets are `0.1, 0.3, 1.2, 5.0` seconds
(`pkg/observability/metrics/prometheus.go`, `Buckets: buckets`), so `le="1.2"` is
the *smallest "fast enough" boundary that exists* without changing Traefik's
configuration. With these buckets the reported p95 can only ever be 0.1, 0.3, 1.2
or 5.0 — "p95 is 1.2" means "p95 is somewhere in (0.3, 1.2]".

**The gap, recorded rather than papered over.** ROADMAP Phase 5 must set
`metrics.prometheus.buckets` in the k3s Traefik HelmChart `valuesContent` to a
finer set (`0.05, 0.1, 0.25, 0.5, 1, 2.5, 5`) for this SLI to be a real
measurement rather than a coarse one. Until then the latency SLI is
correct but coarse, and `boutique:latency_bucket_resolution_seconds` records the
fact (a value of 4 means the default buckets are in force). This is a Phase 5
action item, added to `TASKS.md`.

### SLI 3 — synthetic (external) availability

| | |
|---|---|
| **Definition** | the fraction of one-minute probes of the public frontend hostname that succeed |
| **Numerator** | `avg_over_time(probe_success{job="frontend-external"}[5m])` |
| **Denominator** | 1 (the probe is a gauge, so `avg_over_time`, not `rate`) |
| **Window** | 5m |
| **Target** | no SLO yet — see the note below |
| **Recorded as** | `synthetic:availability_ratio_rate5m` |

**Why this one has no SLO.** The probe's own availability is not an SLO for the
application; it is the *only* signal in the platform that covers the ALB, the
Web ACL and DNS, because every application metric is generated by the very thing
that is unreachable. Promoting it to an SLO with an error budget would let the
edge consume the application's budget, which is the wrong direction.

**One thing is missing and it is recorded.** The probe's target URL is a Phase 5
Terraform output; the blackbox chart's `platform.externalProbe.url` is empty
until Phase 5 provides it, so this SLI has no series today. See
`observability/blackbox/values.yaml`.

---

## 2. The burn-rate alerts

Three conditions per SLI, from the SRE Workbook Table 5.2. The arithmetic for a
99.9% availability target (budget = 0.1% = 43m 12s over 30 days):

| condition | long window | short window | burn rate | threshold | severity |
|---|---|---|---|---|---|
| 2% of the 30-day budget in 1 hour | 1h | 5m | 14.4 | `14.4 * 0.001` = **1.44%** | `page` |
| 5% in 6 hours | 6h | 30m | 6 | `6 * 0.001` = **0.6%** | `page` |
| 10% in 3 days | 3d | 2h | 1 | `1 * 0.001` = **0.1%** | `ticket` |

For the 99% latency target the budget is 10x larger, so the thresholds are 10x
larger: 14.4%, 6% and 1%.

**Why the two windows are `and`-ed, not merged.** The workbook's rule is that
the alert fires only when the condition holds in BOTH windows. A single 5-minute
blip moves the 5m window and nothing else; a slow six-hour bleed moves the 6h
window but not the 5m one. Only a real, current, sustained outage moves both.
That is the property that `observability/synthetic-tests/` proves: one synthetic
series fires the 14.4x page and does not fire the 6x ticket, because the two
windows sit in different places.

**One deviation, recorded.** The workbook's third row uses a 6h short window
against a 3d long window. These rules use 2h. The reason is memory: a 6h short
window in a burn-rate alert means `sum_over_time(...[6h])` evaluated at 30s over
13 jobs on a 4 GiB node, and the query buffer is the expensive part. 2h against
3d is still a 36:1 short/long ratio, which is the property that matters.

**The files.** `observability/slos/boutique-availability-slo.yaml` and
`observability/slos/boutique-latency-slo.yaml`. Rendered into PrometheusRules by
`observability/kube-prometheus-stack/templates/platform-rules.yaml`.

---

## 3. The error-budget policy

Modelled on the SRE Workbook's Appendix B framing, and scoped to what a
one-operator platform with a 43-day free-plan window can actually enforce.

### 3.1 The budget

- Availability: **0.1%** of requests over 30 days.
- Latency: **1%** of requests under 1.2s over 30 days.
- Both are computed from the recorded numerator/denominator, at the burn rates
  in §2, and are visible on the **Boutique golden signals** dashboard as
  `job:availability_error_budget_remaining_ratio` and
  `job:latency_error_budget_remaining_ratio`. A value of 1.0 is a full budget; 0
  means it is gone.

### 3.2 Stop shipping when the budget is consumed

**The rule.** If the remaining 30-day budget for *either* SLI reaches 0, feature
work stops until the budget recovers. This is the whole point of an error
budget: without it, "we are at 99.8% availability" is a number nobody acts on;
with it, it is a decision that has already been made.

**What "stop shipping" means for this platform.** The SPEC's build window is 43
days and the repo is the durable artifact, so a full stop is not the right
instrument. The concrete form, in order:

1. **The 1x ticket fires** (`BoutiqueAvailabilityErrorBudgetBurn`, `burn_rate:
   "1"`, `window: "2h/3d"`). It routes to `sns-ticket`, not to `sns-page`.
2. **New Platform work is suspended for the affected service.** The next merge
   to `main` that touches that service waits for the budget to recover, or
   carries an explicit note in the PR description that it ignores the budget and
   why.
3. **The next week's `mise-en-place` plan cannot include a feature for that
   service** until the recovered fraction is above 0.5.

**Why the ticket, not the page.** Consuming the budget at exactly the budget
rate is a *policy* action, not an emergency. The emergencies are the 14.4x and 6x
pages, which say the budget is going to be gone in 2 days or 5 days.

### 3.3 Postmortem when one incident eats more than 20%

**The rule.** If a single incident consumes more than **20%** of the 30-day error
budget for either SLI, a postmortem is written and merged to `docs/runbooks/`
before the incident is closed.

20% of the availability budget is 8m 38s of total outage in one incident, or
0.02% of requests. For the latency budget it is 1h 26m of slow requests, or 0.2%
of requests. These are the numbers to compare against when deciding whether to
write one.

**The postmortem is 20 minutes of work, not a week.** It is:

1. **What the monitoring caught, and when** — from Grafana screenshots of the
   **Boutique golden signals** dashboard.
2. **The timeline**, from LogQL (the exact path is
   `docs/runbooks/find-the-failing-checkout.md`).
3. **What made the incident worse** — the thing that turned 5 minutes into 40.
4. **One action item with an owner and a date.** Not a list of five.

**The trigger is measurable.** The burn-rate alerts compute it:
`job:availability_error_budget_remaining_ratio` dropping by 0.2 or more between
two adjacent evaluations is one incident eating 20% of the budget.

### 3.4 What happens to the demo target

The SPEC's teardown expectation is "destroy after validation", and the repo is
the durable artifact. So the policy has one extra clause:

- An incident that happens **during the live demo window** gets the postmortem;
  an SLO violation that happens because the demo cluster was destroyed on
  schedule does not, because the SLI is not measurable after teardown.

---

## 4. What is proven, and what is not

| claim | proof |
|---|---|
| Every rule file is syntactically valid | `promtool check rules observability/rules/*.yaml observability/loki/alerts.yaml` |
| Every SLI rule file is syntactically valid | `promtool check rules observability/slos/*.yaml` |
| The 14.4x page fires on a synthetic 3%-error series | `promtool test rules observability/synthetic-tests/*.yml` — three cases, all pass |
| The 6x and 1x tickets do NOT fire on that same series | same test |
| A 1-in-20 error rate for 10 minutes does not page | same test, case 2 |
| The alerts are routed page vs ticket | the Alertmanager route tree rendered by `helm template observability/kube-prometheus-stack` |
| The rules land in the cluster as PrometheusRules | `helm template` output names `boutique-availability-slo`, `boutique-latency-slo`, `boutique-golden-signals`, `boutique-slo-recording`, `loki-alerts` |
| **The alerts fire live in Alertmanager** | **NOT PROVEN.** Requires a cluster. ROADMAP Phase 12 validation. |
| **The SLO ratios are non-zero in a real query** | **NOT PROVEN.** Requires the Phase 5 edge to be generating traffic. |
| **The latency SLI is measured at the stated resolution** | **NOT PROVEN, and known-coarse** — see the 1.2s bucket limitation in §1. Phase 5 action item. |
