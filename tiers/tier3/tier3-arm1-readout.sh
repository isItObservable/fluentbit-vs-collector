#!/usr/bin/env bash
# ISI-3577 E3 ARM 1 — 24h soak readout (scheduled via systemd-run at 2026-09-13T23:05Z)
set -uo pipefail
export KUBECONFIG="$HOME/.config/capmox/observable-otelarrow.kubeconfig"
KDIR="$HOME/.cache/fbvc-e0-branch"; KPI="$KDIR/kpi"; OUT="$KDIR/tiers/tier3"
ISSUE="658650ae-4891-4893-9b69-c607bd594802"
T0="2026-09-12T21:00:47Z"
LOG="$OUT/arm1-readout.log"; exec >"$LOG" 2>&1

post() { python3 - "$1" "$ISSUE" <<'PY'
import sys,json,urllib.request
req=urllib.request.Request("http://127.0.0.1:3100/api/issues/%s/comments"%sys.argv[2],
  data=json.dumps({"body":sys.argv[1]}).encode(),headers={"Content-Type":"application/json"},method="POST")
try: print("[post] HTTP",urllib.request.urlopen(req,timeout=30).status)
except Exception as e: print("[post] FAILED",e)
PY
}

dt_receipt() {
  local sent_total=0 fail_total=0 pod lp M s f
  while read -r pod; do
    [ -z "$pod" ] && continue
    lp=$((18900 + RANDOM % 400))
    kubectl -n bench-collector port-forward "$pod" "$lp:8888" >/tmp/dtpf3.log 2>&1 & local pf=$!
    sleep 4
    M=$(curl -s --max-time 8 "http://127.0.0.1:$lp/metrics"); kill $pf 2>/dev/null || true
    s=$(awk '/^otelcol_exporter_sent_(log_records|metric_points|spans).*dynatrace/{s+=$2} END{print s+0}' <<<"$M")
    f=$(awk '/^otelcol_exporter_send_failed_(log_records|metric_points|spans).*dynatrace/{s+=$2} END{print s+0}' <<<"$M")
    echo "[dt-receipt] $pod sent=$s send_failed=$f"
    sent_total=$(awk -v a="$sent_total" -v b="$s" 'BEGIN{print a+b}')
    fail_total=$(awk -v a="$fail_total" -v b="$f" 'BEGIN{print a+b}')
  done < <(kubectl -n bench-collector get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  echo "[dt-receipt] TOTAL sent_to_DT=$sent_total send_failed=$fail_total (logs+metrics+traces)"
  awk -v s="$sent_total" -v f="$fail_total" 'BEGIN{
    print (s>0 && f==0) ? "[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (logs+metrics+traces exported, 0 send_failed)" \
                        : "[dt-receipt] VERDICT: NOT CONFIRMED — investigate export" }'
}

load_check() {
  local lp kp lreq kiter tgen
  lp=$(kubectl -n bench-load get pod -l app=locust-oteldemo -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  kp=$(kubectl -n bench-load get pod -l app=k6-hipstershop  -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  tgen=$(kubectl -n bench-load get pod -l app=tgen-traces   -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  lreq=$(kubectl -n bench-load logs -l app=locust-oteldemo --tail=60 2>/dev/null | awk '/Aggregated/{n=$2} END{print n+0}')
  kiter=$(kubectl -n bench-load logs -l app=k6-hipstershop  --tail=5  2>/dev/null | grep -oE '[0-9]+ complete' | tail -1 | grep -oE '[0-9]+')
  echo "[load] locust(otel-demo) pod=$lp reqs=${lreq:-0} | k6(hipster-shop) pod=$kp iters=${kiter:-0} | telemetrygen-traces pod=$tgen (@200 span/s)"
  if [ "$lp" = "Running" ] && [ "$kp" = "Running" ] && [ "$tgen" = "Running" ] && [ "${lreq:-0}" -gt 0 ] 2>/dev/null; then
    echo "[load] LOAD REACHING APP: PASS (app load + telemetrygen traces into engine OTLP)"
  else
    echo "[load] LOAD REACHING APP: FAIL — a generator is not Running (dataset INVALID)"
  fi
}

app_churn() { python3 - "$T0" <<'PY'
import sys,json,subprocess,datetime
T0=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')); hits=[]
for ns in ("otel-demo","hipster-shop"):
    try: d=json.loads(subprocess.check_output(["kubectl","-n",ns,"get","pods","-o","json"],text=True))
    except Exception: continue
    for p in d["items"]:
        for cs in p.get("status",{}).get("containerStatuses",[]) or []:
            ls=cs.get("lastState",{}).get("terminated")
            if cs.get("restartCount",0)>0 and ls and ls.get("finishedAt"):
                fa=datetime.datetime.fromisoformat(ls["finishedAt"].replace("Z","+00:00"))
                if fa>=T0: hits.append(f"{ns}/{p['metadata']['name']} rc={cs['restartCount']} {ls.get('reason')} @{ls['finishedAt']}")
print(f"[app-churn] log-source pods restarted DURING run (WARNING, non-fatal): {len(hits)}")
for h in hits: print("   ",h)
PY
}

green() { grep -q "CENSUS GATE: PASS" "$1" && grep -q "RECEIVED IN DYNATRACE" "$1" && grep -q "LOAD REACHING APP: PASS" "$1"; }

echo "[arm1-readout] START at $(date -u +%FT%TZ)"
FINAL="$OUT/tier3-collector-results.md"
{ echo "# Tier 3 (logs+metrics+traces, NO tail sampling) — ARM 1 collector v0.159.0 — 24h soak readout"
  echo "generated: $(date -u +%FT%TZ) · engine=collector (single, FB offline) · load=locust+k6+telemetrygen(traces@200,metrics@100)"
  echo "topology: DaemonSet(logs) + StatefulSet(metrics istiod+Kepler) + Deployment(traces OTLP) — TIER-3 delta = traces pipeline"
  echo; echo '## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)'
  STRICT_NS="bench-collector kepler" bash "$KPI/census-gate.sh" bench-collector kepler otel-demo hipster-shop 2>&1
  echo; echo '## App churn during run (WARNING-only)'; app_churn
  echo; echo '## Load reaching app gate (#6c)'; load_check
  echo; echo '## Dynatrace receipt gate (pt9 — logs+metrics+traces RECEIVED IN DYNATRACE)'; dt_receipt
  echo; echo '## Leak readout — collector (all components, tail-flat)'; bash "$KPI/leak-readout.sh" collector 12 15 2>&1
  echo; echo '## Loss accounting — collector (accepted vs sent, all signals)'; bash "$KPI/loss-accounting.sh" collector 2>&1
  echo; echo '## Resource snapshot (working-set, per component)'; kubectl top pod -n bench-collector --no-headers 2>&1
} | tee "$FINAL"

if grep -q "CENSUS GATE: PASS" "$FINAL"; then FV="🟢 VALID — 24h soak complete, census PASS"; else FV="🔴 INVALID — restart during soak"; fi
post "$(printf '## Tier 3 · ARM 1 (collector) — 24h soak COMPLETE: %s\n\nT0=%s · readout at %s\n\n```\n%s\n```\n\n**Next:** ARM 2 = Fluent Bit v5.1.1 — teardown collector arm + apply `tiers/tier3/fluentbit-tier3.yaml` (pt9 serial; resolve the gRPC/HTTP FB-ingress validation note first), 2h gate -> 24h soak. Then `tier3-comparison.md` -> E5 (ISI-3579).' \
  "$FV" "$T0" "$(date -u +%FT%TZ)" "$(sed -n '1,76p' "$FINAL")")"
echo "[arm1-readout] tearing down bench-load"; kubectl delete ns bench-load --wait=false 2>&1
echo "[arm1-readout] DONE — FB arm is the next manual step"
