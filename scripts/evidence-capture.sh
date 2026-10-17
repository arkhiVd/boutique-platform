#!/usr/bin/env bash
# ===========================================================================
# evidence-capture.sh -- capture, from the live system, the proof for every
# ROADMAP exit criterion that can be checked by reading it. Read-only: the
# admission tests are server-side dry-runs, so the apiserver evaluates the
# request against Pod Security and the LimitRange and nothing is created.
#
# Writes docs/evidence/live/<UTC date>/<NN-name>.txt, one file per criterion
# group, each starting with the command that produced it. docs/evidence/README.md
# indexes what each file proves and names the criteria that are NOT provable
# this way (pipeline runs, fault injection), so absence is visible.
#
# Requires: the SSM-tunnelled KUBECONFIG, AWS credentials, terraform, jq, curl.
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Every recorded command is relative to the repository root, so the evidence
# reads the same on any machine and names no home directory.
cd "$ROOT" || exit 1
OUT="${OUT:-$ROOT/docs/evidence/live/$(date -u +%F)}"
mkdir -p "$OUT"
NS=observability
PROM=/api/v1/namespaces/$NS/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1
LOKI=/api/v1/namespaces/$NS/services/loki:3100/proxy/loki/api/v1
TEMPO=/api/v1/namespaces/$NS/services/tempo:3200/proxy/api
tf() { terraform -chdir=platform output -raw "$1"; }

# cap <file> <title> -- <command...>: run, record the command and its output.
cap() {
  local file="$1" title="$2"; shift 3
  {
    printf '# %s\n# %s\n$ %s\n' "$title" "$(date -u +%FT%TZ)" "$*"
    "$@" 2>&1
    printf 'exit=%s\n\n' "$?"
  } >>"$OUT/$file"
}
promq() { kubectl get --raw "$PROM/query?query=$(jq -rn --arg q "$1" '$q|@uri')" | jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(",")) \(.value[1])"'; }

: >"$OUT/.started"
rm -f "$OUT"/*.txt

# --- Phase 0/1: plans empty, budget, cost ------------------------------------
TOKEN_FOR_PLAN="$(aws ssm get-parameter --name /boutique-platform/k3s/token --with-decryption --query Parameter.Value --output text)"
export TF_VAR_k3s_token="$TOKEN_FOR_PLAN"
plan_empty() { terraform -chdir="$1" plan -input=false -no-color -lock=false -detailed-exitcode >/dev/null 2>&1; local rc=$?; echo "terraform -chdir=$1 plan -detailed-exitcode -> $rc (0 = no changes)"; return $rc; }
cap 01-plans.txt "Phase 0/1/2: a second plan is empty after apply" -- plan_empty bootstrap
cap 01-plans.txt "Phase 2-5: platform plan is empty after apply" -- plan_empty platform
unset TF_VAR_k3s_token TOKEN_FOR_PLAN
cap 02-cost.txt "Phase 1: the Budget and its thresholds" -- aws budgets describe-budgets \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit.Amount,Unit:BudgetLimit.Unit}' --output table
cap 02-cost.txt "Phase 1: the estimate for the running shape" -- scripts/cost-estimate.sh

# --- Phase 2/3: network, nodes, SSM-only -------------------------------------
cap 03-nodes.txt "Phase 3: nodes Ready across three AZs" -- kubectl get nodes -o wide -L topology.kubernetes.io/zone,boutique.io/role
# The account also holds other projects' key pairs; what matters here is that
# no node of THIS platform was launched with one.
mapfile -t NODE_IDS < <(terraform -chdir=platform output -json node_instance_ids | jq -r '.. | strings')
cap 03-nodes.txt "Phase 3: no platform node has an EC2 key pair (access is SSM only)" -- aws ec2 describe-instances \
  --instance-ids "${NODE_IDS[@]}" \
  --query 'Reservations[].Instances[].[InstanceId,KeyName]' --output text
cap 03-nodes.txt "Phase 3: every node is SSM-managed and online" -- aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName]' --output table
cap 03-nodes.txt "Phase 2: no security group opens 22/tcp or the API to the world" -- aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values="$(tf vpc_id)" \
  --query "SecurityGroups[].IpPermissions[?contains(IpRanges[].CidrIp, '0.0.0.0/0')][].[FromPort,ToPort]" --output text

# --- Phase 4: admission and snapshots ----------------------------------------
privileged() { kubectl -n boutique run evidence-privileged --image=busybox:1.38.0 --restart=Never --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.38.0","securityContext":{"privileged":true}}]}}'; }
oversized() { kubectl -n boutique run evidence-oversized --image=busybox:1.38.0 --restart=Never --dry-run=server \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"busybox:1.38.0","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"resources":{"requests":{"cpu":"100m","memory":"4Gi"},"limits":{"cpu":"100m","memory":"4Gi"}}}]}}'; }
defaulted() { kubectl -n boutique run evidence-defaults --image=busybox:1.38.0 --restart=Never --dry-run=server -o jsonpath='{.spec.containers[0].resources}' \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"busybox:1.38.0","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'; echo; }
cap 04-policy.txt "Phase 4: a privileged pod is REJECTED by Pod Security (restricted)" -- privileged
cap 04-policy.txt "Phase 4: a pod over the LimitRange max is REJECTED" -- oversized
cap 04-policy.txt "Phase 4: a pod with no requests gets the LimitRange defaults (defaulted, not rejected)" -- defaulted
cap 04-policy.txt "Phase 4: etcd snapshots in S3" -- aws s3 ls "s3://$(tf etcd_snapshot_bucket)/etcd-snapshots/"

# --- Phase 5: edge -------------------------------------------------------------
ALB="$(tf alb_dns_name)"
code() { curl -sk -o /dev/null -w "%{http_code} $1\n" -H "Host: $2" "$1"; }
cap 05-edge.txt "Phase 5: http redirects to https" -- curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "http://$ALB/"
cap 05-edge.txt "Phase 5: the shop through the ALB" -- code "https://$ALB/" boutique.local
cap 05-edge.txt "Phase 5: Grafana host route, same ALB" -- code "https://$ALB/login" grafana.boutique.local
cap 05-edge.txt "Phase 5: Jenkins host route, same ALB" -- code "https://$ALB/login" jenkins.boutique.local
cap 05-edge.txt "Phase 5: SQL injection probe (Web ACL is in COUNT mode: 200 expected, the match is logged)" -- \
  code "https://$ALB/?id=1'%20OR%20'1'='1" boutique.local
cap 05-edge.txt "Phase 5: Web ACL action" -- terraform -chdir=platform output -raw waf_action
cap 05-edge.txt "Phase 5: ALB access log objects written in the last hour" -- bash -c \
  "aws s3 ls --recursive \"s3://\$(aws elbv2 describe-load-balancer-attributes --load-balancer-arn $(tf alb_arn) --query \"Attributes[?Key=='access_logs.s3.bucket'].Value\" --output text)/\" | awk -v t=\"\$(date -u -d '-1 hour' '+%F %T')\" '\$1\" \"\$2 >= t' | tail -3"

# --- Phase 6: the shop ---------------------------------------------------------
cap 06-boutique.txt "Phase 6: every workload Available" -- kubectl -n boutique get deploy
cap 06-boutique.txt "Phase 6: pods spread across AZs" -- bash -c \
  "kubectl -n boutique get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | sort | uniq -c"
cap 06-boutique.txt "Phase 6: containers without readOnlyRootFilesystem or runAsNonRoot (expect none)" -- bash -c \
  "kubectl -n boutique get pods -o json | jq -r '.items[] | .metadata.name as \$p | .spec.securityContext as \$ps | .spec.containers[] | select((.securityContext.readOnlyRootFilesystem != true) or ((.securityContext.runAsNonRoot // \$ps.runAsNonRoot) != true)) | \"\(\$p)/\(.name)\"' | sort -u; echo checked"

# --- Phase 9: metrics and alerting --------------------------------------------
cap 09-metrics.txt "Phase 9: request rate per service from span metrics (non-zero = traffic seen)" -- \
  promq 'sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))'
cap 09-metrics.txt "Phase 9: every scrape target up" -- promq 'count by (health) (up == 1) or count(up == 0)'
cap 09-metrics.txt "Phase 9: alerts firing now" -- bash -c \
  "kubectl get --raw '$PROM/alerts' | jq -r '.data.alerts[] | select(.state==\"firing\") | \"\(.labels.severity) \(.labels.alertname)\"' | sort | uniq -c"
cap 09-metrics.txt "Phase 9: Alertmanager SNS notifications sent and failed (since its start)" -- bash -c \
  "kubectl -n $NS exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- wget -qO- localhost:9093/metrics | grep -E '^alertmanager_notifications(_failed)?_total\\{integration=\"sns\"' | grep -v ' 0\$'"
cap 09-metrics.txt "Phase 9: the alert topic has a confirmed subscriber" -- aws sns get-topic-attributes \
  --topic-arn "$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':boutique-platform-alerts')].TopicArn" --output text)" \
  --query 'Attributes.{Confirmed:SubscriptionsConfirmed,Pending:SubscriptionsPending}'

# --- Phase 10: logs ------------------------------------------------------------
lokiq() { kubectl get --raw "$LOKI/query_range?query=$(jq -rn --arg q "$1" '$q|@uri')&limit=$2&since=${3:-1h}" \
  | jq -r '.data.result[] | .stream.app as $a | .values[] | "\($a) \(.[1][0:160])"' | head -"$2"; }
# productcatalogservice logs at startup only (upstream is silent per request:
# 8 lines in 24h against frontend's 700k), so the window is a day, not an hour.
cap 10-logs.txt "Phase 10: productcatalogservice lines retrievable from Loki (last 24h; it logs only at startup)" -- \
  lokiq '{namespace="boutique", app="productcatalogservice"}' 3 24h
cap 10-logs.txt "Phase 10: lines per app over 24h (every service ships)" -- bash -c \
  "kubectl get --raw '$LOKI/query?query=$(jq -rn '"sum by (app) (count_over_time({namespace=\"boutique\"}[24h]))"|@uri')' | jq -r '.data.result[] | \"\(.metric.app) \(.value[1])\"'"
cap 10-logs.txt "Phase 10: Loki label cardinality (series per label name)" -- bash -c \
  "kubectl get --raw '$LOKI/labels' | jq -r '.data | length' | sed 's/^/label names: /'"

# --- Phase 11: traces ----------------------------------------------------------
# Searched by the payment span, not by service: checkoutservice's own OTLP
# export calls are traces rooted at checkoutservice too, and a service search
# returns those first (one span, one service).
cap 11-traces.txt "Phase 11: a checkout trace (it contains a payment Charge) and the services it spans" -- bash -c \
  "id=\$(kubectl get --raw '$TEMPO/search?q=$(jq -rn '"{ span.rpc.method = \"Charge\" }"|@uri')&limit=1&start=$(( $(date +%s) - 3600 ))&end=$(date +%s)' | jq -r '.traces[0].traceID'); \
   echo trace \$id; kubectl get --raw '$TEMPO/traces/'\$id | jq -r '[.batches[].resource.attributes[] | select(.key==\"service.name\") | .value.stringValue] | unique | join(\" -> \")'"
cap 11-traces.txt "Phase 11: span-metrics series in Prometheus" -- promq 'count(traces_span_metrics_calls_total)'

# --- Phase 13: one verdict -----------------------------------------------------
cap 13-doctor.txt "Phase 13: doctor.sh" -- bash -c "KUBECONFIG_PATH=\"\$KUBECONFIG\" scripts/doctor.sh | sed 's/\x1b\[[0-9;]*m//g'"

rm -f "$OUT/.started"
echo "evidence written to ${OUT#"$ROOT"/}:"
for f in "$OUT"/*.txt; do printf '  %-18s %3s captures, %s non-zero exits\n' "$(basename "$f")" \
  "$(grep -c '^\$ ' "$f")" "$(grep -c '^exit=[1-9]' "$f")"; done
