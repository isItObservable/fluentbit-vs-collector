#!/usr/bin/env bash
# ============================================================================
# collect.sh — one benchmark snapshot of all three variants -> $1 (a file).
#
# Uniform sources so the comparison is fair:
#   * records shipped + loss   -> each edge component's self-telemetry
#   * CPU / memory / wire-bytes -> per-pod cAdvisor (same source for all three)
# Counters are monotonic since pod start. Take two snapshots ~T apart and
# diff.sh them for per-interval rates.
#
# Usage: KUBECONFIG=... ./collect.sh /tmp/snap_t0.txt
# ============================================================================
set -uo pipefail
NS=default
OUT=${1:-/dev/stdout}
: > "$OUT"
echo "TS=$(date +%s)  # $(date -u +%FT%TZ)" >> "$OUT"

pf() { # $1 pod $2 port $3 path -> prometheus text
  local lp=$((20000 + RANDOM % 9000))
  kubectl port-forward -n "$NS" "$1" ${lp}:$2 >/dev/null 2>&1 & local p=$!; sleep 3
  curl -s "http://localhost:${lp}$3"; kill $p 2>/dev/null
}

# ---- records + loss (self-telemetry) ----
for pod in $(kubectl get pods -n "$NS" -o name | grep otel-agent-collector | sed 's|pod/||'); do
  pf "$pod" 8888 /metrics | grep -v '^#' | grep -E "otelcol_(receiver_accepted_log_records|exporter_sent_log_records|exporter_send_failed_log_records|exporter_sent_wire\{.*Logs)" | sed "s|^|ARROW|;s|$| POD=$pod|" >> "$OUT"
done
for pod in $(kubectl get pods -n "$NS" -o name | grep otel-agent-otlp | sed 's|pod/||'); do
  pf "$pod" 8888 /metrics | grep -v '^#' | grep -E "otelcol_(receiver_accepted_log_records|exporter_sent_log_records|exporter_send_failed_log_records)" | sed "s|^|OTLP|;s|$| POD=$pod|" >> "$OUT"
done
for pod in $(kubectl get pods -n "$NS" -o name | grep fluent-bit-v5 | sed 's|pod/||'); do
  pf "$pod" 2020 /api/v2/metrics/prometheus | grep -v '^#' | grep -E "fluentbit_(input_records_total|output_proc_records_total|output_proc_bytes_total|output_dropped_records_total|output_retries_failed_total)" | sed "s|^|FLB|;s|$| POD=$pod|" >> "$OUT"
done

# ---- CPU / mem / wire (cAdvisor, per pod, uniform) ----
for node in $(kubectl get nodes -o name | grep worker | cut -d/ -f2); do
  kubectl get --raw "/api/v1/nodes/$node/proxy/metrics/cadvisor" 2>/dev/null \
    | grep -E "container_cpu_usage_seconds_total|container_memory_working_set_bytes|container_network_transmit_bytes_total" \
    | grep -E "otel-agent-collector|otel-agent-otlp|fluent-bit-v5" >> "$OUT"
done
echo "done -> $OUT ($(wc -l < "$OUT") lines)"
