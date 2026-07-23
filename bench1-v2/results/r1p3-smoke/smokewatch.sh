#!/usr/bin/env bash
export KUBECONFIG=/home/hrexed/.config/capmox/observable-agentsandbox.kubeconfig
OUT=/tmp/isi1843-smoke.log
POD=$(kubectl -n dfsmoke get pod -l app=df-engine -o jsonpath='{.items[0].metadata.name}')
echo "--- extended watcher started $(date -u +%FT%TZ) ---" >> $OUT
for i in $(seq 1 70); do
  TS=$(date -u +%FT%TZ)
  PANIC=$(kubectl -n dfsmoke logs $POD -c df-engine 2>/dev/null | grep -cE 'panic|pipeline_runtime_failed|observed_error')
  READY=$(kubectl -n dfsmoke get pod $POD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  RST=$(kubectl -n dfsmoke get pod $POD -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  DEMO=$(kubectl -n otel-demo get pods --no-headers 2>/dev/null | grep -c "Running")
  SPANS=$(kubectl -n dfsmoke logs deploy/sink -c otelcol --since=60s 2>/dev/null | grep -oE '"spans": [0-9]+' | awk -F': ' '{s+=$2} END{print s+0}')
  LOGSC=$(kubectl -n dfsmoke logs deploy/sink -c otelcol --since=60s 2>/dev/null | grep -oE '"log records": [0-9]+' | awk -F': ' '{s+=$2} END{print s+0}')
  echo "$TS ready=$READY restarts=$RST panic_lines=$PANIC demo_running=$DEMO spans_last60s=$SPANS logs_last60s=$LOGSC" >> $OUT
  if [ "$PANIC" -gt 0 ]; then echo "!!! PANIC DETECTED at $TS" >> $OUT; kubectl -n dfsmoke logs $POD -c df-engine > /tmp/isi1843-smoke-panic.log 2>&1; break; fi
  sleep 30
done
echo "watch finished $(date -u +%FT%TZ)" >> $OUT
