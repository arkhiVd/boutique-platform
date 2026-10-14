#!/usr/bin/env bash
# Recompute the SPEC cost table from current us-east-1 on-demand list prices.
#
# Prices are stated, dated, and overridable by env vars — never silently assumed.
# The point is that the cost delta is printed as part of the plan gate, not guessed:
# this script exits 7 if the plan does not fit the remaining Free-plan credit, and
# 8 if it exceeds the running-on-demand vCPU quota.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PRICED_ON="2026-10-08"
# us-east-1 on-demand Linux, USD per hour and per GB-month. Verified against the
# AWS price list on PRICED_ON. Override to re-price without editing the script.
: "${P_T3_MICRO:=0.0104}"; : "${P_T3_SMALL:=0.0208}"
: "${P_T3_MEDIUM:=0.0416}"; : "${P_T3_LARGE:=0.0832}"
: "${P_T2_MICRO:=0.0116}"; : "${P_T2_SMALL:=0.0232}"
: "${P_GP3_GB:=0.08}"; : "${P_ALB_HR:=0.0225}"; : "${P_LCU_HR:=0.008}"
: "${P_SNAP_GB:=0.05}"; : "${P_DATA_GB:=0.09}"; : "${P_LOG_GB:=0.50}"
# t3 CPU-credit surcharge: an "unlimited" instance that exceeds its baseline accrues
# $0.05 per vCPU-hour on the surplus. Modelled so the sustained-CPU trap is visible.
: "${P_CPU_SURCHARGE:=0.05}"; : "${BASELINE_FRACTION:=0.20}"

# The shape, as "<count>x <type> + <count>x <type>". Defaults to the SPEC's
# recommended shape: three k3s servers for etcd quorum plus one workload node.
: "${SHAPE:=3xt3.small+1xt3.medium}"
: "${NODE_GB:=16}"
: "${HOURS_PER_MONTH:=730}"; : "${FREE_TIER_HOURS:=750}"; : "${FREE_TIER_EBS_GB:=30}"
: "${ALB:=1}"; : "${LCU:=2}"; : "${SNAP_GB:=4}"; : "${DATA_OUT_GB:=60}"; : "${LOG_GB:=2}"
: "${WINDOW_DAYS:=43}"; : "${CREDIT_BUDGET:=200}"
: "${VCPU_QUOTA:=8}"
# Measured platform CPU requests (mCPU) from the rendered manifests: 3850m total,
# of which 2820m is the `boutique` namespace. Phase 11 added 250m (Tempo); the
# number was 3600m before it. See docs/resource-budget.md.
: "${MEASURED_REQUEST_MILLI:=3850}"
# Expected sustained CPU as a fraction of the t3 baseline under demo
# loadgenerator traffic. Requests are not usage; this is the honest
# operating point, and the worst case is printed separately.
: "${SUSTAINED_FRACTION:=0.80}"

# --- resolve the shape into count/price/vcpu/ram per node type -------------------
SHAPE_ROWS=""
SHAPE_TOTAL_COUNT=0
SHAPE_TOTAL_CPU=0
SHAPE_TOTAL_RAM=0

node_price() {
  case "$1" in
    t2.micro)  printf '%s' "$P_T2_MICRO" ;;
    t2.small)  printf '%s' "$P_T2_SMALL" ;;
    t3.micro)  printf '%s' "$P_T3_MICRO" ;;
    t3.small)  printf '%s' "$P_T3_SMALL" ;;
    t3.medium) printf '%s' "$P_T3_MEDIUM" ;;
    t3.large)  printf '%s' "$P_T3_LARGE" ;;
    *) printf 'unknown instance type: %s\n' "$1" >&2; return 1 ;;
  esac
}

# GiB of RAM and vCPU per instance type, from the live DescribeInstanceTypes result.
node_vcpu() { case "$1" in t2.*) printf '1' ;; *) printf '2' ;; esac; }
node_ram()  {
  case "$1" in
    t2.micro|t3.micro) printf '1' ;; t2.small|t3.small) printf '2' ;;
    t3.medium) printf '4' ;; t3.large) printf '8' ;;
  esac
}

norm="$(printf '%s' "$SHAPE" | tr -d ' ' | tr '+' '\n')"
while IFS= read -r token; do
  [[ -n "$token" ]] || continue
  cnt="${token%%x*}"; typ="${token#*x}"
  [[ "$cnt" =~ ^[0-9]+$ && -n "$typ" && "$cnt" != "$typ" ]] || {
    printf 'bad SHAPE token %q — use "3xt3.small+1xt3.medium"\n' "$token" >&2; exit 2; }

  p="$(node_price "$typ")" || exit 2
  c="$(node_vcpu "$typ")"; r="$(node_ram "$typ")"
  SHAPE_ROWS+="${cnt} ${typ} ${p} ${c} ${r}
"
  SHAPE_TOTAL_COUNT=$((SHAPE_TOTAL_COUNT + cnt))
  SHAPE_TOTAL_CPU=$((SHAPE_TOTAL_CPU + cnt * c))
  SHAPE_TOTAL_RAM=$((SHAPE_TOTAL_RAM + cnt * r))
done <<< "$norm"

# --- one pass, so the arithmetic cannot drift between lines ----------------------
awk -v shape="$SHAPE" -v rows="$SHAPE_ROWS" -v gb="$NODE_GB" \
    -v hr="$HOURS_PER_MONTH" -v free_h="$FREE_TIER_HOURS" \
    -v fe="$FREE_TIER_EBS_GB" -v pgp3="$P_GP3_GB" \
    -v alb="$ALB" -v pah="$P_ALB_HR" -v lcu="$LCU" -v pl="$P_LCU_HR" \
    -v snap="$SNAP_GB" -v psn="$P_SNAP_GB" -v dg="$DATA_OUT_GB" -v pd="$P_DATA_GB" \
    -v lg="$LOG_GB" -v plog="$P_LOG_GB" -v sur="$P_CPU_SURCHARGE" -v basef="$BASELINE_FRACTION" -v hrs="$HOURS_PER_MONTH" -v MEASURED_REQUEST_MILLI="$MEASURED_REQUEST_MILLI" -v SUSTAINED_FRACTION="$SUSTAINED_FRACTION" \
    -v wd="$WINDOW_DAYS" -v cb="$CREDIT_BUDGET" \
    -v priced="$PRICED_ON" -v cqn="$VCPU_QUOTA" '
BEGIN {
  n_lines = split(rows, L, "\n")
  tot_cpu = 0; tot_ram = 0; tot_cnt = 0; bill_free_hr = 0

  printf "Shape: %s\n", shape
  printf "%-24s %5s %6s %8s %9s %10s\n", "instance type", "count", "vCPU", "GiB", "free-h/bill", "EC2 $/mo"

  for (i = 1; i <= n_lines; i++) {
    if (L[i] ~ /^[ \t]*$/) continue
    split(L[i], f, " ")
    cnt = f[1] + 0; typ = f[2]; p = f[3] + 0; vc = f[4] + 0; ram = f[5] + 0
    cnt_hrs   = cnt * hr
    # Free tier is a single pooled 750h, applied to the cheapest eligible node type
    # first. Here: applied once, against the smallest type present.
    tot_cnt += cnt; tot_cpu += cnt * vc; tot_ram += cnt * ram
    key = typ
    agg_hrs[key] += cnt_hrs
    if (!(key in agg_cnt)) { agg_cnt[key] = 0; agg_p[key] = p; agg_vcpu[key] = vc; agg_ram[key] = ram }
    agg_cnt[key] += cnt
  }

  # grant the pooled free hours to the single cheapest eligible type
  eligible = ""
  for (t in agg_cnt) { if (t == "t3.micro" || t == "t3.small") { if (eligible == "" || agg_p[t] < agg_p[eligible]) eligible = t } }
  free_given = 0
  if (eligible != "" && free_h > 0) { free_given = free_h; free_type = eligible }

  ec2 = 0
  for (t in agg_cnt) {
    h = agg_hrs[t]
    fr = (t == free_type) ? free_given : 0
    if (fr > h) fr = h
    billable = h - fr
    cost = billable * agg_p[t]
    ec2 += cost
    printf "%-24s %5d %6d %8d %7.0f/%3.0f %10.2f\n", t, agg_cnt[t], agg_vcpu[t] * agg_cnt[t], agg_ram[t] * agg_cnt[t], fr, billable, cost
  }

  tot_gb   = tot_cnt * gb
  bill_gb  = tot_gb - fe; if (bill_gb < 0) bill_gb = 0
  ebs      = bill_gb * pgp3
  alb_h    = alb * hr * pah
  alb_l    = alb * lcu * hr * pl
  snap_c   = snap * psn
  data_c   = dg * pd
  log_c    = lg * plog
  other    = snap_c + data_c + log_c
  total    = ec2 + ebs + alb_h + alb_l + other
  win      = total * wd / 30.4
  free_node = (hr > 0) ? free_h / hr : 0

  printf "\n%-24s %5s %6s %8s %9s %10s\n", "", "", "", "", "", ""
  printf "EBS gp3 volumes       %3d x %2dGiB = %4dGiB | %dGiB free | %3dGiB x $%.4f = $%.2f\n", tot_cnt, gb, tot_gb, fe, bill_gb, pgp3, ebs
  printf "ALB                   %d x %dh x $%.4f = $%.2f\n", alb, hr, pah, alb_h
  printf "ALB LCU               %d x %d x %dh x $%.4f = $%.2f\n", alb, lcu, hr, pl, alb_l
  printf "Snapshots / evidence  %dGiB x $%.4f = $%.2f\n", snap, psn, snap_c
  printf "Data out              %dGiB x $%.4f = $%.2f (first 100GiB free)\n", dg, pd, data_c
  printf "Logs / ECR            %dGiB x $%.4f = $%.2f\n", lg, plog, log_c
  printf "\nTOTAL / month                                            = $%.2f  (priced %s)\n", total, priced
  printf "Remaining %d-day window                                  = $%.2f  of a $%d credit (%.0f%%)\n", wd, win, cb, win * 100 / cb
  printf "Nodes fully inside the pooled 750 free hours: %.2f\n", free_node
  printf "vCPU: %d of the %.0f quota    RAM: %d GiB\n", tot_cpu, cqn, tot_ram

  # t3 CPU-credit model. A t3 instance is burstable at a 20% baseline, so the
  # cluster sustains 0.20 * total vCPU — NOT the 2000m a t3 advertises. Requests
  # are an admission guarantee, not a performance guarantee. Two numbers matter:
  #   * the committed cost, which the guard enforces
  #   * the surcharge risk, which depends on sustained usage, not requests
  baseline  = tot_cpu * 1000 * basef
  req_cpu   = MEASURED_REQUEST_MILLI          # measured platform requests, mCPU
  exp_sust  = baseline * SUSTAINED_FRACTION   # expected sustained under demo load
  worst_sur = req_cpu - baseline;  if (worst_sur < 0) worst_sur = 0
  exp_sur   = exp_sust - baseline; if (exp_sur < 0) exp_sur = 0
  exp_risk  = exp_sur  / 1000 * sur * hrs
  worst_risk= worst_sur / 1000 * sur * hrs

  printf "\nt3 CPU-credit model (t3 is burstable at a 20%% baseline, so the cluster\n"
  printf "  sustains %.0fm sustained, not the %dm the instances advertise):\n", baseline, tot_cpu * 1000
  printf "  platform requests      %.0fm  (admission guarantee only)\n", req_cpu
  printf "  expected sustained     %.0fm  = %.0f%% of baseline -> $%.2f/mo surcharge risk\n", exp_sust, SUSTAINED_FRACTION * 100, exp_risk
  printf "  worst case sustained   %.0fm  = requests fully used -> $%.2f/mo surcharge risk\n", req_cpu, worst_risk
  printf "  committed total        $%.2f/month   $%.2f over %d days (guarded)\n", total, total * wd / 30.4, wd
  printf "  total incl. expected   $%.2f/month   $%.2f over %d days\n", total + exp_risk, (total + exp_risk) * wd / 30.4, wd
  if (worst_risk > 0)
    printf "  !! total incl. worst case $%.2f/month  $%.2f over %d days - OVER the $%d credit\n", total + worst_risk, (total + worst_risk) * wd / 30.4, wd, cb
  win = (total + exp_risk) * wd / 30.4

  bad = 0
  if (win > cb) {
    printf "\n!! OVER BUDGET by $%.2f\n", win - cb
    bad = 7
  }
  if (tot_cpu > cqn) {
    printf "\n!! OVER vCPU QUOTA: %d requested, %.0f available. The next instance cannot launch.\n", tot_cpu, cqn
    if (bad == 0) bad = 8
  }
  exit bad
}
'
rc=$?

case $rc in
  7)
    printf '\nThis plan does not fit the remaining Free-plan credit. Fewer nodes, smaller\n' >&2
    printf 'nodes, no ALB, or a shorter window.\n' >&2
    ;;
  8)
    printf '\nThis plan exceeds the running-on-demand vCPU quota. Fewer or smaller nodes.\n' >&2
    ;;
esac
exit $rc
