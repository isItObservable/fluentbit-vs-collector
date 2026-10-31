#!/usr/bin/env bash
# lib.sh — shared arm config + helpers for the deploy -> validate -> teardown
# automation. Source this; do not execute. One place defines, per arm, the
# engine namespace, the self-telemetry endpoint, and the receive/export metric
# expressions — so the gate and the deploy/teardown scripts never drift.
set -euo pipefail

# Point KUBECONFIG at your own cluster. (No internal paths are baked in.)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
ART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${FRONTEND_SUCCESS_MIN:=95}"  # otel-demo frontend min success-rate % for the gate
: "${FRONTEND_PROBES:=40}"       # HTTP probes to compute the success rate

# Optional backend-receipt hook. The gate calls `backend_receipt <signal> <window>`
# and expects it to print a record count (>0 = received). Leave BACKEND_RECEIPT_CMD
# unset to skip the backend-receipt check (engine-export is still verified locally).
# Example: export BACKEND_RECEIPT_CMD=./backend-receipt-dynatrace.sh
: "${BACKEND_RECEIPT_CMD:=}"

# arm -> (ns, self-metrics port, self-metrics path, "engine kind", gateway selector)
arm_ns()       { case "$1" in fluentbit) echo bench-fluentbit;; collector) echo bench-collector;; arrow) echo bench-arrow;; otap) echo bench-otap;; *) return 1;; esac; }
arm_port()     { case "$1" in fluentbit) echo 2020;; *) echo 8888;; esac; }
arm_path()     { case "$1" in fluentbit) echo /api/v1/metrics/prometheus;; *) echo /metrics;; esac; }
arm_kind()     { case "$1" in fluentbit) echo fluentbit;; *) echo collector;; esac; }
arm_selector() { case "$1" in
  fluentbit|collector|arrow) echo "benchmark.component=gateway";;
  otap)                      echo "benchmark.component=df-engine";;
  *) return 1;; esac; }

log()  { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# port-forward a pod port, run a curl, clean up. Usage: scrape <ns> <selector> <port> <path>
# Binds a LOCAL HIGH port (port+10000) so a same-number listener on your workstation
# cannot silently shadow the forward (curl would hit the wrong process -> false fail).
scrape() {
  local ns="$1" sel="$2" port="$3" path="$4"
  local lport=$((port + 10000))
  local pod; pod=$(kubectl -n "$ns" get pod -l "$sel" -o name 2>/dev/null | head -1)
  [ -z "$pod" ] && return 3
  kubectl -n "$ns" port-forward "$pod" "$lport:$port" >/tmp/bench-pf.log 2>&1 & local p=$!
  sleep 4
  curl -s --max-time 8 "http://127.0.0.1:$lport$path" || true
  kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
}

# backend-receipt: delegate to a user-supplied, backend-specific hook if set.
# Prints a record count on stdout (0 if no hook / nothing received).
backend_receipt() {
  local signal="$1" window="${2:-15m}"
  [ -z "$BACKEND_RECEIPT_CMD" ] && { echo "SKIP"; return 0; }
  "$BACKEND_RECEIPT_CMD" "$signal" "$window" 2>/dev/null || echo 0
}
