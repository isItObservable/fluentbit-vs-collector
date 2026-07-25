#!/usr/bin/env bash
# ISI-1879 — corrected smoke monitor. The first driver aborted on a FALSE
# engine-alive positive (stale 0.50.0 metric name). This watches the
# already-running engine-new (0.51.0) for a continuous >=45min window under the
# live otel-demo fan-out load, using the 0.51.0-aware grader, and banks a
# corrected verdict. engine-old already collapsed to 1 set (control death on
# `boo` metrics.rs:266) — that evidence is banked; this run is about the new one.
set -uo pipefail
BASE=/tmp/isi1879-smoke
GRADER=/tmp/fvc1821/bench1-v2/results/r1p3-arrow-rebuild/engine-alive-051.sh
export KUBECONFIG=$HOME/.config/capmox/observable-agentsandbox.kubeconfig
WINDOW=${WINDOW:-2760}
CSV="$BASE/liveness2.csv"
LOG="$BASE/monitor2.log"
exec >>"$LOG" 2>&1
echo "=== monitor2 start $(date -u +%FT%TZ) pid $$ ==="

POD0=$(kubectl -n dfsmoke get pod -l app=engine-new -o jsonpath='{.items[0].metadata.name}')
START_ISO=$(kubectl -n dfsmoke get pod "$POD0" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')
START_EPOCH=$(date -d "$START_ISO" +%s)
DEADLINE=$(( START_EPOCH + WINDOW ))
echo "engine-new pod=$POD0 start=$START_ISO window=${WINDOW}s deadline=$(date -u -d @$DEADLINE +%FT%TZ)"
echo "ts,age_s,new_alive,new_sets,new_overflow,new_boo,new_panic,restarts,pod" > "$CSV"

grade_sets(){ # -> "alive sets"
  local snap; snap=$(mktemp)
  kubectl -n dfsmoke port-forward "deploy/engine-new" 18091:8080 >/dev/null 2>&1 & local pf=$!; sleep 3
  if curl -sf "http://127.0.0.1:18091/api/v1/metrics?format=json&reset=false&keep_all_zeroes=true" -o "$snap" 2>/dev/null; then
    local sets; sets=$(python3 -c "import json;print(len(json.load(open('$snap')).get('metric_sets',[])))" 2>/dev/null || echo -1)
    if bash "$GRADER" "$snap" >/dev/null 2>&1; then echo "1 $sets"; else echo "0 $sets"; fi
  else echo "0 -1"; fi
  kill $pf 2>/dev/null; rm -f "$snap"
}
lc(){ kubectl -n dfsmoke logs deploy/engine-new --tail=200000 2>/dev/null | grep -Ec "$1" || true; }

FAIL=""; LASTSETS=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  ts=$(date -u +%FT%TZ); now=$(date +%s); age=$(( now - START_EPOCH ))
  set -- $(grade_sets); na=$1; ns=$2; LASTSETS=$ns
  ov=$(lc 'DictionaryKeyOverflowError'); bo=$(lc '\bboo\b'); pa=$(lc 'panicked')
  pod=$(kubectl -n dfsmoke get pod -l app=engine-new -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  rs=$(kubectl -n dfsmoke get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  echo "$ts,$age,$na,$ns,$ov,$bo,$pa,$rs,$pod" | tee -a "$CSV"
  [ "$na" = "0" ] && FAIL="engine_dead(sets=$ns)"
  [ "${ov:-0}" != "0" ] && FAIL="dict_overflow"
  [ "${bo:-0}" != "0" ] && FAIL="boo_panic"
  [ "${pa:-0}" != "0" ] && FAIL="panic"
  [ "$pod" != "$POD0" ] && FAIL="pod_replaced($POD0->$pod)"
  [ "${rs:-0}" != "0" ] && FAIL="pod_restarted(count=$rs)"
  if [ -n "$FAIL" ]; then
    echo "!!! FAIL: $FAIL at age ${age}s"
    kubectl -n dfsmoke logs deploy/engine-new --tail=300 > "$BASE/engine-new-FAILURE2.log" 2>&1
    echo "FAIL_NEW:$FAIL:age=${age}s" > "$BASE/verdict2"; exit 1
  fi
  sleep 90
done
FINAL_AGE=$(( $(date +%s) - START_EPOCH ))
kubectl -n dfsmoke logs deploy/engine-new --tail=400 > "$BASE/engine-new-final2.log" 2>&1
echo "PASS_NEW_SURVIVES_OLD_FAILED:new_age=${FINAL_AGE}s:new_sets=${LASTSETS}:old=collapsed_to_1set_boo_metrics.rs266" > "$BASE/verdict2"
echo "=== monitor2 PASS age=${FINAL_AGE}s $(date -u +%FT%TZ) ==="
