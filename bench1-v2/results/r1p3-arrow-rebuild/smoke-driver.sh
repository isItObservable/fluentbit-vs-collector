#!/usr/bin/env bash
# ISI-1879 arrow-rebuild smoke DRIVER — fully detached (setsid nohup), survives
# session teardowns. Waits for the df_engine 0.51.0 build, deploys the
# concurrent positive-control smoke (engine-old 0.50.0 vs engine-new 0.51.0 on
# byte-identical fan-out load), runs the >=45min measurement, banks a verdict.
#
# All state to disk: any future heartbeat reads $BASE/verdict + $BASE/*.
set -uo pipefail

BASE=/tmp/isi1879-smoke
RIG=/tmp/fvc1821/bench1-v2/results/r1p3-arrow-rebuild
ALIVE=/tmp/fvc1821/bench1-v2/results/r1p3-retry/engine-alive.sh
export KUBECONFIG=$HOME/.config/capmox/observable-agentsandbox.kubeconfig
TOKEN=$(sed -n 's#https://\([^@]*\)@github.com#\1#p' "$HOME/.git-credentials" | head -1 | sed 's#.*:##')
RUN=30150098818
SMOKE_SECS=${SMOKE_SECS:-2760}   # 46 min measurement window
NEW_IMG=ghcr.io/isitobservable/df_engine:0.51.0

mkdir -p "$BASE"
LOG="$BASE/driver.log"
CSV="$BASE/liveness.csv"
exec >>"$LOG" 2>&1
echo "=================================================================="
echo "=== driver start $(date -u +%FT%TZ) pid $$ ==="

verdict(){ echo "$1" > "$BASE/verdict"; echo "VERDICT=$1 at $(date -u +%FT%TZ)"; }

# positive control on the grep (isi1843 lesson): prove the pattern CAN match
echo "grep self-test (must be >=1): $(printf 'thread panicked DictionaryKeyOverflowError\nboo [21,7]\n' | grep -Ec 'DictionaryKeyOverflowError|\bboo\b|panicked')"

# ---- 1. wait for build ----------------------------------------------------
echo "--- stage 1: wait for build $RUN ---"
while true; do
  j=$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/isItObservable/Otel-arrow/actions/runs/$RUN" 2>/dev/null || true)
  st=$(echo "$j" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status'),d.get('conclusion'))" 2>/dev/null || echo "poll-error x")
  echo "$(date -u +%TZ) build: $st"
  case "$st" in
    "completed success") break;;
    "completed "*) verdict "FAIL_BUILD:$st"; exit 1;;
  esac
  sleep 45
done
echo "BUILD_OK" > "$BASE/stage.build.done"

# ---- 2. deploy smoke rig --------------------------------------------------
echo "--- stage 2: deploy smoke rig ---"
kubectl apply -f "$RIG/smoke-rebuild.yaml" || { verdict "FAIL_APPLY_RIG"; exit 1; }
# engine-new MUST boot; engine-old is the control and may crashloop (do not gate)
if ! kubectl -n dfsmoke rollout status deploy/engine-new --timeout=240s; then
  echo "engine-new did NOT reach Ready — capturing"; kubectl -n dfsmoke describe deploy/engine-new; kubectl -n dfsmoke get pods
  verdict "FAIL_ENGINE_NEW_BOOT"; exit 1
fi
kubectl -n dfsmoke rollout status deploy/fanout --timeout=180s || true
kubectl -n dfsmoke rollout status deploy/sink-new --timeout=120s || true
kubectl -n dfsmoke rollout status deploy/sink-old --timeout=120s || true
kubectl -n dfsmoke rollout status deploy/engine-old --timeout=120s || echo "engine-old not Ready (expected if it panics on boot)"
NEW_DIGEST=$(kubectl -n dfsmoke get pod -l app=engine-new -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)
echo "engine-new imageID: $NEW_DIGEST"
echo "$NEW_DIGEST" > "$BASE/new-image-digest.txt"
echo "DEPLOY_OK" > "$BASE/stage.deploy.done"

# ---- 3. deploy otel-demo load ---------------------------------------------
echo "--- stage 3: deploy otel-demo load ---"
helm repo update open-telemetry >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true
timeout 600 helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.10 -n otel-demo --create-namespace \
  -f "$RIG/otel-demo-values-smoke.yaml" || echo "helm returned non-zero (continuing; load may still start)"
echo "waiting 150s for demo services + loadgen to warm..."
sleep 150
kubectl -n otel-demo get pods | tail -30
echo "LOAD_OK" > "$BASE/stage.load.done"

# ---- 4. smoke measurement -------------------------------------------------
echo "--- stage 4: smoke measurement ${SMOKE_SECS}s ---"
echo "ts,new_alive,new_sets,old_alive,old_sets,new_overflow,new_boo,new_panic,old_overflow,old_boo,old_panic" > "$CSV"
grade(){ # $1=app label $2=localport -> echoes "alive sets" ; alive=1 ok
  local app=$1 port=$2 snap; snap=$(mktemp)
  kubectl -n dfsmoke port-forward "deploy/$app" "$port:8080" >/dev/null 2>&1 &
  local pf=$!; sleep 3
  if curl -sf "http://127.0.0.1:$port/api/v1/metrics?format=json&reset=false&keep_all_zeroes=true" -o "$snap" 2>/dev/null; then
    local sets; sets=$(python3 -c "import json;print(len(json.load(open('$snap')).get('metric_sets',[])))" 2>/dev/null || echo -1)
    if bash "$ALIVE" "$snap" >/dev/null 2>&1; then echo "1 $sets"; else echo "0 $sets"; fi
  else echo "0 -1"; fi
  kill $pf 2>/dev/null; rm -f "$snap"
}
logcount(){ kubectl -n dfsmoke logs "deploy/$1" --tail=100000 2>/dev/null | grep -Ec "$2" || echo 0; }

START=$(date +%s); NEW_DIED=0
while [ $(( $(date +%s) - START )) -lt "$SMOKE_SECS" ]; do
  ts=$(date -u +%FT%TZ)
  read -r na ns < <(grade engine-new 18091)
  read -r oa os < <(grade engine-old 18092)
  no=$(logcount engine-new 'DictionaryKeyOverflowError'); nb=$(logcount engine-new '\bboo\b'); np=$(logcount engine-new 'thread .*panicked|panicked at')
  oo=$(logcount engine-old 'DictionaryKeyOverflowError'); ob=$(logcount engine-old '\bboo\b'); op=$(logcount engine-old 'thread .*panicked|panicked at')
  echo "$ts,$na,$ns,$oa,$os,$no,$nb,$np,$oo,$ob,$op" | tee -a "$CSV"
  # abort early if the NEW engine dies — do not waste the window (task rule)
  if [ "$na" = "0" ] || [ "$no" != "0" ] || [ "$nb" != "0" ] || [ "$np" != "0" ]; then
    echo "!!! NEW ENGINE FAILURE DETECTED at $ts (alive=$na overflow=$no boo=$nb panic=$np)"
    kubectl -n dfsmoke logs deploy/engine-new --tail=200 > "$BASE/engine-new-FAILURE.log" 2>&1
    NEW_DIED=1; break
  fi
  sleep 120
done

# ---- 5. verdict -----------------------------------------------------------
ELAPSED=$(( $(date +%s) - START ))
echo "--- measurement ended, elapsed ${ELAPSED}s ---"
kubectl -n dfsmoke logs deploy/engine-new --tail=300 > "$BASE/engine-new-final.log" 2>&1
kubectl -n dfsmoke logs deploy/engine-old --tail=300 > "$BASE/engine-old-final.log" 2>&1
# control check: did the OLD engine actually fail (proving the rig carries the trigger)?
OLD_FAILED=$(awk -F, 'NR>1 && ($4==0 || $9!=0 || $10!=0 || $11!=0){print "1"; exit}' "$CSV")
echo "old_failed=${OLD_FAILED:-0} new_died=$NEW_DIED elapsed=$ELAPSED"
if [ "$NEW_DIED" = "1" ]; then
  verdict "FAIL_NEW_OVERFLOW:elapsed=${ELAPSED}s"
elif [ "$ELAPSED" -ge 2700 ]; then
  if [ "${OLD_FAILED:-0}" = "1" ]; then verdict "PASS_NEW_SURVIVES_OLD_FAILED:elapsed=${ELAPSED}s"
  else verdict "PASS_NEW_SURVIVES_CONTROL_INCONCLUSIVE:elapsed=${ELAPSED}s"; fi
else
  verdict "INCOMPLETE:elapsed=${ELAPSED}s"
fi
echo "=== driver end $(date -u +%FT%TZ) ==="
