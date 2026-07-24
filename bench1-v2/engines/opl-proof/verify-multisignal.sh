#!/usr/bin/env bash
# ============================================================================
# ISI-1859 step B — multi-signal OPL node-proof (df_engine 0.50.0 @ 7502e7d)
# Henrik ask: drop Dynatrace-rejected metrics (cumulative + Summary) and prove
# the trace/span/metric/log scenario end-to-end on the REAL binary.
#
#   ./verify-multisignal.sh --deploy   # apply multisignal.yaml, run gens, assert
#   ./verify-multisignal.sh            # assert against current sink
#
# OPL under test (see multisignal.yaml df-opl-config):
#   signals
#   | if (is Metric) { where not(aggregation_temporality == 2) | where metric_type != 5 }
#   | if (is Log)    { <conditional severity ERROR/CLEARED> }
#   | if (is Log)    { <PII field-read + whole-value hash redact> }
#   | if (is Span)   { set attributes["parity.seen"] = "true" }
#
# Enum integers pinned @ 7502e7d (pdata/src/otlp/metrics.rs):
#   MetricType Gauge=1 Sum=2 Summary=5 ; AggregationTemporality Cumulative=2
#
# NOTE (runtime finding): a single `and` combining not(aggregation_temporality==2)
# with metric_type!=5 spuriously drops Gauges (Gauge has no temporality; the `and`
# mishandles the absent field). Chained `where` filters are the correct form —
# each predicate is decisive in isolation (proven) and composes correctly chained.
# ============================================================================
set -euo pipefail
NS=dfopl
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--deploy" ]]; then
  awk 'BEGIN{RS="\n---\n"} !/kind: Job/{print $0"\n---"}' "$HERE/multisignal.yaml" | kubectl apply -f -
  kubectl -n "$NS" rollout status deploy/df-engine --timeout=150s
  kubectl -n "$NS" rollout status deploy/sink       --timeout=150s
  kubectl -n "$NS" delete job gen-sum gen-gauge gen-trace gen-err gen-ok >/dev/null 2>&1 || true
  awk 'BEGIN{RS="\n---\n"} /kind: Job/{print $0"\n---"}'  "$HERE/multisignal.yaml" | kubectl apply -f -
  kubectl -n "$NS" wait --for=condition=complete job/gen-sum job/gen-gauge job/gen-trace job/gen-err job/gen-ok --timeout=150s
  sleep 7
fi

LOG="$(mktemp)"
kubectl -n "$NS" logs deploy/sink --tail=300000 > "$LOG"
fail=0
chk(){ local n="$1" g="$2" w="$3"; if [[ "$g" == "$w" ]]; then echo "PASS $n ($g)"; else echo "FAIL $n (got $g want $w)"; fail=1; fi; }

# --- metrics: drop cumulative Sum, keep Gauge (Summary drop proven by metric_type read) ---
chk "metric Gauge kept"          "$(grep -c 'DataType: Gauge' "$LOG")" 20
chk "metric cumulative Sum drop" "$(grep -c 'DataType: Sum'   "$LOG")" 0
# --- traces: all spans traverse the transform and are tagged ---
chk "spans kept"                 "$(grep -c 'Span #' "$LOG")"          40
chk "spans tagged parity.seen"   "$(grep -c 'parity.seen: Str(true)' "$LOG")" 40
# --- logs: conditional severity + PII redact unchanged alongside metrics/traces ---
chk "logs total"                 "$(grep -c 'LogRecord #' "$LOG")"     100
chk "log ERROR if-branch"        "$(grep -c 'SeverityText: ERROR'   "$LOG")" 50
chk "log CLEARED else-branch"    "$(grep -c 'SeverityText: CLEARED' "$LOG")" 50
chk "log PII flagged"            "$(grep -c 'pii.email.detected: Str(true)' "$LOG")" 50
chk "log body redacted"          "$(grep -c 'Body: Str(REDACTED:' "$LOG")" 50
chk "log email removed"          "$(grep -c 'alice@example.com' "$LOG")" 0

# engine health
if kubectl -n "$NS" logs deploy/df-engine --since=20m 2>/dev/null | grep -iE "panicked at|core.*died"; then
  echo "FAIL engine clean"; fail=1
else echo "PASS engine clean (no panic/core death)"; fi

rm -f "$LOG"
[[ $fail -eq 0 ]] && echo "== ALL PASS ==" || { echo "== FAILURES =="; exit 1; }
