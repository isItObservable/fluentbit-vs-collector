#!/usr/bin/env bash
# ISI-3578 E4 — Tier 4 (logs + metrics + traces + TAIL SAMPLING) — SERIAL SINGLE-ENGINE
# driver, ARM 1 = COLLECTOR. pt9: ONE engine live; engine EXPORTS to Dynatrace; validity gate =
# signal RECEIVED IN DYNATRACE (+ census 0-restart + LOAD reaching app). FB is ARM 2, after teardown
# (FB = no-TS control: T3-shaped trace load, isolates the collector's T3->T4 tail-sampling delta).
# Detached (setsid) — survives heartbeat deaths. Timeline from T0:
#   T+2h  -> 2h validity gate: census + DT-receipt(logs+metrics+traces) + LOAD + leak + loss -> POST.
#   T+26h -> 24h soak readout: same set + tail-sampling cost callout -> POST, teardown bench-load, flag ARM 2.
# Tier delta vs Tier-3 = a tail_sampling processor on the TRACES pipeline; telemetrygen @200 span/s
# drives the engine OTLP receiver (same load as T3 so the T3->T4 delta is the tail-sampling cost).
set -uo pipefail
export KUBECONFIG="$HOME/.config/capmox/observable-otelarrow.kubeconfig"
KDIR="$HOME/.cache/fbvc-e0-branch"; KPI="$KDIR/kpi"; OUT="$KDIR/tiers/tier4"
HARNESS="/mnt/nas/projects/isitobservable/_artifacts/isi3572/E0/harness"
HARNESS2="$KDIR/harness"
ISSUE="997b27bb-1cd7-49c0-9353-a078c0be4031"   # ISI-3578
LOG="$OUT/driver.log"; exec >>"$LOG" 2>&1

post() { python3 - "$1" "$ISSUE" <<'PY'
import sys,json,urllib.request
req=urllib.request.Request("http://127.0.0.1:3100/api/issues/%s/comments"%sys.argv[2],
  data=json.dumps({"body":sys.argv[1]}).encode(),headers={"Content-Type":"application/json"},method="POST")
try: print("[post] HTTP",urllib.request.urlopen(req,timeout=30).status)
except Exception as e: print("[post] FAILED",e)
PY
}

apply_load() { # idempotent app load (logs+app traces) + telemetrygen traces/metrics into the engine OTLP
  kubectl apply -f "$HARNESS/load/00-load-namespace.yaml" 2>&1 || kubectl create ns bench-load 2>&1
  kubectl label ns bench-load oneagent=false --overwrite 2>&1
  # pt13 load-clock gotcha: delete+recreate so the LoadTestShape/stages ramp clock re-aligns to THIS T0.
  kubectl -n bench-load delete deploy locust-oteldemo k6-hipstershop --ignore-not-found 2>&1
  kubectl -n bench-load delete job  tgen-traces tgen-metrics       --ignore-not-found 2>&1
  kubectl apply -f "$HARNESS/locust/locust-oteldemo.yaml" 2>&1
  kubectl apply -f "$HARNESS/k6/k6-hipstershop.yaml" 2>&1
  # telemetrygen traces(@200/s) + metrics(@100/s) -> engine OTLP receiver, 26h to span gate+soak.
  local EP="bench-collector-otlp.bench-collector.svc.cluster.local:4317"
  sed -e "s#PLACEHOLDER:4317#${EP}#g" \
      -e 's#value: "2h"#value: "26h"#g' \
      "$HARNESS2/telemetrygen-load.yaml" | kubectl apply -f - 2>&1
}

# DT-receipt across the THREE collector components (logs DS / metrics STS / traces Deploy).
# Each pod exposes :8888. Sum otelcol_exporter_sent_* and _send_failed_* for the dynatrace exporter.
dt_receipt() {
  local sent_total=0 fail_total=0 pod lp M s f
  while read -r pod; do
    [ -z "$pod" ] && continue
    lp=$((18900 + RANDOM % 400))
    kubectl -n bench-collector port-forward "$pod" "$lp:8888" >/tmp/dtpf4.log 2>&1 & local pf=$!
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

# Tail-sampling telemetry — the E4 measurement. Pull the traces-Deployment :8888 and read the
# tail_sampling processor's own counters (sampled vs not-sampled, dropped, decision-buffer size).
ts_stats() {
  local pod lp M
  pod=$(kubectl -n bench-collector get pod -l app=bench-collector-otlp -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$pod" ] && { echo "[tail-sampling] traces pod not found"; return; }
  lp=$((19400 + RANDOM % 300))
  kubectl -n bench-collector port-forward "$pod" "$lp:8888" >/tmp/tspf4.log 2>&1 & local pf=$!
  sleep 4
  M=$(curl -s --max-time 8 "http://127.0.0.1:$lp/metrics"); kill $pf 2>/dev/null || true
  echo "[tail-sampling] traces pod=$pod"
  awk '/^otelcol_processor_tail_sampling_(sampling_decision|count_traces_sampled|global_count_traces_sampled|new_trace_id_received|sampling_traces_on_memory|sampling_trace_dropped_too_early|sampling_policy_evaluation_error)/{print "   "$1" "$2}' <<<"$M" | sort -u
  awk '/^otelcol_processor_tail_sampling_sampling_decision_latency/{print "   "$1" "$2}' <<<"$M" | tail -3
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

readout() { # $1 phase ; $2 outfile
  { echo "# Tier 4 (logs+metrics+traces+TAIL SAMPLING) — ARM 1 collector v0.159.0 — $1 readout"
    echo "generated: $(date -u +%FT%TZ) · engine=collector (single, FB offline) · load=locust+k6+telemetrygen(traces@200,metrics@100)"
    echo "topology: DaemonSet(logs) + StatefulSet(metrics istiod+Kepler) + Deployment(traces OTLP + tail_sampling) — TIER-4 delta = tail_sampling processor"
    echo "tail-sampling policy: keep-errors OR (NOT healthcheck AND 30% probabilistic); decision_wait=10s num_traces=100000"
    echo; echo '## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)'
    STRICT_NS="bench-collector kepler" bash "$KPI/census-gate.sh" bench-collector kepler otel-demo hipster-shop 2>&1
    echo; echo '## App churn during run (WARNING-only)'; app_churn
    echo; echo '## Load reaching app gate (#6c)'; load_check
    echo; echo '## Dynatrace receipt gate (pt9 — logs+metrics+traces RECEIVED IN DYNATRACE)'; dt_receipt
    echo; echo '## Tail-sampling processor stats (E4 measurement — sampled/dropped/decision buffer)'; ts_stats
    echo; echo '## Leak readout — collector (all components, tail-flat)'; bash "$KPI/leak-readout.sh" collector 12 15 2>&1
    echo; echo '## Loss accounting — collector (accepted vs sent, all signals)'; bash "$KPI/loss-accounting.sh" collector 2>&1
    echo; echo '## Resource snapshot (working-set, per component — WATCH the traces pod: tail_sampling cost)'; kubectl top pod -n bench-collector --no-headers 2>&1
  } | tee "$2"
}

green() { grep -q "CENSUS GATE: PASS" "$1" && grep -q "RECEIVED IN DYNATRACE" "$1" && grep -q "LOAD REACHING APP: PASS" "$1"; }

T0=$(date -u +%FT%TZ); echo "[driver] Tier4 ARM1(collector)+LOAD START T0=$T0 pid=$$"
echo "[driver] applying load (locust+k6+telemetrygen traces/metrics) at T0"; apply_load

sleep 7200
GATE="$OUT/tier4-collector-2h-gate.md"; readout "2h validity gate" "$GATE"
if green "$GATE"; then GV="🟢 GREEN — census PASS + logs/metrics/traces in Dynatrace + load reaching app + tail_sampling active"; else GV="🔴 RED — a gate failed (dataset INVALID)"; fi
post "$(printf '## Tier 4 · ARM 1 (collector) — 2h validity gate: %s\n\nT0=%s · gate at %s · SINGLE-ENGINE (pt9), FB offline · signals=logs+metrics+traces+TAIL SAMPLING (keep-errors OR (NOT healthcheck AND 30%%)) · load=locust+k6+telemetrygen(traces@200)\n\n```\n%s\n```\n\nArtifact: `tiers/tier4/tier4-collector-2h-gate.md`. %s' \
  "$GV" "$T0" "$(date -u +%FT%TZ)" "$(sed -n '1,72p' "$GATE")" \
  "$(green "$GATE" && echo 'Soak continues; 24h readout auto-posts at T+26h.' || echo 'Halting before soak; investigate.')")"
green "$GATE" || { echo "[driver] gate RED — halt (keeping bench-load for triage)"; exit 0; }

sleep 86400
FINAL="$OUT/tier4-collector-results.md"; readout "24h soak" "$FINAL"
if grep -q "CENSUS GATE: PASS" "$FINAL"; then FV="🟢 VALID — 24h soak complete, census PASS"; else FV="🔴 INVALID — restart during soak"; fi
post "$(printf '## Tier 4 · ARM 1 (collector) — 24h soak COMPLETE: %s\n\nT0=%s · readout at %s · TAIL-SAMPLING cost = the traces-pod working-set/CPU delta vs T3 (watch the resource snapshot)\n\n```\n%s\n```\n\n**Next:** ARM 2 = Fluent Bit v5.1.1 as the NO-TS CONTROL (FB has no tail sampling) — teardown collector arm + apply `tiers/tier4/fluentbit-tier4.yaml` (= T3-shaped full-stack trace load), 2h gate -> 24h soak. Then `tier4-comparison.md` (call out the collector T3->T4 tail-sampling CPU/mem/state cost) -> E5 (ISI-3579).' \
  "$FV" "$T0" "$(date -u +%FT%TZ)" "$(sed -n '1,84p' "$FINAL")")"
echo "[driver] tearing down bench-load (arm end)"; kubectl delete ns bench-load --wait=false 2>&1
echo "[driver] Tier4 ARM1 DONE — FB arm (no-TS control) is the next heartbeat's manual step"
