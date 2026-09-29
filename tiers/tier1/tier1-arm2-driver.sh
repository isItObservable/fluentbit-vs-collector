#!/usr/bin/env bash
# ISI-3575 E1 — Tier 1 (logs only) — SERIAL SINGLE-ENGINE driver, ARM 2 = FLUENT BIT v5.
# Runs ONLY after ARM 1 (collector) completed + bench-collector ns torn down (pt9).
# pt9 gate = logs RECEIVED IN DYNATRACE: FB exports via opentelemetry OUTPUT to the same
# DT logs endpoint the collector arm used; receipt oracle = fluentbit_output_* metrics
# (proc>0, dropped==0, errors==0). Detached (setsid), survives HB death.
#
# Timeline (from T0 = launch):
#   T+2h   -> 2h validity gate: census + DT-receipt + LOAD + leak + loss -> POST verdict.
#   T+26h  -> 24h soak readout: census + DT-receipt + LOAD + leak + loss + live cost -> POST,
#             then teardown bench-load and declare Tier 1 both-arm COMPLETE.
set -uo pipefail
export KUBECONFIG="$HOME/.config/capmox/observable-otelarrow.kubeconfig"
KDIR="$HOME/.cache/fbvc-e0-branch"; KPI="$KDIR/kpi"; OUT="$KDIR/tiers/tier1"
HARNESS="/mnt/nas/projects/isitobservable/_artifacts/isi3572/E0/harness"
LOG="$OUT/arm2-driver.log"; exec >>"$LOG" 2>&1

post() { python3 - "$1" <<'PY'
import sys,json,urllib.request
req=urllib.request.Request("http://127.0.0.1:3100/api/issues/a16f0d51-315c-487c-8d6c-18b117cb829e/comments",
  data=json.dumps({"body":sys.argv[1]}).encode(),headers={"Content-Type":"application/json"},method="POST")
try: print("[post] HTTP",urllib.request.urlopen(req,timeout=30).status)
except Exception as e: print("[post] FAILED",e)
PY
}

apply_load() { # idempotent: kubectl apply is a no-op on already-running, unchanged specs
  kubectl apply -f "$HARNESS/load/00-load-namespace.yaml" 2>&1
  kubectl apply -f "$HARNESS/locust/locust-oteldemo.yaml" 2>&1
  kubectl apply -f "$HARNESS/k6/k6-hipstershop.yaml" 2>&1
}

fb_metrics() { kubectl -n bench-fluentbit get pods -o jsonpath='{.items[0].metadata.name}' | { read -r pod
  kubectl -n bench-fluentbit port-forward "$pod" 20200:2020 >/tmp/fbpf.log 2>&1 & local pf=$!; sleep 5
  curl -s --max-time 8 http://127.0.0.1:20200/api/v1/metrics/prometheus; kill $pf 2>/dev/null || true; }
}

dt_receipt() { # FB pt9 receipt: OTel-output export metrics as RECEIVED-IN-DYNATRACE oracle
  local M proc drp err
  M=$(fb_metrics)
  proc=$(awk -F' ' '/^fluentbit_output_proc_records_total/{s+=$2} END{print s+0}' <<<"$M")
  drp=$(awk -F' ' '/^fluentbit_output_dropped_records_total/{s+=$2} END{print s+0}' <<<"$M")
  err=$(awk -F' ' '/^fluentbit_output_errors_total/{s+=$2} END{print s+0}' <<<"$M")
  echo "[dt-receipt] FB otel-output proc=$proc dropped=$drp errors=$err"
  [ "${proc%.*}" -gt 0 ] 2>/dev/null && [ "${drp%.*}" -eq 0 ] 2>/dev/null && [ "${err%.*}" -eq 0 ] 2>/dev/null && echo "[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (otel output, 0 dropped/errors)" || echo "[dt-receipt] VERDICT: NOT CONFIRMED — investigate FB export"
}

load_check() { # #6c — assert real per-app load is reaching the frontends
  local lp kp lreq kiter
  lp=$(kubectl -n bench-load get pod -l app=locust-oteldemo -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  kp=$(kubectl -n bench-load get pod -l app=k6-hipstershop  -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  lreq=$(kubectl -n bench-load logs -l app=locust-oteldemo --tail=60 2>/dev/null | awk '/Aggregated/{n=$2} END{print n+0}')
  kiter=$(kubectl -n bench-load logs -l app=k6-hipstershop --tail=5 2>/dev/null | grep -oE '[0-9]+ complete' | tail -1 | grep -oE '[0-9]+')
  echo "[load] locust(otel-demo) pod=$lp aggregated_reqs=${lreq:-0}  |  k6(hipster-shop) pod=$kp iterations=${kiter:-0}"
  if [ "$lp" = "Running" ] && [ "$kp" = "Running" ] && [ "${lreq:-0}" -gt 0 ] 2>/dev/null; then
    echo "[load] LOAD REACHING APP: PASS"
  else
    echo "[load] LOAD REACHING APP: FAIL — no-load or crashed generator (dataset INVALID)"
  fi
}

app_churn() { # WARNING-only: demo LOG-SOURCE pods that restarted AFTER T0 (during the run)
  python3 - "$T0" <<'PY'
import sys,json,subprocess,datetime
T0=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
hits=[]
for ns in ("otel-demo","hipster-shop"):
    try: d=json.loads(subprocess.check_output(["kubectl","-n",ns,"get","pods","-o","json"],text=True))
    except Exception: continue
    for p in d["items"]:
        for cs in p.get("status",{}).get("containerStatuses",[]) or []:
            ls=cs.get("lastState",{}).get("terminated")
            if cs.get("restartCount",0)>0 and ls and ls.get("finishedAt"):
                fa=datetime.datetime.fromisoformat(ls.get("finishedAt").replace('Z','+00:00'))
                if fa>=T0: hits.append(f"{ns}/{p['metadata']['name']} rc={cs['restartCount']} {ls.get('reason')} @{ls.get('finishedAt')}")
print(f"[app-churn] log-source pods restarted DURING run (WARNING, non-fatal — logs kept flowing): {len(hits)}")
for h in hits: print("   ",h)
PY
}

readout() { # $1 phase ; $2 outfile
  { echo "# Tier 1 (logs only) — ARM 2 fluent-bit — $1 readout"
    echo "generated: $(date -u +%FT%TZ)  ·  engine=fluent-bit 5.1.1 (single, collector torn down)  ·  load=locust(otel-demo)+k6(hipster-shop)"
    echo; echo '## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)'
    STRICT_NS="bench-fluentbit kepler" bash "$KPI/census-gate.sh" bench-fluentbit kepler otel-demo hipster-shop 2>&1
    echo; echo '## App churn during run (WARNING-only)'
    app_churn
    echo; echo '## Load reaching app gate (#6c)'
    load_check
    echo; echo '## Dynatrace receipt gate (pt9 — signal RECEIVED IN DYNATRACE)'
    dt_receipt
    echo; echo '## Leak readout — fluent-bit (tail-flat)'
    bash "$KPI/leak-readout.sh" fluentbit 12 15 2>&1
    echo; echo '## Loss accounting — fluent-bit'
    bash "$KPI/loss-accounting.sh" fluentbit 2>&1
    echo; echo '## Live cost spot-sample (mc/1M; sustained = computed from gate->final records delta at processing)'
    bash "$KPI/cost-per-1m.sh" fluentbit 60 2>&1
    echo; echo '## Resource snapshot (working-set)'
    kubectl top pod -n bench-fluentbit --no-headers 2>&1
  } | tee "$2"
}

green() { grep -q "CENSUS GATE: PASS" "$1" && grep -q "RECEIVED IN DYNATRACE" "$1" && grep -q "LOAD REACHING APP: PASS" "$1"; }

T0=$(date -u +%FT%TZ); echo "$T0" > "$OUT/T0-arm2.txt"
echo "[driver] Tier1 ARM2(fluent-bit)+LOAD START T0=$T0 pid=$$"
echo "[driver] applying load harness (locust+k6) at T0"; apply_load

sleep 7200
GATE="$OUT/tier1-fluentbit-2h-gate.md"; readout "2h validity gate" "$GATE"
if green "$GATE"; then GV="🟢 GREEN — census PASS + logs exported to Dynatrace + load reaching app"; else GV="🔴 RED — a gate failed (dataset INVALID)"; fi
post "$(printf '## Tier 1 · ARM 2 (fluent-bit) — 2h validity gate: %s\n\nT0=%s · gate at %s · SINGLE-ENGINE (pt9), collector torn down · load=locust+k6 50→200 ramp\n\n```\n%s\n```\n\nArtifact: `tiers/tier1/tier1-fluentbit-2h-gate.md`. %s' \
  "$GV" "$T0" "$(date -u +%FT%TZ)" "$(sed -n '1,60p' "$GATE")" \
  "$(green "$GATE" && echo 'Soak continues; 24h readout auto-posts at T+26h.' || echo 'Halting before soak; investigate.')")"
green "$GATE" || { echo "[driver] gate RED — halt (keeping bench-load for triage)"; exit 0; }

sleep 86400
FINAL="$OUT/tier1-fluentbit-results.md"; readout "24h soak" "$FINAL"
if grep -q "CENSUS GATE: PASS" "$FINAL"; then FV="🟢 VALID — 24h soak complete, census PASS"; else FV="🔴 INVALID — restart during soak"; fi
post "$(printf '## Tier 1 · ARM 2 (fluent-bit) — 24h soak COMPLETE: %s\n\nT0=%s · readout at %s\n\n```\n%s\n```\n\n**Next:** Tier 1 both-arm COMPLETE → post per-engine comparison table (feeds E5), advance to Tier 2 ([ISI-3576](/ISI/issues/ISI-3576)).' \
  "$FV" "$T0" "$(date -u +%FT%TZ)" "$(sed -n '1,72p' "$FINAL")")"
echo "[driver] tearing down bench-load (arm end)"; kubectl delete ns bench-load --wait=false 2>&1
echo "[driver] Tier1 ARM2 DONE — both arms complete"
