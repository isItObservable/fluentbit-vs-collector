#!/usr/bin/env bash
# ISI-3574 E0 — Deliverable #6: stable-load harness driver.
# Two profiles reproducing a fixed rate against a chosen engine arm:
#   2h-rampup  → gate profile (warm-up + ramp to target)
#   24h-stable → soak profile (hold target rate for 24h)
#
# Usage:  ./run-profile.sh <2h-rampup|24h-stable> <collector|fluentbit>
#
# ⭐ ISI-1927: LOCUST_RUN_TIME / --duration was NOT honoured on 1/8 pods in the prior
#   benchmark, over-running the window and skewing the tail. This driver ALWAYS enforces
#   a hard `kubectl delete` backstop at T+DURATION+120s regardless of the generator's own
#   duration flag, so no generator can outlive its profile.
# ⭐ ISI-3264: standard telemetrygen framing over the real Istio mesh (no slowloris).
set -euo pipefail

PROFILE="${1:?profile: 2h-rampup | 24h-stable}"
ARM="${2:?arm: collector | fluentbit}"
KDIR="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.config/capmox/observable-otelarrow.kubeconfig}"

case "$ARM" in
  collector) EP="bench-collector-otlp.bench-collector.svc.cluster.local:4317" ;;
  fluentbit) EP="bench-fluentbit-otlp.bench-fluentbit.svc.cluster.local:4317" ;;
  *) echo "unknown arm: $ARM" >&2; exit 2 ;;
esac

case "$PROFILE" in
  2h-rampup)  DUR="2h";  SPAN_RATE="200"; METRIC_RATE="100"; HARD_KILL_S=$((2*3600+120)) ;;
  24h-stable) DUR="24h"; SPAN_RATE="200"; METRIC_RATE="100"; HARD_KILL_S=$((24*3600+120)) ;;
  *) echo "unknown profile: $PROFILE" >&2; exit 2 ;;
esac

echo "[harness] profile=$PROFILE arm=$ARM endpoint=$EP duration=$DUR hardkill=+${HARD_KILL_S}s"

# Render + apply the generators pointed at this arm.
sed -e "s#PLACEHOLDER:4317#${EP}#g" \
    -e "s#value: \"2h\"#value: \"${DUR}\"#g" \
    -e "s#value: \"200\"#value: \"${SPAN_RATE}\"#g" \
    -e "s#value: \"100\"#value: \"${METRIC_RATE}\"#g" \
    "$KDIR/telemetrygen-load.yaml" | kubectl apply -f -

# App traffic: otel-demo + hipster-shop already emit continuously; the loadgenerators
# there provide the app-level trace fan-out. telemetrygen adds the fixed raw-signal floor.

# Hard backstop (ISI-1927): guarantee the window closes on time.
echo "[harness] backstop armed; will delete ns/bench-load at T+${HARD_KILL_S}s"
( sleep "$HARD_KILL_S" && kubectl delete ns bench-load --wait=false \
    && echo "[harness] HARD KILL fired at $(date -u +%FT%TZ)" ) &
echo "[harness] backstop PID $!  (record this; kill it only if you delete ns/bench-load early)"
