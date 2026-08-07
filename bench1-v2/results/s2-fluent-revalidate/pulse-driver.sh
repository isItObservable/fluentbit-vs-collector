#!/usr/bin/env bash
# ============================================================================
# ISI-2093 S2-fluent RE-VALIDATION 24h soak — hourly liveness + crash-fingerprint
# ----------------------------------------------------------------------------
# Re-run of the ISI-1823 S2 soak to confirm the Fluent Bit 5.0.9 SIGSEGV
# crash-loop reproduces (was it a defect, or environmental / a one-off?).
#
# Detached (setsid nohup). Records ONE pulse per hour for 25 pulses covering the
# 24h window, then exits. NOT authoritative for stop/teardown — the finalizer
# (END census + leak-readout) is. Its job:
#   1. within-run liveness + EARLY detection of a mid-run pod REPLACEMENT
#      (a new pod name fakes a flat trend and invalidates the run — D12).
#   2. crash-loop confirmation: log restartCount every hour AND, whenever it
#      increases, capture the container lastState.terminated (exitCode/reason/
#      signal) + the crash stack from `kubectl logs --previous` so the
#      SIGSEGV @ flb_http_common.c:903 fingerprint is captured on THIS run.
#
# Primary question: does restartCount climb (~1/h) with the same fingerprint?
#   same fingerprint  => CONFIRMED stability defect
#   clean (0 restarts) => original result was environmental -> retract
# ============================================================================
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.config/capmox/observable-otelarrow.kubeconfig}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$DIR/pulses.log"
CRASHLOG="$DIR/crashes.log"
# Engine identity captured at START (written by the operator into window.env)
source "$DIR/window.env"
ENGINE_POD_START="${ENGINE_POD_START:?set in window.env}"
ENGINE_CREATED_START="${ENGINE_CREATED_START:?set in window.env}"

log(){ printf '%s\n' "$*" >> "$LOG"; }
clog(){ printf '%s\n' "$*" >> "$CRASHLOG"; }

prev_restarts=-1
log "=== S2-fluent RE-VALIDATION pulse driver started $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$ ==="
clog "=== S2-fluent RE-VALIDATION crash log — engine=$ENGINE_POD_START @ $ENGINE_CREATED_START ==="
for i in $(seq 1 25); do
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # engine census
  read -r epod ecreated erestarts ephase < <(kubectl get pods -n default -l app=bench-fluentbit-v5 \
    -o jsonpath='{.items[0].metadata.name}{" "}{.items[0].metadata.creationTimestamp}{" "}{.items[0].status.containerStatuses[0].restartCount}{" "}{.items[0].status.phase}{"\n"}' 2>/dev/null)
  npods=$(kubectl get pods -n default -l app=bench-fluentbit-v5 --no-headers 2>/dev/null | wc -l)
  # soak load liveness
  od=$(kubectl get pods -n otel-demo -l phase=leak24h --no-headers 2>/dev/null | grep -c Running)
  hs=$(kubectl get pods -n hipster-shop -l phase=leak24h --no-headers 2>/dev/null | grep -c Running)
  # app readiness (ready deployments)
  odready=$(kubectl get deploy -n otel-demo --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2] && a[2]>0)c++}END{print c+0}')
  hsready=$(kubectl get deploy -n hipster-shop --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2] && a[2]>0)c++}END{print c+0}')
  census="OK"
  if [[ "$epod" != "$ENGINE_POD_START" || "$ecreated" != "$ENGINE_CREATED_START" ]]; then
    census="REPLACED!! start=$ENGINE_POD_START@$ENGINE_CREATED_START now=$epod@$ecreated"
  fi
  log "PULSE $i $now | engine=$epod created=$ecreated restarts=$erestarts phase=$ephase pods=$npods census=$census | soak od=$od hs=$hs | ready od=$odready hs=$hsready"

  # crash-fingerprint capture on restart increase
  if [[ "$erestarts" =~ ^[0-9]+$ && "$prev_restarts" =~ ^[0-9]+$ && "$erestarts" -gt "$prev_restarts" && "$prev_restarts" -ge 0 ]]; then
    clog "--- restart bump $prev_restarts -> $erestarts detected at $now (pod $epod) ---"
    kubectl get pod -n default "$epod" -o jsonpath='lastState.terminated: exitCode={.status.containerStatuses[0].lastState.terminated.exitCode} reason={.status.containerStatuses[0].lastState.terminated.reason} signal={.status.containerStatuses[0].lastState.terminated.signal} startedAt={.status.containerStatuses[0].lastState.terminated.startedAt} finishedAt={.status.containerStatuses[0].lastState.terminated.finishedAt}{"\n"}' 2>/dev/null >> "$CRASHLOG"
    clog "  crash stack (kubectl logs --previous tail):"
    kubectl logs -n default "$epod" -c fluent-bit --previous --tail=40 2>/dev/null | sed 's/^/    /' >> "$CRASHLOG"
    clog ""
  fi
  prev_restarts="$erestarts"
  sleep 3600
done
log "=== S2-fluent RE-VALIDATION pulse driver finished 25 pulses $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
