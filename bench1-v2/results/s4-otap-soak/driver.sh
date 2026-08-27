#!/usr/bin/env bash
# =============================================================================
# ISI-3302 — S4-final OTAP hop arm 24h SOAK driver (Config A, attempt 1).
# Topology: apps →OTLP→ edge collector (contrib 0.154.0, OTAP-out)
#                 →OTAP→ df_engine 0.51.0 relay →OTLP/HTTP→ Dynatrace.
#
# Run DETACHED from the bench1-v2 clone root (cluster must be FREE — serial
# after S3 per plan §1 exclusive-use):
#   setsid nohup ./results/s4-otap-soak/driver.sh >/dev/null 2>&1 &
#   disown
#
# STATE machine (on disk at $OUT/STATE):
#   TEARDOWN_OTHERS → delete S3's native-arrow engine + any stale engine arm
#   DEPLOY_ENGINES  → render relay ConfigMap (DT token never on disk), apply
#                     relay + edge collector, delete pods, wait BOTH fresh
#                     (0 restarts, Ready) — D12 census needs new timestamps
#   REPOINT_APPS    → full §1 cycle: helm otel-demo + hipster apply (Config A
#                     values), appprotocol.sh, ns labels, istiod values +
#                     restart + Telemetry CR, app rollout restarts, converge
#   SMOKE           → 720s settle + OneAgent-absent proof
#   GATE            → validate-phase.sh otap-config-a (8 checks, blocking;
#                     3 attempts with 300s DT-ingestion settle between)
#   SOAK_START      → run-lock + census + START_TS + soak jobs (50 VU/app 24h)
#   SOAK_RUNNING    → hourly pulse: both pods' restarts, relay pipeline-alive,
#                     edge accepted/otap-sent/send_failed → pulse-hourly.csv
#   CAPTURE_END     → END_TS + census + census MATCH + job status, delete jobs
#   SOAK_COMPLETE
#
# SAFETY properties (inherited from S3 driver + ISI-1949 run-driver.sh):
#   - GATE is blocking: red gate halts BEFORE load opens (nothing measured)
#   - Driver NEVER tears down apps/engines (only soak JOBS deleted at end)
#   - Census captured BEFORE job deletion (D12 discipline)
#   - KUBECONFIG is the PERSISTENT path (survives reboots)
#   - DT token NEVER written to disk or shell args (render script uses awk ENVIRON)
#   - Completion comment posted to ISI-3302 via localhost API (wake for readout)
# =============================================================================
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.config/capmox/observable-otelarrow.kubeconfig}"
# Helm must use the PERSISTENT repository config — agent sessions export a
# transient HELM_REPOSITORY_CONFIG (e.g. /tmp/paperclip-opencode-config-*/)
# that has no repos, which killed attempt 1 at REPOINT_APPS.
export HELM_REPOSITORY_CONFIG="$HOME/.config/helm/repositories.yaml"
export EXPECTED_REPLICAS=2
ENGINE=otap-config-a
RUN_ID=S4-OTAP-CONFIG-A
CLONE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT=/mnt/nas/projects/isitobservable/_artifacts/isi1779/soak/S4-otap
ISSUE=4fd522ef-e20b-495b-bd30-b07a104c71f0
API=http://127.0.0.1:3100
mkdir -p "$OUT"
STATE="$OUT/STATE"; LOG="$OUT/driver.log"
cd "$CLONE" || { echo "no clone at $CLONE"; exit 1; }

say()     { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
setstate(){ echo "$1" > "$STATE"; say "STATE=$1"; }
post() { # $1 = markdown body
  python3 -c 'import json,sys; print(json.dumps({"body":sys.argv[1]}))' "$1" \
    | curl -s -X POST "$API/api/issues/$ISSUE/comments" \
        -H "Content-Type: application/json" -d @- >>"$LOG" 2>&1 || true
}
EDGEPOD(){ kubectl -n default get pod -l app.kubernetes.io/instance=default.bench-otap-config-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
RELAYPOD(){ kubectl -n default get pod -l app=bench-df-engine-otap -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

say "=== S4-OTAP soak driver START (Config A, attempt 1)"

# ─── TEARDOWN_OTHERS — exclusive cluster use (plan §1) ──────────────────────
setstate TEARDOWN_OTHERS
say "Deleting S3 native-arrow engine + any stale engine arms"
kubectl -n default delete deploy bench-otel-arrow-native --ignore-not-found >>"$LOG" 2>&1
kubectl -n default delete svc bench-otel-arrow-native --ignore-not-found >>"$LOG" 2>&1
kubectl -n default delete cm bench-otel-arrow-native-config --ignore-not-found >>"$LOG" 2>&1
kubectl -n default delete deploy bench-fluentbit --ignore-not-found >>"$LOG" 2>&1
kubectl -n default delete svc bench-fluentbit --ignore-not-found >>"$LOG" 2>&1
kubectl -n default delete opentelemetrycollector bench-otel-collector --ignore-not-found >>"$LOG" 2>&1
sleep 10
say "Stale engine cleanup done. bench-* remaining:"
kubectl -n default get pods -o name 2>/dev/null | grep -E 'bench-' | tee -a "$LOG" || say "(none besides Config A, if any)"

# ─── DEPLOY_ENGINES ─────────────────────────────────────────────────────────
setstate DEPLOY_ENGINES
if ! kubectl get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1; then
  setstate NO_OTEL_OPERATOR; say "FATAL: otel-operator CRD missing — edge collector CR cannot deploy"; exit 1
fi
say "Rendering df_engine relay ConfigMap (token from in-cluster secret, off-disk)"
./engines/render-df-engine-otap-relay.sh default >>"$LOG" 2>&1 || { setstate RENDER_FAIL; say "FATAL: relay config render failed"; exit 1; }
say "Applying relay deployment, then edge collector CR"
kubectl apply -f engines/df-engine-otap-relay.yaml >>"$LOG" 2>&1
kubectl apply -f engines/otap-config-a-edge-collector.yaml >>"$LOG" 2>&1

say "Waiting for BOTH engine pods fresh (0 restarts, Ready; up to 10m)"
deadline=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  e="$(EDGEPOD)"; r="$(RELAYPOD)"
  ok=1
  for p in "$e" "$r"; do
    [ -n "$p" ] || { ok=0; continue; }
    rst=$(kubectl -n default get pod "$p" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    rdy=$(kubectl -n default get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
    [[ "$rst" == "0" && "$rdy" == "True" ]] || ok=0
  done
  [ "$ok" -eq 1 ] && { say "Both engine pods ready: edge=$e relay=$r"; break; }
  say "pods: edge=${e:-none} relay=${r:-none} (waiting)"
  sleep 15
done
e="$(EDGEPOD)"; r="$(RELAYPOD)"
if [ -z "$e" ] || [ -z "$r" ]; then
  setstate ENGINE_NOT_ALIVE; say "FATAL: engine pods never appeared (edge=${e:-none} relay=${r:-none})"; exit 1
fi

# ─── REPOINT_APPS — full §1 cycle for ENGINE=otap-config-a ──────────────────
setstate REPOINT_APPS
say "helm upgrade otel-demo (Config A values, version 0.40.10)"
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.10 -n otel-demo --create-namespace \
  -f apps/otel-demo-values-otap-config-a.yaml --wait >>"$LOG" 2>&1 \
  || { setstate APP_HELM_FAIL; say "FATAL: otel-demo helm upgrade failed"; exit 1; }
say "kubectl apply hipster-shop (Config A manifest)"
kubectl apply -f apps/hipster-shop-otap-config-a.yaml >>"$LOG" 2>&1 \
  || { setstate APP_APPLY_FAIL; say "FATAL: hipster-shop apply failed"; exit 1; }
say "appprotocol.sh (MANDATORY after every helm upgrade)"
./apps/appprotocol.sh >>"$LOG" 2>&1 || say "WARN: appprotocol.sh non-zero"
say "namespace labels (sidecars in, OneAgent out)"
kubectl label ns otel-demo hipster-shop istio-injection=enabled --overwrite >>"$LOG" 2>&1
kubectl label ns otel-demo hipster-shop oneagent=false --overwrite >>"$LOG" 2>&1
say "istiod values (Config A providers) + restart + Telemetry CR"
helm upgrade istiod istio/istiod -n istio-system --version 1.29.2 \
  -f istio/values-otap-config-a.yaml --wait >>"$LOG" 2>&1 \
  || { setstate ISTIOD_FAIL; say "FATAL: istiod helm upgrade failed"; exit 1; }
kubectl rollout restart deploy/istiod -n istio-system >>"$LOG" 2>&1
kubectl rollout status deploy/istiod -n istio-system --timeout=300s >>"$LOG" 2>&1 \
  || say "WARN: istiod rollout status non-zero"
kubectl apply -f istio/telemetry-otap-config-a.yaml >>"$LOG" 2>&1
say "rollout restart app deployments (sequential — no CPU for a mass surge)"
kubectl -n otel-demo rollout restart deploy >>"$LOG" 2>&1
kubectl -n otel-demo rollout status deploy --timeout=600s >>"$LOG" 2>&1 || say "WARN: otel-demo rollout slow"
kubectl -n hipster-shop rollout restart deploy >>"$LOG" 2>&1
kubectl -n hipster-shop rollout status deploy --timeout=600s >>"$LOG" 2>&1 || say "WARN: hipster-shop rollout slow"

say "Converging: both app namespaces fully Ready (up to 15m)"
CDEAD=$(( $(date +%s) + 900 ))
while [ "$(date +%s)" -lt "$CDEAD" ]; do
  notready=$(kubectl get deploy -A -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
n=[i["metadata"]["namespace"]+"/"+i["metadata"]["name"] for i in d.get("items",[])
  if i["metadata"]["namespace"] in ("otel-demo","hipster-shop")
  and (i["spec"].get("replicas",1) or 0)!=(i.get("status",{}).get("readyReplicas",0) or 0)]
print(",".join(n))' 2>/dev/null)
  [ -z "$notready" ] && { say "both namespaces Ready"; break; }
  say "notready=[${notready:-none}]"
  sleep 30
done
[ -n "${notready:-}" ] && say "WARN: apps not fully converged at deadline — gate CHECK 1 will decide"

# ─── SMOKE ──────────────────────────────────────────────────────────────────
setstate SMOKE
OA=$(kubectl get pods -n otel-demo -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except: print(0); raise SystemExit
print(sum(1 for p in d.get("items",[]) for ic in (p.get("spec",{}).get("initContainers",[]) or []) if "dynatrace" in ic.get("name","")))' 2>/dev/null)
say "OneAgent init-containers on otel-demo pods: ${OA:-?} (expect 0)"
say "Smoke: 720s for telemetry to settle before gate reads its window"
sleep 720

# ─── GATE ───────────────────────────────────────────────────────────────────
setstate GATE
# ISI-3302 attempt-1 diagnosis: first gate run went RED on 2026-08-27 with ZERO
# spans/logs/istio spans in-window while a post-hoc re-query of the SAME window
# showed 50k+ spans flowing with attributes intact — Dynatrace Grail ingest lag
# raced the fresh engine pods (born 18 min before gate). Same failure mode S3
# attempt-3 hit (see s3-arrow-soak/driver.sh); retry with a settle wait before
# halting. A genuinely broken pipeline stays RED across all attempts and still
# halts with no load applied.
GATE_PASSES=0
for attempt in 1 2 3; do
  say "Running validate-phase.sh $ENGINE --window 15m (8 checks, must be GREEN) — attempt $attempt"
  if ./validate-phase.sh "$ENGINE" --window 15m > "$OUT/gate.out" 2>&1; then
    cp "$OUT/gate.out" "$OUT/gate-GREEN.out"
    say "GATE GREEN (attempt $attempt) — opening soak window"
    GATE_PASSES=1
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    setstate GATE_RETRY_WAIT
    say "GATE RED (attempt $attempt) — waiting 300s for DT ingestion to settle, then re-running"
    tail -6 "$OUT/gate.out" | tee -a "$LOG"
    sleep 300
    setstate GATE
  fi
done
if [ "$GATE_PASSES" -ne 1 ]; then
  setstate GATE_RED
  say "GATE RED after 3 attempts — NOT starting soak. Engines + apps left idling for diagnosis."
  tail -20 "$OUT/gate.out" | tee -a "$LOG"
  post "**GATE RED — S4 OTAP soak NOT started (ISI-3302).** validate-phase.sh otap-config-a failed 3 attempts (with ingestion-lag settle waits). Full report: \`_artifacts/isi1779/soak/S4-otap/gate.out\`. Engines+apps left idling for diagnosis; nothing was measured."
  exit 1
fi

# ─── SOAK_START ─────────────────────────────────────────────────────────────
setstate SOAK_START
kubectl create configmap isi1779-run-lock -n default \
  --from-literal=claimed="$(date -u +%FT%TZ)" --from-literal=owner=ISI-3302 --from-literal=run="$RUN_ID" \
  --dry-run=client -o yaml | kubectl apply -f - >>"$LOG" 2>&1

./pod-census.sh "$RUN_ID" start > "$OUT/census-START.txt" 2>>"$LOG" || say "WARN: start census non-zero"
S_EDGE=$(grep -oE 'bench-otap-config-a-collector-[a-z0-9-]+' "$OUT/census-START.txt" | head -1)
S_RELAY=$(grep -oE 'bench-df-engine-otap-[a-z0-9-]+' "$OUT/census-START.txt" | head -1)
kubectl get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' \
  | awk '$2 ~ /^bench-/' > "$OUT/engine-identity-START.txt"
grep -A3 -iE 'attribute landing|CHECK 7' "$OUT/gate.out" > "$OUT/attr-landing-verdict.txt" 2>/dev/null || true

START_TS="$(date -u +%FT%TZ)"; echo "$START_TS" > "$OUT/START_TS"
SOAK_SECS=86400
say "START=$START_TS ; soak duration ${SOAK_SECS}s (24h)"
say "Census at start: edge=$S_EDGE relay=$S_RELAY"

say "Applying soak jobs (50 VU/app, constant, 24h)"
kubectl apply -f loadtest/soak-jobs-otap-config-a.yaml >>"$LOG" 2>&1
setstate SOAK_RUNNING
sleep 30
say "Soak pods launched:"
kubectl get pods -A -l soak=isi1779 -o wide 2>&1 | tee -a "$LOG"

# ─── SOAK_RUNNING — hourly pulse ────────────────────────────────────────────
echo "timestamp,edge_pod,edge_restarts,relay_pod,relay_restarts,accepted,otap_sent,send_failed,relay_alive" \
  > "$OUT/pulse-hourly.csv"

SOAK_START_EPOCH=$(date +%s)
SOAK_END_EPOCH=$(( SOAK_START_EPOCH + SOAK_SECS ))
HOUR_INTERVAL=3600
NEXT_PULSE=$(( SOAK_START_EPOCH + HOUR_INTERVAL ))

while [ "$(date +%s)" -lt "$SOAK_END_EPOCH" ]; do
  now=$(date +%s)
  remaining=$(( SOAK_END_EPOCH - now ))
  say "Soak running — ${remaining}s remaining until 24h mark"

  sleep_to=$(( NEXT_PULSE < SOAK_END_EPOCH ? NEXT_PULSE : SOAK_END_EPOCH ))
  sleep_secs=$(( sleep_to - now ))
  if [ "$sleep_secs" -gt 0 ]; then sleep "$sleep_secs"; fi
  NEXT_PULSE=$(( NEXT_PULSE + HOUR_INTERVAL ))

  ts="$(date -u +%FT%TZ)"
  e="$(EDGEPOD)"; r="$(RELAYPOD)"
  if [ -z "$e" ] || [ -z "$r" ]; then
    say "WARN: engine pod GONE at $ts (edge=${e:-none} relay=${r:-none}) — soak contaminated"
    echo "${ts},${e:-GONE},?,${r:-GONE},?,-,-,-,DEAD" >> "$OUT/pulse-hourly.csv"
    continue
  fi
  erst=$(kubectl -n default get pod "$e" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
  rrst=$(kubectl -n default get pod "$r" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")

  # relay pipeline liveness (R1P3 death signature: pod Ready, cores gone)
  alive="ALIVE"
  if ! ./results/s4-otap-soak/engine-alive-051-otap.sh --live -n default -p "$r" \
      > "$OUT/pulse-relay-$(date -u +%H%M%S).out" 2>&1; then
    alive="DEAD"; say "WARN: relay pipeline DEAD at $ts (restarts=$rrst)"
  fi

  # edge collector counters (accepted / otap-sent / send_failed)
  acc="-"; sent="-"; sf="-"
  kubectl -n default port-forward "pod/$e" 18889:8888 >/dev/null 2>&1 &
  PF=$!; sleep 3
  M=$(curl -s --max-time 10 http://127.0.0.1:18889/metrics || true)
  kill $PF 2>/dev/null; wait $PF 2>/dev/null
  if [ -n "$M" ]; then
    acc=$(awk '/^otelcol_receiver_accepted_(spans|log_records|metric_points)/{s+=$2} END{printf "%.0f", s+0}' <<< "$M")
    sent=$(awk '/^otelcol_exporter_sent_(spans|log_records|metric_points)/{s+=$2} END{printf "%.0f", s+0}' <<< "$M")
    sf=$(awk '/^otelcol_exporter_send_failed_(spans|log_records|metric_points)/{s+=$2} END{printf "%.0f", s+0}' <<< "$M")
  fi
  echo "${ts},${e},${erst},${r},${rrst},${acc},${sent},${sf},${alive}" >> "$OUT/pulse-hourly.csv"
  say "Pulse $ts — edge=$e(rst=$erst acc=$acc sent=$sent sf=$sf) relay=$r(rst=$rrst alive=$alive)"

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

./pod-census.sh "$RUN_ID" end > "$OUT/census-END.txt" 2>>"$LOG" || say "WARN: end census non-zero"
E_EDGE=$(grep -oE 'bench-otap-config-a-collector-[a-z0-9-]+' "$OUT/census-END.txt" | head -1)
E_RELAY=$(grep -oE 'bench-df-engine-otap-[a-z0-9-]+' "$OUT/census-END.txt" | head -1)
CEDGE="MISMATCH edge start=$S_EDGE end=$E_EDGE"; [ -n "$S_EDGE" ] && [ "$S_EDGE" = "$E_EDGE" ] && CEDGE="MATCH edge ($S_EDGE)"
CREL="MISMATCH relay start=$S_RELAY end=$E_RELAY"; [ -n "$S_RELAY" ] && [ "$S_RELAY" = "$E_RELAY" ] && CREL="MATCH relay ($S_RELAY)"
say "census verdict: $CEDGE | $CREL"
{ echo "$CEDGE"; echo "$CREL"; } > "$OUT/census-verdict.txt"
kubectl get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' \
  | awk '$2 ~ /^bench-/' > "$OUT/engine-identity-END.txt"

r="$(RELAYPOD)"
./results/s4-otap-soak/engine-alive-051-otap.sh --live -n default -p "$r" \
  > "$OUT/engine-alive-post-soak.out" 2>&1 && say "Post-soak relay: pipeline ALIVE" || say "Post-soak relay: pipeline DEAD (record)"

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

say "Deleting soak jobs (24h soak complete)"
kubectl delete -f loadtest/soak-jobs-otap-config-a.yaml >>"$LOG" 2>&1 || say "WARN: job delete non-zero (may already be gone)"
kubectl delete configmap isi1779-run-lock -n default >>"$LOG" 2>&1 || true

setstate SOAK_COMPLETE
say "=== S4-OTAP SOAK COMPLETE. START=$START_TS END=$END_TS"
post "**S4 OTAP hop arm 24h soak COMPLETE (ISI-3302).** START=$START_TS END=$END_TS. Census: $CEDGE ; $CREL. Artifacts in \`_artifacts/isi1779/soak/S4-otap/\` (STATE=SOAK_COMPLETE). Next: RUN-REGISTER row + leak-readout for BOTH workloads (\`bench-otap-config-a-collector\` + \`bench-df-engine-otap\`) + verdict + push. Cluster is free for S2m (ISI-3303) after this readout."

# Leave engines+apps deployed (serial chain: S2m repoints next); driver exits.
