#!/usr/bin/env bash
# ============================================================================
# run-benchmark.sh — orchestrate the ISI-1779 phased benchmark exactly as
# Henrik specified (comment 2026-07-21):
#
#   Phase 1  stable30   50 VU on EACH app (otel-demo + hipster-shop), 30 min
#            -> wait for BOTH apps to recover
#   Phase 2  rampup2h   +50 VU every 30 min for 2 h (50->100->150->200)
#            -> wait for BOTH apps to recover
#   Phase 3  leak24h    50 VU on each app, 24 h  (memory-leak detection)
#
# Load is applied by the two Locust drivers (loadgen-otel-demo /
# loadgen-hipster-shop) sharing the phase-aware BenchmarkShape. At every phase
# boundary we snapshot all three edge shippers (arrow / otlp / fluentbit) with
# scripts/collect.sh so throughput / CPU-mem / loss can be computed per phase,
# and every SNAP_EVERY seconds through the 24 h leak phase so a rising
# collector RSS trend is visible.
#
# Idempotent-ish: safe to re-run; it re-creates the scripts ConfigMap and
# re-applies the drivers. Snapshots land in $OUTDIR.
#
# Usage:
#   export KUBECONFIG=~/.config/capmox/observable-otelarrow.kubeconfig
#   ./run-benchmark.sh [OUTDIR]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="${1:-/tmp/isi1779-run}"
NS_APPS_OTEL="otel-demo"
NS_APPS_HIPSTER="hipster-shop"
RECOVERY_MAX="${RECOVERY_MAX:-1800}"   # cap the "wait for recovery" gate at 30 min
RECOVERY_QUIET="${RECOVERY_QUIET:-180}" # apps must stay Ready this long to count as recovered
SNAP_EVERY="${SNAP_EVERY:-7200}"       # leak phase: snapshot every 2 h

mkdir -p "$OUTDIR"
log() { echo "[$(date -u +%FT%TZ)] $*"; }

snap() { # $1 label
  log "snapshot: $1"
  "$HERE/../scripts/collect.sh" "$OUTDIR/snap_$1.txt" || log "WARN snapshot $1 failed"
}

apps_ready() {
  # true only if every pod in both app namespaces is Ready
  for ns in "$NS_APPS_OTEL" "$NS_APPS_HIPSTER"; do
    # count pods that are NOT Running/Completed or not fully ready
    local notready
    notready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | awk '{split($2,a,"/"); if (a[1]!=a[2] && $3!="Completed") c++} END{print c+0}')
    [ "${notready:-1}" -eq 0 ] || return 1
  done
  return 0
}

wait_recovery() { # gate between phases: apps Ready and stable for RECOVERY_QUIET
  log "recovery gate: waiting for $NS_APPS_OTEL + $NS_APPS_HIPSTER to settle (max ${RECOVERY_MAX}s)"
  local start now quiet_start=0
  start=$(date +%s)
  while :; do
    now=$(date +%s)
    if apps_ready; then
      [ "$quiet_start" -eq 0 ] && quiet_start=$now
      if [ $((now - quiet_start)) -ge "$RECOVERY_QUIET" ]; then
        log "recovery gate: apps stable ${RECOVERY_QUIET}s -> recovered"
        return 0
      fi
    else
      quiet_start=0
    fi
    if [ $((now - start)) -ge "$RECOVERY_MAX" ]; then
      log "recovery gate: hit RECOVERY_MAX ${RECOVERY_MAX}s -> proceeding (documented cap)"
      return 0
    fi
    sleep 30
  done
}

set_phase() { # $1 phase name
  log "phase -> $1"
  kubectl set env deploy/loadgen-otel-demo    LOAD_PHASE="$1" -n default >/dev/null
  kubectl set env deploy/loadgen-hipster-shop LOAD_PHASE="$1" -n default >/dev/null
  kubectl rollout restart deploy/loadgen-otel-demo deploy/loadgen-hipster-shop -n default >/dev/null
  kubectl rollout status  deploy/loadgen-otel-demo -n default --timeout=120s
  kubectl rollout status  deploy/loadgen-hipster-shop -n default --timeout=120s
}

# --- 0. deploy drivers (scripts ConfigMap from the .py, then both Deployments)
log "creating loadtest-scripts ConfigMap from python files"
kubectl create configmap loadtest-scripts -n default \
  --from-file="$HERE/loadshape.py" \
  --from-file="$HERE/tasks_otel_demo.py" \
  --from-file="$HERE/tasks_hipster_shop.py" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$HERE/locust-otel-demo.yaml" -f "$HERE/locust-hipster-shop.yaml"

# --- Phase 1: stable 30 min
set_phase stable30
snap "p1_stable_t0"
log "phase 1 (stable30): holding 50 VU/app for 1800s"; sleep 1800
snap "p1_stable_t1"
wait_recovery

# --- Phase 2: rampup 2 h (+50 VU / 30 min)
set_phase rampup2h
snap "p2_ramp_t0"
for m in 30 60 90 120; do
  sleep 1800
  snap "p2_ramp_${m}min"
done
wait_recovery

# --- Phase 3: leak 24 h (periodic snapshots for RSS trend)
set_phase leak24h
snap "p3_leak_t0"
elapsed=0
while [ "$elapsed" -lt 86400 ]; do
  sleep "$SNAP_EVERY"; elapsed=$((elapsed + SNAP_EVERY))
  snap "p3_leak_${elapsed}s"
done
snap "p3_leak_end"

log "done. Compute per-phase tables, e.g.:"
log "  python3 $HERE/../scripts/compute.py $OUTDIR/snap_p1_stable_t0.txt $OUTDIR/snap_p1_stable_t1.txt"
log "  python3 $HERE/../scripts/compute.py $OUTDIR/snap_p3_leak_t0.txt   $OUTDIR/snap_p3_leak_end.txt   # 24h leak delta"
