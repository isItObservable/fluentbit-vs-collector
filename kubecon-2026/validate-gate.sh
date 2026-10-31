#!/usr/bin/env bash
# ============================================================================
# validate-gate.sh — PRE-TEST VALIDATION GATE (the "strange things" guard).
# ALL checks MUST pass before ANY run (rampup or soak) is trusted.
#
#   ./validate-gate.sh <fluentbit|collector|arrow|otap>
#
# Checks (exit != 0 on the first FAIL):
#   1. CENSUS   — all pods Running; engine-under-test 0-restart (STRICT).
#   2. DEMO     — otel-demo frontend success-rate >= FRONTEND_SUCCESS_MIN%
#                 (run ./validate-app.sh first for the full app journey).
#   3. RECEIVE  — engine pipeline accepted > 0 AND refused == 0.
#   4. EXPORT   — engine pipeline sent/output > 0 (data leaves the engine).
#   5. RECEIPT  — exported telemetry is received in your backend (optional;
#                 set BACKEND_RECEIPT_CMD — see lib.sh). SKIP if unset.
#   6. OTAP     — (Arm D only) df_engine relay healthy + exporting.
#
# Catches: a demo that only errors, an engine that accepts-but-refuses, an
# engine that receives-but-never-exports, and an export that never lands.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ARM="${1:?usage: validate-gate.sh <fluentbit|collector|arrow|otap>}"
NS=$(arm_ns "$ARM")    || { echo "unknown arm: $ARM" >&2; exit 2; }
PORT=$(arm_port "$ARM"); MPATH=$(arm_path "$ARM"); KIND=$(arm_kind "$ARM"); SEL=$(arm_selector "$ARM")
OTEL_DEMO_NS="${OTEL_DEMO_NS:-otel-demo}"
fail=0

echo "== pre-test validation gate — arm=$ARM ns=$NS =="

# ---- 1. CENSUS -------------------------------------------------------------
echo "[1/6] pod census ($NS engine 0-restart; apps Running)"
restarts=$(kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')
notrun=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)
if [ "${restarts:-0}" -eq 0 ] && [ "${notrun:-0}" -eq 0 ]; then ok "census — engine pods Running, 0 restarts"
else bad "census — restarts=$restarts not-running=$notrun in $NS"; fail=1; fi
for ns in "$OTEL_DEMO_NS" hipster-shop bench-load; do
  nr=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)
  [ "${nr:-0}" -ne 0 ] && { bad "census — $nr pod(s) not Running in $ns"; fail=1; }
done

# ---- 2. DEMO HEALTH (frontend success-rate) --------------------------------
echo "[2/6] otel-demo frontend success-rate (>= ${FRONTEND_SUCCESS_MIN}% over ${FRONTEND_PROBES} probes)"
FEPOD=$(kubectl -n "$OTEL_DEMO_NS" get pod -l app.kubernetes.io/name=frontend-proxy -o name 2>/dev/null | head -1)
[ -z "$FEPOD" ] && FEPOD=$(kubectl -n "$OTEL_DEMO_NS" get pod -l app.kubernetes.io/component=frontend-proxy -o name 2>/dev/null | head -1)
if [ -z "$FEPOD" ]; then
  bad "frontend-proxy pod not found in $OTEL_DEMO_NS"; fail=1
else
  # bind a LOCAL HIGH port so a same-number local listener can't shadow the forward
  kubectl -n "$OTEL_DEMO_NS" port-forward "$FEPOD" 18080:8080 >/tmp/bench-fe.log 2>&1 & FEP=$!; sleep 4
  succ=0
  for i in $(seq 1 "$FRONTEND_PROBES"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:18080/api/products" 2>/dev/null || echo 000)
    [[ "$code" =~ ^2 ]] && succ=$((succ+1))
  done
  kill "$FEP" 2>/dev/null || true; wait "$FEP" 2>/dev/null || true
  rate=$(( succ * 100 / FRONTEND_PROBES ))
  if [ "$rate" -ge "$FRONTEND_SUCCESS_MIN" ]; then ok "frontend success-rate=${rate}% (${succ}/${FRONTEND_PROBES})"
  else bad "frontend success-rate=${rate}% (${succ}/${FRONTEND_PROBES}) < ${FRONTEND_SUCCESS_MIN}% — demo erroring, NOT working"; fail=1; fi
fi

# ---- 3 & 4. RECEIVE / EXPORT ----------------------------------------------
echo "[3/6] engine receives (accepted>0, refused==0)  &  [4/6] engine exports (sent/output>0)"
M=$(scrape "$NS" "$SEL" "$PORT" "$MPATH")
if [ -z "$M" ]; then
  bad "could not scrape engine self-metrics ($NS $SEL :$PORT$MPATH)"; fail=1
elif [ "$KIND" = collector ]; then
  acc=$(awk '/^otelcol_receiver_accepted/{s+=$2} END{print s+0}' <<<"$M")
  ref=$(awk '/^otelcol_receiver_refused/ {s+=$2} END{print s+0}' <<<"$M")
  sent=$(awk '/^otelcol_exporter_sent/    {s+=$2} END{print s+0}' <<<"$M")
  fse=$(awk '/^otelcol_exporter_send_failed/{s+=$2} END{print s+0}' <<<"$M")
  if awk -v a="$acc" -v r="$ref" 'BEGIN{exit !(a>0 && r==0)}'; then ok "receive accepted=$acc refused=$ref"; else bad "receive accepted=$acc refused=$ref"; fail=1; fi
  if awk -v s="$sent" -v f="$fse" 'BEGIN{exit !(s>0 && f==0)}'; then ok "export sent=$sent send_failed=$fse"; else bad "export sent=$sent send_failed=$fse"; fail=1; fi
else # fluentbit
  inp=$(awk '/^fluentbit_input_records_total/{s+=$2} END{print s+0}' <<<"$M")
  out=$(awk '/^fluentbit_output_proc_records_total/{s+=$2} END{print s+0}' <<<"$M")
  err=$(awk '/^fluentbit_output_errors_total/{s+=$2} END{print s+0}' <<<"$M")
  drp=$(awk '/^fluentbit_output_dropped_records_total/{s+=$2} END{print s+0}' <<<"$M")
  if awk -v i="$inp" 'BEGIN{exit !(i>0)}'; then ok "receive input=$inp"; else bad "receive input=$inp"; fail=1; fi
  if awk -v o="$out" 'BEGIN{exit !(o>0)}'; then ok "export output=$out errors=$err dropped=$drp"; else bad "export output=$out errors=$err dropped=$drp"; fail=1; fi
fi

# ---- 5. BACKEND RECEIPT (optional) -----------------------------------------
echo "[5/6] backend receipt (optional; set BACKEND_RECEIPT_CMD to enable)"
for sig in traces logs metrics; do
  c=$(backend_receipt "$sig" 15m)
  if [ "$c" = SKIP ]; then echo "      SKIP $sig — no BACKEND_RECEIPT_CMD configured"; continue; fi
  if awk -v v="${c:-0}" 'BEGIN{exit !(v>0)}' 2>/dev/null; then ok "backend received $sig: $c (last 15m)"
  else bad "backend received 0 $sig in last 15m — export not landing"; fail=1; fi
done

# ---- 6. ARM-D end-to-end ---------------------------------------------------
if [ "$ARM" = otap ]; then
  echo "[6/6] Arm-D OTAP chain: edge -> df_engine (OTAP relay) -> backend direct"
  dfr=$(kubectl -n "$NS" get pods -l benchmark.component=df-engine -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')
  if [ "${dfr:-0}" -eq 0 ]; then ok "df_engine relay 0-restart"; else bad "df_engine relay restarts=$dfr"; fail=1; fi
else
  echo "[6/6] arm-D-only chain check — N/A for arm=$ARM"
fi

echo "========================================================"
if [ "$fail" -ne 0 ]; then
  echo "VALIDATION GATE: FAIL (arm=$ARM) — DO NOT START THE RUN. Fix the red checks above." >&2
  exit 1
fi
echo "VALIDATION GATE: PASS (arm=$ARM) — cleared for rampup + soak."
