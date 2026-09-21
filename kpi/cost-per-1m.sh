#!/usr/bin/env bash
# cost-per-1M records (headline comparison metric).
# millicores-consumed / (records-processed / 1e6). Lower = cheaper engine per unit work.
# Headline unit: millicores per 1M records (mc/1M).
# Live oracle: instantaneous CPU (metrics-server) over a rate window; for the real
# benchmark read the sustained soak average from Grail, not a spot sample.
#
# Usage:./cost-per-1m.sh <collector|fluentbit> [window_s]
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
ARM="${1:?arm: collector | fluentbit}"; W="${2:-60}"

case "$ARM" in
  collector) NS=bench-collector; PORT=8888; MPATH=/metrics
    rec_expr='/^otelcol_receiver_accepted/{s+=$2} END{print s+0}';;
  fluentbit) NS=bench-fluentbit; PORT=2020; MPATH=/api/v1/metrics/prometheus
    rec_expr='/^fluentbit_input_records_total/{s+=$2} END{print s+0}';;
  *) echo "unknown arm: $ARM" >&2; exit 2;;
esac
POD=$(kubectl -n "$NS" get pods -o name | head -1)

read_recs() { kubectl -n "$NS" port-forward "$POD" "$PORT:$PORT" >/tmp/cost-pf.log 2>&1 & local p=$!
  sleep 4; curl -s "http://127.0.0.1:$PORT$MPATH" | awk "$rec_expr"; kill "$p" 2>/dev/null||true; }

r0=$(read_recs); echo "[cost] t0 records=$r0; sampling CPU over ${W}s..."
mc_sum=0; ticks=0
end=$((SECONDS+W))
while [ "$SECONDS" -lt "$end" ]; do
  mc=$(kubectl -n "$NS" top pod --no-headers 2>/dev/null | awk '{gsub(/m/,"",$2); s+=$2} END{print s+0}')
  mc_sum=$((mc_sum+mc)); ticks=$((ticks+1)); sleep 10
done
r1=$(read_recs)

python3 - "$r0" "$r1" "$mc_sum" "$ticks" "$W" <<'PY'
import sys
r0,r1,mc_sum,ticks,W=map(float,sys.argv[1:])
recs=r1-r0
avg_mc=mc_sum/ticks if ticks else 0
if recs<=0: print("[cost] no record delta in window — increase window or check load"); raise SystemExit
cost=avg_mc/(recs/1e6)
print(f"[cost] delta_records={recs:.0f} avg_millicores={avg_mc:.1f} window={W:.0f}s")
print(f"[cost] COST-PER-1M = {cost:.2f} millicores/1M records")
PY
