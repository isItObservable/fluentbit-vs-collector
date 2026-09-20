#!/usr/bin/env bash
# ISI-3574 E0 — Deliverable #7: loss accounting (accepted == sent).
# ISI-1843 lesson: received != exported is COALESCING, not loss — but for a raw
# accounting oracle we compare what the pipeline ACCEPTED vs what it SENT/exported.
# Collector: otelcol_receiver_accepted_* vs otelcol_exporter_sent_* (+ refused/failed).
# Fluent Bit: fluentbit_input_records_total vs fluentbit_output_proc_records_total
#             (+ fluentbit_output_dropped_records_total, fluentbit_output_errors_total).
# Reports per-signal accepted/sent/dropped and a loss %.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.config/capmox/observable-otelarrow.kubeconfig}"
ARM="${1:?arm: collector | fluentbit}"

pf() { # ns pod localport remoteport
  kubectl -n "$1" port-forward "$2" "$3:$4" >/tmp/kpi-pf.log 2>&1 & echo $!; }

case "$ARM" in
  collector)
    POD=$(kubectl -n bench-collector get pods -o name | head -1)
    PID=$(pf bench-collector "$POD" 8888 8888); sleep 4
    M=$(curl -s http://127.0.0.1:8888/metrics); kill "$PID" 2>/dev/null || true
    acc=$(awk '/^otelcol_receiver_accepted/{s+=$2} END{print s+0}' <<<"$M")
    ref=$(awk '/^otelcol_receiver_refused/ {s+=$2} END{print s+0}' <<<"$M")
    sent=$(awk '/^otelcol_exporter_sent/    {s+=$2} END{print s+0}' <<<"$M")
    fse=$(awk '/^otelcol_exporter_send_failed/{s+=$2} END{print s+0}' <<<"$M")
    echo "[collector] accepted=$acc refused=$ref sent=$sent send_failed=$fse"
    # ISI-1843: sent can EXCEED accepted (fan-out to N exporters/pipelines) — a raw
    # 1-sent/accepted then goes negative and is meaningless. The true loss oracle is
    # refused==0 && send_failed==0. Report the fan-out ratio separately for context.
    awk -v a="$acc" -v s="$sent" -v r="$ref" -v f="$fse" 'BEGIN{
      if(a>0) printf "fan-out ratio sent/accepted=%.3f (>1 = multi-exporter, expected)\n", s/a;
      printf "LOSS VERDICT: %s (refused=%d, send_failed=%d)\n", (r==0 && f==0)?"NO LOSS":"LOSS DETECTED", r, f;
    }'
    ;;
  fluentbit)
    POD=$(kubectl -n bench-fluentbit get pods -o name | head -1)
    PID=$(pf bench-fluentbit "$POD" 2020 2020); sleep 4
    M=$(curl -s http://127.0.0.1:2020/api/v1/metrics/prometheus); kill "$PID" 2>/dev/null || true
    inp=$(awk '/^fluentbit_input_records_total/{s+=$2} END{print s+0}' <<<"$M")
    out=$(awk '/^fluentbit_output_proc_records_total/{s+=$2} END{print s+0}' <<<"$M")
    drp=$(awk '/^fluentbit_output_dropped_records_total/{s+=$2} END{print s+0}' <<<"$M")
    err=$(awk '/^fluentbit_output_errors_total/{s+=$2} END{print s+0}' <<<"$M")
    echo "[fluentbit] input=$inp output=$out dropped=$drp errors=$err"
    awk -v i="$inp" -v d="$drp" 'BEGIN{ if(i>0) printf "loss%%=%.4f (dropped/input)\n",(d/i)*100; else print "no traffic yet"}'
    ;;
  *) echo "unknown arm: $ARM" >&2; exit 2 ;;
esac
