#!/usr/bin/env bash
# =============================================================================
# ISI-1881 — R1P3-arrow detached driver (df_engine 0.51.0, the arrow arm).
# Runs PHASE-RUNBOOK.md end to end, DETACHED (setsid nohup), banking every step
# to disk so it survives session teardown. Separates the WORK from the
# notification (ISI-1843/ISI-1879 pattern).
#
# SAFETY: the 8-check gate is BLOCKING. If validate-phase.sh exits non-zero the
# driver HALTS before any load — no measurement window is opened, nothing is
# contaminated, and the engine just idles for diagnosis. It NEVER tears down;
# the window + census are recoverable from Kubernetes (capture-window.sh) so the
# register can be filled after the fact.
# =============================================================================
set -uo pipefail
export KUBECONFIG=/tmp/otelarrow.kubeconfig
export ENGINE=otel-arrow-native
RUN_ID=R1-P3-arrow
CLONE=/tmp/fvc1821/bench1-v2
OUT="$CLONE/results/r1p3-arrow-run"
mkdir -p "$OUT"
STATE="$OUT/STATE"; LOG="$OUT/driver.log"
cd "$CLONE" || { echo "no clone"; exit 1; }
say(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
setstate(){ echo "$1" > "$STATE"; say "STATE=$1"; }

ENGPOD(){ kubectl -n default get pod -l app=bench-otel-arrow-native -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

setstate DEPLOY_APPS
say "=== R1P3-arrow driver start ; engine image $(kubectl -n default get pod -l app=bench-otel-arrow-native -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)"

# guard: engine must be alive before we touch the apps
p="$(ENGPOD)"
if [ -z "$p" ] || ! ./results/r1p3-arrow-rebuild/engine-alive-051.sh --live -n default -p "$p" >>"$LOG" 2>&1; then
  setstate ENGINE_NOT_ALIVE; say "FATAL: engine not alive pre-deploy"; exit 1
fi

# --- Step 2: both apps pointed at the arrow engine ---
say "helm upgrade otel-demo -> arrow (--wait, up to 15m)"
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo --version 0.40.10 \
  -n otel-demo --create-namespace -f apps/otel-demo-values-${ENGINE}.yaml --wait --timeout 15m >>"$LOG" 2>&1 \
  || say "WARN: otel-demo helm upgrade returned non-zero (continuing; gate will judge)"
say "apply hipster-shop -> arrow"
kubectl apply -f apps/hipster-shop-${ENGINE}.yaml >>"$LOG" 2>&1 || say "WARN: hipster-shop apply non-zero"

# --- Step 3: appProtocol (MANDATORY, helm strips it every upgrade) ---
./apps/appprotocol.sh >>"$LOG" 2>&1 || say "WARN: appprotocol.sh non-zero"

# --- Step 4: namespace labels (sidecars in, DT injection out) ---
kubectl label ns otel-demo hipster-shop istio-injection=enabled --overwrite >>"$LOG" 2>&1
kubectl label ns otel-demo hipster-shop oneagent=false --overwrite >>"$LOG" 2>&1

# --- Step 5: Istio ---
setstate ISTIO
helm upgrade istiod istio/istiod -n istio-system -f istio/values-${ENGINE}.yaml --wait >>"$LOG" 2>&1 \
  || say "WARN: istiod helm upgrade non-zero"
kubectl rollout restart deploy/istiod -n istio-system >>"$LOG" 2>&1
kubectl -n istio-system rollout status deploy/istiod --timeout=240s >>"$LOG" 2>&1 || say "WARN: istiod rollout slow"
kubectl apply -f istio/telemetry-${ENGINE}.yaml >>"$LOG" 2>&1

# --- Step 6: restart apps to pick up mesh + port protocol (CPU-tight surge) ---
setstate RESTART_APPS
kubectl -n otel-demo rollout restart deploy >>"$LOG" 2>&1
kubectl -n hipster-shop rollout restart deploy >>"$LOG" 2>&1
sleep 150   # tolerate the maxSurge=1/maxUnavailable=0 deadlock; it self-resolves
kubectl -n otel-demo rollout status deploy --timeout=600s >>"$LOG" 2>&1 || say "WARN: otel-demo rollout slow"
kubectl -n hipster-shop rollout status deploy --timeout=600s >>"$LOG" 2>&1 || say "WARN: hipster-shop rollout slow"

# --- Step 7: smoke (apps' own loadgenerators at low volume), then gate ---
setstate SMOKE
say "smoke: 720s for telemetry to flow before the gate reads its 15m window"
sleep 720

# re-confirm engine survived the app churn before spending gate time
p="$(ENGPOD)"
./results/r1p3-arrow-rebuild/engine-alive-051.sh --live -n default -p "$p" > "$OUT/engine-alive-pre-gate.out" 2>&1 || say "WARN: pre-gate liveness non-zero (gate CHECK 5d will confirm)"

setstate GATE
say "running validate-phase.sh $ENGINE --window 15m (all 8 checks 0-7 must pass)"
if ./validate-phase.sh ${ENGINE} --window 15m > "$OUT/gate.out" 2>&1; then
  cp "$OUT/gate.out" "$OUT/gate-GREEN.out"
  say "GATE GREEN"
else
  setstate GATE_RED
  say "GATE RED — NOT starting load. Engine + apps left idling for diagnosis (nothing measured)."
  tail -12 "$OUT/gate.out" | tee -a "$LOG"
  exit 1
fi

# --- Gate green: open the measurement window ---
setstate OPEN_WINDOW
# run-lock record (nothing reads it, but teardown.sh P3 asserts it)
kubectl create configmap isi1779-run-lock -n default \
  --from-literal=claimed="$(date -u +%FT%TZ)" --from-literal=owner=ISI-1881 --from-literal=run="$RUN_ID" \
  --dry-run=client -o yaml | kubectl apply -f - >>"$LOG" 2>&1

# START census + engine identity, BEFORE load (D12)
./pod-census.sh "$RUN_ID" start > "$OUT/census-START.txt" 2>>"$LOG" || say "WARN: start census non-zero"
kubectl get pods -A --no-headers -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' \
  | awk '$2 ~ /^bench-/' > "$OUT/engine-identity-START.txt"
# attr-landing verdict for the register (CHECK 7 already ran it; snapshot separately too)
grep -A3 -iE 'attribute landing|CHECK 7|spans=.*logs=.*metrics=' "$OUT/gate.out" > "$OUT/attr-landing-verdict.txt" 2>/dev/null || true

START_TS="$(date -u +%FT%TZ)"; echo "$START_TS" > "$OUT/START_TS"
say "START=$START_TS ; applying ramp jobs (staggered 50->200 VU/app, 7200s)"

# --- Step 9: timed run ---
kubectl apply -f loadtest/ramp-jobs-${ENGINE}.yaml >>"$LOG" 2>&1
setstate LOAD_RUNNING
sleep 20
kubectl get pods -A -l ramp=isi1779 -o wide >> "$LOG" 2>&1

# --- Wait for the load to finish (poll k8s, no capture loop on the data path) ---
deadline=$(( $(date +%s) + 8400 ))   # 7200s + ~20m slack
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 120
  if ./capture-window.sh "$RUN_ID" > "$OUT/window-poll.out" 2>&1; then
    break   # exit 0 = all ramp pods finished
  fi
done

# --- Step 10: END + census, from Kubernetes, BEFORE any teardown ---
setstate CAPTURE_END
./capture-window.sh "$RUN_ID" > "$OUT/window-END.out" 2>&1 || true
END_TS="$(grep -oE 'End:[[:space:]]+[0-9T:-]+Z' "$OUT/window-END.out" | awk '{print $2}')"
echo "${END_TS:-UNRESOLVED}" > "$OUT/END_TS"
./pod-census.sh "$RUN_ID" end > "$OUT/census-END.txt" 2>>"$LOG" || say "WARN: end census non-zero"
say "END=${END_TS:-UNRESOLVED} ; census captured. NOT tearing down."
setstate RUN_COMPLETE
say "=== R1P3-arrow load COMPLETE. Pending: fill RUN-REGISTER, readout vs collector/fluentbit, D12 census verdict, teardown after verification."
