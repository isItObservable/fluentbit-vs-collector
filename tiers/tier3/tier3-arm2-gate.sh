#!/usr/bin/env bash
# ISI-3577 E3 — ARM 2 (Fluent Bit v5.1.1) — 2h validity gate readout
# Scheduled via systemd-run at 2026-09-14T01:16Z (T0+2h)
export PATH="/home/hrexed/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export KUBECONFIG="$HOME/.config/capmox/observable-otelarrow.kubeconfig"
KDIR="$HOME/.cache/fbvc-e0-branch"; KPI="$KDIR/kpi"; OUT="$KDIR/tiers/tier3"
ISSUE="658650ae-4891-4893-9b69-c607bd594802"
T0="2026-09-13T23:14:00Z"
LOG="$OUT/arm2-gate.log"; exec >"$LOG" 2>&1

echo "[arm2-gate] START at $(date -u +%FT%TZ)"

post() { python3 - "$1" "$ISSUE" <<'PY'
import sys,json,urllib.request
req=urllib.request.Request("http://127.0.0.1:3100/api/issues/%s/comments"%sys.argv[2],
  data=json.dumps({"body":sys.argv[1]}).encode(),headers={"Content-Type":"application/json"},method="POST")
try: print("[post] HTTP",urllib.request.urlopen(req,timeout=30).status)
except Exception as e: print("[post] FAILED",e)
PY
}

fb_receipt() {
  local sent_total=0 fail_total=0 pod lp M s f
  while read -r pod; do
    [ -z "$pod" ] && continue
    lp=$((12900 + RANDOM % 400))
    kubectl -n bench-fluentbit port-forward "$pod" "$lp:2020" >/tmp/fb-pf-gate.log 2>&1 & local pf=$!
    sleep 4
    M=$(curl -s --max-time 8 "http://127.0.0.1:$lp/api/v1/metrics/prometheus")
    kill $pf 2>/dev/null || true
    s=$(echo "$M" | awk '/fluentbit_output_proc_records_total/{s+=$2} END{print s+0}')
    f=$(echo "$M" | awk '/fluentbit_output_dropped_records_total/{s+=$2} END{print s+0}')
    echo "[dt-receipt] $pod proc=$s dropped=$f"
    sent_total=$(awk -v a="$sent_total" -v b="$s" 'BEGIN{print a+b}')
    fail_total=$(awk -v a="$fail_total" -v b="$f" 'BEGIN{print a+b}')
  done < <(kubectl -n bench-fluentbit get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  echo "[dt-receipt] TOTAL proc_records=$sent_total dropped=$fail_total (logs+metrics+traces)"
  awk -v s="$sent_total" -v f="$fail_total" 'BEGIN{
    print (s>0 && f==0) ? "[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (all signals processed, 0 dropped)" \
                        : "[dt-receipt] VERDICT: CHECK — investigate output" }'
}

load_check() {
  local lp kp tgen lreq
  lp=$(kubectl -n bench-load get pod -l app=locust-oteldemo -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  kp=$(kubectl -n bench-load get pod -l app=k6-hipstershop  -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  tgen=$(kubectl -n bench-load get pod -l app=tgen-traces   -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  lreq=$(kubectl -n bench-load logs -l app=locust-oteldemo --tail=60 2>/dev/null | awk '/Aggregated/{n=$2} END{print n+0}')
  echo "[load] locust pod=$lp reqs=${lreq:-0} | k6 pod=$kp | tgen-traces pod=$tgen (--otlp-http :4318)"
  if [ "$lp" = "Running" ] && [ "$kp" = "Running" ] && [ "$tgen" = "Running" ] && [ "${lreq:-0}" -gt 0 ] 2>/dev/null; then
    echo "[load] LOAD REACHING APP: PASS"
  else
    echo "[load] LOAD REACHING APP: FAIL — a generator is not Running"
  fi
}

GATE_FILE="$OUT/tier3-fluentbit-2h-gate.md"
{
  echo "# Tier 3 (logs+metrics+traces, NO tail sampling) — ARM 2 FB v5.1.1 — 2h validity gate"
  echo "generated: $(date -u +%FT%TZ) · engine=fluentbit-v5.1.1 · load=locust+k6+telemetrygen(traces@200 --otlp-http :4318)"
  echo
  echo "## Census gate"
  kubectl get pods -n bench-fluentbit -o wide --no-headers 2>&1 | awk '{print $1, $4, $5}'
  kubectl get pods -n kepler --no-headers 2>&1 | awk '{print $1, $4, $5}'
  STRICT_NS="bench-fluentbit kepler" bash "$KPI/census-gate.sh" bench-fluentbit kepler otel-demo hipster-shop 2>&1
  echo
  echo "## Load check"; load_check
  echo
  echo "## DT receipt (FB output proc_records / dropped)"; fb_receipt
  echo
  echo "## Resource snapshot"
  kubectl top pods -n bench-fluentbit --no-headers 2>&1
} | tee "$GATE_FILE"

green() { grep -q "CENSUS GATE: PASS" "$1" && grep -q "LOAD REACHING APP: PASS" "$1" && grep -q "proc_records=" "$1"; }
if green "$GATE_FILE"; then GV="🟢 GREEN"; else GV="🔴 RED"; fi
post "$(printf '## Tier 3 · ARM 2 (FB v5.1.1) — 2h validity gate: %s\n\nT0=%s · gate at %s\n\n```\n%s\n```\n\n%s' \
  "$GV" "$T0" "$(date -u +%FT%TZ)" "$(cat "$GATE_FILE")" \
  "$(green "$GATE_FILE" && echo 'Soak continues — 24h readout at ~2026-09-15T01:16Z.' || echo 'Gate RED — halting. Investigate before proceeding.')")"
echo "[arm2-gate] DONE. Gate: $GV"
