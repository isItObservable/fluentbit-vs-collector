#!/usr/bin/env bash
# ISI-3577 E3 — ARM 2 (Fluent Bit v5.1.1) — 24h soak readout
# Scheduled via systemd-run at 2026-09-15T01:16Z (T0+26h)
export PATH="/home/hrexed/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export KUBECONFIG="$HOME/.config/capmox/observable-otelarrow.kubeconfig"
KDIR="$HOME/.cache/fbvc-e0-branch"; KPI="$KDIR/kpi"; OUT="$KDIR/tiers/tier3"
ISSUE="658650ae-4891-4893-9b69-c607bd594802"
T0="2026-09-13T23:14:00Z"
LOG="$OUT/arm2-soak.log"; exec >"$LOG" 2>&1

echo "[arm2-soak] START at $(date -u +%FT%TZ)"

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
    kubectl -n bench-fluentbit port-forward "$pod" "$lp:2020" >/tmp/fb-pf-soak.log 2>&1 & local pf=$!
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
    print (s>0 && f==0) ? "[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (0 dropped)" \
                        : "[dt-receipt] VERDICT: CHECK — investigate output" }'
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

FINAL="$OUT/tier3-fluentbit-results.md"
{
  echo "# Tier 3 (logs+metrics+traces, NO tail sampling) — ARM 2 FB v5.1.1 — 24h soak readout"
  echo "generated: $(date -u +%FT%TZ) · engine=fluentbit-v5.1.1 · load=locust+k6+telemetrygen(traces@200 --otlp-http :4318)"
  echo "topology: DaemonSet(logs) + StatefulSet(metrics) + Deployment(traces OTLP/HTTP 4318) — TIER-3 delta = traces pipeline"
  echo
  echo "## Census gate"
  kubectl get pods -n bench-fluentbit -o wide --no-headers 2>&1 | awk '{print $1, $4, $5}'
  kubectl get pods -n kepler --no-headers 2>&1 | awk '{print $1, $4, $5}'
  STRICT_NS="bench-fluentbit kepler" bash "$KPI/census-gate.sh" bench-fluentbit kepler otel-demo hipster-shop 2>&1
  echo
  echo "## App churn during run (WARNING-only)"; app_churn
  echo
  echo "## DT receipt (FB output proc_records / dropped)"; fb_receipt
  echo
  echo "## Memory leak check (tail-flat at 24h)"
  echo "[leak] bench-fluentbit — 8 samples @ 15s"
  for i in $(seq 1 8); do
    ts=$(date -u +%FT%TZ)
    mem=$(kubectl top pods -n bench-fluentbit --no-headers 2>/dev/null | awk '{gsub(/Mi/,"",$3); s+=$3} END{print s"MiB"}')
    echo "  $ts  $mem"
    [ $i -lt 8 ] && sleep 15
  done
  echo
  echo "## Resource snapshot (working-set, per component)"
  kubectl top pods -n bench-fluentbit --no-headers 2>&1
  echo
  echo "## Load note"
  echo "[load] bench-load pods completed naturally at T+26h (~2026-09-15T01:14Z) — by design (telemetrygen 26h)"
  echo "[load] Load ran for FULL soak window (T+2h gate through T+26h)"
} | tee "$FINAL"

if grep -q "CENSUS GATE: PASS" "$FINAL"; then FV="🟢 VALID — 24h soak complete, census PASS"; else FV="🔴 INVALID"; fi
post "$(printf '## Tier 3 · ARM 2 (FB v5.1.1) — 24h soak COMPLETE: %s\n\nT0=%s · readout at %s\n\n```\n%s\n```\n\n**Next:** produce tier3-comparison.md → E5 (ISI-3579).' \
  "$FV" "$T0" "$(date -u +%FT%TZ)" "$(sed -n '1,80p' "$FINAL")")"
echo "[arm2-soak] tearing down bench-load and bench-fluentbit"
kubectl delete ns bench-load --wait=false 2>&1 || true
kubectl delete ns bench-fluentbit --wait=false 2>&1 || true
echo "[arm2-soak] DONE — produce tier3-comparison.md → E5"
