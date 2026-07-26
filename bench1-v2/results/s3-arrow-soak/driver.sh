#!/usr/bin/env bash
# =============================================================================
# ISI-1881 — S3-otel-arrow 24h SOAK driver (df_engine 0.51.0, ATTEMPT 2).
#
# Run DETACHED from the bench1-v2 clone root:
#   setsid nohup ./results/s3-arrow-soak/driver.sh >/dev/null 2>&1 &
#   disown
#
# STATE machine (on disk at results/s3-arrow-soak/STATE):
#   DEPLOY_ENGINE  → delete stale engine pod, wait for fresh pod with 0 restarts
#   SMOKE          → 720s for telemetry to settle, re-confirm engine alive
#   GATE           → validate-phase.sh 8/8 (blocking; GATE_RED halts with no load)
#   SOAK_START     → apply soak jobs, record START, capture pod census
#   SOAK_RUNNING   → hourly: engine-alive-051.sh + set snapshot → rss-hourly.csv
#   CAPTURE_END    → record END = START + 86400s, capture END census, delete jobs
#   SOAK_COMPLETE
#
# SAFETY properties inherited from R1P3/R2P3 pattern:
#   - GATE is blocking: red gate halts driver before load opens (nothing measured)
#   - Driver NEVER tears down apps/engine (only soak JOBS are deleted at end)
#   - Pod census captured before job deletion (D12 discipline)
#   - KUBECONFIG is the PERSISTENT path (survives reboots, unlike /tmp/otelarrow.kubeconfig)
#   - DT token NEVER written to disk or shell args (rendered via render-df-engine-config.sh)
#
# SPOF mitigation vs attempt 1: node 9r662 is NotReady → scheduler places new
# pods on j82ph and lz9mb. With 2 workers and 3 critical pods, each worker holds
# at most 2; this is the best achievable with the current 2-healthy-node topology.
# =============================================================================
set -uo pipefail

export KUBECONFIG=~/.config/capmox/observable-otelarrow.kubeconfig
export ENGINE=otel-arrow-native
RUN_ID=S3-otel-arrow
CLONE=/tmp/fvc1821/bench1-v2
OUT="$CLONE/results/s3-arrow-soak"
mkdir -p "$OUT"
STATE="$OUT/STATE"; LOG="$OUT/driver.log"
cd "$CLONE" || { echo "no clone at $CLONE"; exit 1; }

say()     { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
setstate(){ echo "$1" > "$STATE"; say "STATE=$1"; }

ENGPOD(){ kubectl -n default get pod -l app=bench-otel-arrow-native -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

say "=== S3-otel-arrow soak driver START (attempt 2)"

# ─── DEPLOY_ENGINE ──────────────────────────────────────────────────────────
setstate DEPLOY_ENGINE
say "Deleting existing engine pod (attempt-1 had 2 restarts → memory baseline invalid)"
kubectl -n default delete pod -l app=bench-otel-arrow-native --wait=true --timeout=120s >>"$LOG" 2>&1 || true
say "Re-applying engine manifest (engine stays alive via Deployment controller)"
kubectl apply -f engines/otel-arrow-native.yaml >>"$LOG" 2>&1

say "Waiting for fresh engine pod (0 restarts; up to 5m)"
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  p="$(ENGPOD)"
  if [ -n "$p" ]; then
    restarts=$(kubectl -n default get pod "$p" \
      -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    ready=$(kubectl -n default get pod "$p" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
    if [[ "$restarts" == "0" && "$ready" == "True" ]]; then
      say "Engine pod $p ready (restarts=$restarts)"
      break
    fi
    say "Engine pod $p: ready=$ready restarts=$restarts (waiting)"
  else
    say "No engine pod yet (waiting)"
  fi
  sleep 15
done
p="$(ENGPOD)"
if [ -z "$p" ]; then setstate ENGINE_NOT_ALIVE; say "FATAL: engine pod never appeared"; exit 1; fi

# ─── SMOKE ──────────────────────────────────────────────────────────────────
setstate SMOKE
say "Smoke: 720s for telemetry to settle before gate reads its 15m window"
sleep 720

p="$(ENGPOD)"
say "Pre-gate engine liveness check: $p"
./results/r1p3-arrow-rebuild/engine-alive-051.sh --live -n default -p "$p" \
  > "$OUT/engine-alive-pre-gate.out" 2>&1 \
  || say "WARN: pre-gate liveness non-zero (gate CHECK 5d will re-evaluate)"

# ─── GATE ───────────────────────────────────────────────────────────────────
setstate GATE
say "Running validate-phase.sh $ENGINE --window 15m (8 checks, must be GREEN)"
if ./validate-phase.sh "$ENGINE" --window 15m > "$OUT/gate.out" 2>&1; then
  cp "$OUT/gate.out" "$OUT/gate-GREEN.out"
  say "GATE GREEN — opening soak window"
else
  setstate GATE_RED
  say "GATE RED — NOT starting soak. Engine + apps left idling for diagnosis."
  tail -12 "$OUT/gate.out" | tee -a "$LOG"
  exit 1
fi

# ─── SOAK_START ─────────────────────────────────────────────────────────────
setstate SOAK_START
# run-lock
kubectl create configmap isi1779-run-lock -n default \
  --from-literal=claimed="$(date -u +%FT%TZ)" --from-literal=owner=ISI-1881 --from-literal=run="$RUN_ID" \
  --dry-run=client -o yaml | kubectl apply -f - >>"$LOG" 2>&1

# START census (D12) and engine identity — BEFORE load
./pod-census.sh "$RUN_ID" start > "$OUT/census-START.txt" 2>>"$LOG" || say "WARN: start census non-zero"
kubectl get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' \
  | awk '$2 ~ /^bench-/' > "$OUT/engine-identity-START.txt"

# attr-landing snapshot (CHECK 7 already validated; snapshot for the register)
grep -A3 -iE 'attribute landing|CHECK 7|spans=.*logs=.*metrics=' "$OUT/gate.out" > "$OUT/attr-landing-verdict.txt" 2>/dev/null || true

START_TS="$(date -u +%FT%TZ)"; echo "$START_TS" > "$OUT/START_TS"
SOAK_SECS=86400
say "START=$START_TS ; soak duration ${SOAK_SECS}s (24h)"

say "Applying soak jobs (50 VU/app, constant, 24h)"
kubectl apply -f loadtest/soak-jobs-${ENGINE}.yaml >>"$LOG" 2>&1
setstate SOAK_RUNNING
sleep 30
say "Soak pods launched:"
kubectl get pods -A -l soak=isi1779 -o wide 2>&1 | tee -a "$LOG"

# ─── SOAK_RUNNING — hourly pulse ────────────────────────────────────────────
# Header row for RSS snapshot file
echo "timestamp,engine_pod,restarts,sets_accepted,sets_exported,boo_count,alive" \
  > "$OUT/rss-hourly.csv"

SOAK_START_EPOCH=$(date +%s)
SOAK_END_EPOCH=$(( SOAK_START_EPOCH + SOAK_SECS ))
HOUR_INTERVAL=3600
NEXT_PULSE=$(( SOAK_START_EPOCH + HOUR_INTERVAL ))

while [ "$(date +%s)" -lt "$SOAK_END_EPOCH" ]; do
  now=$(date +%s)
  remaining=$(( SOAK_END_EPOCH - now ))
  say "Soak running — ${remaining}s remaining until 24h mark"

  # wait until next hourly pulse (or soak end, whichever is sooner)
  sleep_to=$(( NEXT_PULSE < SOAK_END_EPOCH ? NEXT_PULSE : SOAK_END_EPOCH ))
  sleep_secs=$(( sleep_to - now ))
  if [ "$sleep_secs" -gt 0 ]; then sleep "$sleep_secs"; fi
  NEXT_PULSE=$(( NEXT_PULSE + HOUR_INTERVAL ))

  # hourly snapshot
  ts="$(date -u +%FT%TZ)"
  p="$(ENGPOD)"
  if [ -z "$p" ]; then
    say "WARN: engine pod GONE at $ts — soak may be contaminated"
    echo "${ts},GONE,?,-,-,-,DEAD" >> "$OUT/rss-hourly.csv"
    continue
  fi
  restarts=$(kubectl -n default get pod "$p" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")

  pulse_out="$OUT/pulse-$(date -u +%H%M%S).out"
  alive="ALIVE"
  if ! ./results/r1p3-arrow-rebuild/engine-alive-051.sh --live -n default -p "$p" \
      > "$pulse_out" 2>&1; then
    alive="DEAD"
    say "WARN: engine-alive-051.sh DEAD at $ts (restarts=$restarts)"
  fi
  # extract accepted/exported/boo from the alive snapshot
  acc=$(grep -oE 'accepted:[[:space:]]*[0-9]+' "$pulse_out" | head -1 | grep -oE '[0-9]+' || echo "-")
  exp=$(grep -oE 'exported:[[:space:]]*[0-9]+' "$pulse_out" | head -1 | grep -oE '[0-9]+' || echo "-")
  boo=$(grep -oE 'boo[[:space:]]*count:[[:space:]]*[0-9]+' "$pulse_out" | head -1 | grep -oE '[0-9]+' || echo "0")
  echo "${ts},${p},${restarts},${acc},${exp},${boo},${alive}" >> "$OUT/rss-hourly.csv"
  say "Pulse $ts — pod=$p restarts=$restarts acc=$acc exp=$exp boo=$boo alive=$alive"

  # check soak pods still running
  soak_running=$(kubectl get pods -A -l soak=isi1779 --no-headers 2>/dev/null | grep -c Running || echo 0)
  say "Soak pods Running: $soak_running/2"
  if [ "$soak_running" -eq 0 ]; then
    say "WARN: 0 soak pods Running — possible node failure or job expiry; continuing to CAPTURE_END"
    break
  fi
done

# ─── CAPTURE_END ────────────────────────────────────────────────────────────
setstate CAPTURE_END
END_TS="$(date -u +%FT%TZ)"; echo "$END_TS" > "$OUT/END_TS"
say "Soak 24h elapsed. END=$END_TS"

# END pod census — BEFORE job deletion (D12)
./pod-census.sh "$RUN_ID" end > "$OUT/census-END.txt" 2>>"$LOG" || say "WARN: end census non-zero"
kubectl get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' \
  | awk '$2 ~ /^bench-/' > "$OUT/engine-identity-END.txt"

# Final engine liveness check
p="$(ENGPOD)"
./results/r1p3-arrow-rebuild/engine-alive-051.sh --live -n default -p "$p" \
  > "$OUT/engine-alive-post-soak.out" 2>&1 && say "Post-soak engine: ALIVE" || say "Post-soak engine: DEAD (record)"

# Soak pod final status (for the register)
kubectl get pods -A -l soak=isi1779 -o wide 2>&1 > "$OUT/soak-pods-final.txt"
kubectl get jobs -A -l soak=isi1779 -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for j in d.get("items", []):
    ns = j["metadata"]["namespace"]; name = j["metadata"]["name"]
    st = j.get("status", {})
    print(f"{ns}/{name}: active={st.get(\"active\",0)} succeeded={st.get(\"succeeded\",0)} failed={st.get(\"failed\",0)}")
    for cond in st.get("conditions", []):
        print(f"  condition: {cond.get(\"type\")} reason={cond.get(\"reason\")} lastTransitionTime={cond.get(\"lastTransitionTime\")}")
' > "$OUT/soak-jobs-final.txt" 2>&1 || true

# Delete soak jobs (load is over — safe to remove)
say "Deleting soak jobs (24h soak complete)"
kubectl delete -f loadtest/soak-jobs-${ENGINE}.yaml >>"$LOG" 2>&1 || say "WARN: job delete non-zero (may already be gone)"
kubectl delete configmap isi1779-run-lock -n default >>"$LOG" 2>&1 || true

setstate SOAK_COMPLETE
say "=== S3-otel-arrow SOAK COMPLETE. START=$START_TS END=$END_TS"
say "Next: fill RUN-REGISTER S3 row + census, run readout.sh for 3-engine comparison."
