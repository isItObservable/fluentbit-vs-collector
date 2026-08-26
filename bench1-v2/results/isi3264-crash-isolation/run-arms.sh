#!/usr/bin/env bash
# ============================================================================
# ISI-3264 driver — isolate the Fluent Bit v5.0.9 crash (flb_http_common.c:903
# -> flb_http2_response_begin, preceded by `[downstream] IO timeout`) by SIGNAL
# TYPE, under standard OpenTelemetry load. Detached (setsid) so it survives
# agent heartbeat deaths. Sequential arms A,B,C,D.
#
# Load generator: telemetrygen (github.com/open-telemetry/opentelemetry-collector
# -contrib) — the canonical OTel load tool. OTLP/gRPC == HTTP/2, the shared
# transport under test. Each arm sends ONLY one signal type into the v5 receiver:
#   A metrics-only   B traces-only   C logs-only
#   D connection-lifecycle control: many mostly-idle HTTP/2 connections, minimal
#     payload (high --workers, low --rate) to exercise open/idle/timeout/close.
#
# Per arm: apply load Deployment -> poll engine restartCount every POLL s ->
# on each new crash capture `logs --previous` + lastState.terminated -> stop at
# WINDOW s OR MAXCRASH crashes -> delete load -> record row.
#
# Usage: KUBECONFIG=... ./run-arms.sh
# Env: WINDOW (per-arm s, default 3600), MAXCRASH (default 2), POLL (default 30),
#      WORKERS (default 30), RATE (default 300), D_WORKERS (60), D_RATE (1).
# ============================================================================
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:?KUBECONFIG required}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/results"; mkdir -p "$OUT"
WINDOW="${WINDOW:-3600}"; MAXCRASH="${MAXCRASH:-2}"; POLL="${POLL:-30}"
WORKERS="${WORKERS:-30}"; RATE="${RATE:-300}"
D_WORKERS="${D_WORKERS:-60}"; D_RATE="${D_RATE:-1}"
NS=default; SEL="app=bench-fluentbit-v5"
TG=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
EP="bench-fluentbit-v5.default.svc.cluster.local:4317"
LOG="$OUT/driver.log"; TABLE="$OUT/RESULTS-TABLE.md"

log(){ echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"; }
engine_pod(){ kubectl get pod -n "$NS" -l "$SEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
restart_count(){ kubectl get pod -n "$NS" -l "$SEL" -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="fluent-bit")].restartCount}' 2>/dev/null; }

capture_crash(){ # $1 arm  $2 crash-index
  local arm="$1" idx="$2" pod base; pod="$(engine_pod)"; base="$OUT/${arm}-crash${idx}"
  log "  CRASH #$idx on $pod -> $base.*"
  kubectl get pod -n "$NS" "$pod" -o jsonpath='{.status.containerStatuses[?(@.name=="fluent-bit")].lastState.terminated}' 2>/dev/null > "$base.lastState.json"; echo >> "$base.lastState.json"
  kubectl logs -n "$NS" "$pod" -c fluent-bit --previous --tail=100 2>/dev/null > "$base.prev.log" || true
  if grep -qE 'flb_http_common\.c:903|flb_http2_response_begin' "$base.prev.log"; then
    echo yes > "$base.fp903"
  else
    echo no  > "$base.fp903"
  fi
}

apply_load(){ # $1 arm  $2 signal  $3 workers  $4 rate
  local arm="$1" sig="$2" w="$3" r="$4" lc; lc="$(echo "$arm" | tr 'A-Z' 'a-z')"
  kubectl apply -f - <<YAML >>"$LOG" 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: isi3264-load-${lc}
  namespace: default
  labels: { benchmark: isi1779, isi3264: load, arm: "${lc}" }
spec:
  replicas: 1
  selector: { matchLabels: { isi3264: load, arm: "${lc}" } }
  template:
    metadata:
      labels: { isi3264: load, arm: "${lc}" }
      annotations: { sidecar.istio.io/inject: "false" }
    spec:
      restartPolicy: Always
      containers:
        - name: telemetrygen
          image: ${TG}
          args:
            - "${sig}"
            - "--otlp-endpoint=${EP}"
            - "--otlp-insecure"
            - "--workers=${w}"
            - "--rate=${r}"
            - "--duration=${WINDOW}s"
          resources: { requests: { cpu: "200m", memory: "128Mi" }, limits: { cpu: "2", memory: "512Mi" } }
YAML
}

run_arm(){ # $1 arm  $2 signal  $3 label  $4 workers  $5 rate
  local arm="$1" sig="$2" label="$3" w="$4" r="$5" lc; lc="$(echo "$arm" | tr 'A-Z' 'a-z')"
  log "=== ARM $arm ($label) — signal=$sig workers=$w rate=$r window=${WINDOW}s ==="
  local pod0 rc0 t0; pod0="$(engine_pod)"; rc0="$(restart_count)"; rc0="${rc0:-0}"; t0="$(date +%s)"
  log "  engine pod=$pod0 baseline restartCount=$rc0"
  apply_load "$arm" "$sig" "$w" "$r"
  kubectl rollout status deploy/isi3264-load-"$lc" -n "$NS" --timeout=120s >>"$LOG" 2>&1
  log "  load running"
  local crashes=0 fp="n/a" end=$(( t0 + WINDOW )) last_rc="$rc0"
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep "$POLL"
    local rc pod; rc="$(restart_count)"; rc="${rc:-$last_rc}"; pod="$(engine_pod)"
    [ "$pod" != "$pod0" ] && log "  POD REPLACED $pod0 -> $pod (reschedule/OOM)"
    if [ "${rc:-0}" -gt "${last_rc:-0}" ] 2>/dev/null; then
      while [ "$last_rc" -lt "$rc" ]; do
        last_rc=$((last_rc+1)); crashes=$((crashes+1)); capture_crash "$arm" "$crashes"
        if grep -q yes "$OUT/${arm}-crash${crashes}.fp903" 2>/dev/null; then fp="yes"; elif [ "$fp" = "n/a" ]; then fp="no"; fi
      done
      log "  restartCount=$rc crashes_this_arm=$crashes"
      [ "$crashes" -ge "$MAXCRASH" ] && { log "  MAXCRASH reached — ending arm"; break; }
    fi
  done
  local t1 elapsed rate crashed; t1="$(date +%s)"; elapsed=$(( t1 - t0 ))
  rate=$(awk "BEGIN{ if ($elapsed>0) printf \"%.2f\", $crashes/($elapsed/3600); else print 0 }")
  crashed="no"; [ "$crashes" -gt 0 ] && crashed="yes"
  log "=== ARM $arm done — elapsed=${elapsed}s crashes=$crashes rate=${rate}/hr fp903=$fp ==="
  kubectl delete deploy/isi3264-load-"$lc" -n "$NS" --wait=true >>"$LOG" 2>&1; sleep 10
  echo "| $arm | $label | $crashed | $crashes | ${rate} | $fp | ${elapsed}s |" >> "$TABLE"
  echo "arm=$arm crashed=$crashed crashes=$crashes rate_per_hr=$rate fp903=$fp elapsed_s=$elapsed final_restartCount=$last_rc" >> "$OUT/summary.txt"
}

log "########## ISI-3264 signal-isolation run START ##########"
log "engine baseline: pod=$(engine_pod) restartCount=$(restart_count) image=fluent/fluent-bit:5.0.9 endpoint=$EP"
: > "$OUT/summary.txt"
cat > "$TABLE" <<'HDR'
# ISI-3264 — Fluent Bit v5.0.9 crash isolation by signal type (telemetrygen OTLP/gRPC load)

| arm | signal | crashed? | crashes | restarts/hr | fingerprint 903? | window |
|-----|--------|----------|---------|-------------|------------------|--------|
HDR

run_arm A metrics "metrics-only"                 "$WORKERS"   "$RATE"
run_arm B traces  "traces-only"                  "$WORKERS"   "$RATE"
run_arm C logs    "logs-only"                    "$WORKERS"   "$RATE"
run_arm D traces  "conn-lifecycle (min payload)" "$D_WORKERS" "$D_RATE"

log "########## ALL ARMS COMPLETE ##########"
{ echo; echo "Final engine restartCount: $(restart_count) on pod $(engine_pod)"; } >> "$TABLE"
log "results -> $TABLE"; touch "$OUT/DONE"
