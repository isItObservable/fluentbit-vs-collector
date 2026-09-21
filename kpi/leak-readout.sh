#!/usr/bin/env bash
# memory leak readout (TAIL-flat, NOT first-vs-last).
# Note: a mechanical first-vs-last rule TRIPS on normal warm-up floor-creep
# to plateau. The real question is whether the TAIL is flat. This samples container
# memory over a window and evaluates the LAST third's slope; a leak is a tail that
# keeps rising, not a warm-up that plateaus. (bounded creep on encode is
# NOT a leak either — compare against the absolute plateau, not T0.)
#
# Usage:./leak-readout.sh <collector|fluentbit> [samples] [interval_s]
# For a real soak, point this at Grail (dtctl) history instead; this is the live oracle.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
ARM="${1:?arm: collector | fluentbit}"; N="${2:-12}"; IV="${3:-15}"
case "$ARM" in
  collector) NS=bench-collector;;
  fluentbit) NS=bench-fluentbit;;
  *) echo "unknown arm: $ARM" >&2; exit 2;;
esac

echo "[leak] $NS — $N samples @ ${IV}s (needs metrics-server)"
vals=()
for i in $(seq 1 "$N"); do
  # sum working-set MiB across the DaemonSet pods
  mib=$(kubectl -n "$NS" top pod --no-headers 2>/dev/null | awk '{gsub(/Mi/,"",$3); s+=$3} END{print s+0}')
  ts=$(date -u +%FT%TZ)
  echo " $ts ${mib}MiB"
  vals+=("$mib")
  [ "$i" -lt "$N" ] && sleep "$IV"
done

# TAIL-flat check: compare mean of last third vs mean of middle third.
python3 - "${vals[@]}" <<'PY'
import sys
v=[float(x) for x in sys.argv[1:]]
n=len(v)
if n<6: print("[leak] too few samples for tail analysis"); sys.exit(0)
third=n//3
mid=v[third:2*third]; tail=v[2*third:]
import statistics as st
m=st.mean(mid); t=st.mean(tail)
drift=(t-m)/m*100 if m else 0
print(f"[leak] mid-third mean={m:.1f}MiB tail-third mean={t:.1f}MiB tail-drift={drift:+.2f}%")
# heuristic: >5% still-rising tail over the sampled window = investigate (not auto-fail;
# floor-creep to plateau is normal — read the trend, confirm over a longer Grail window).
print("[leak] VERDICT:", "TAIL-FLAT (ok)" if drift<=5 else "TAIL-RISING — investigate over longer window (boundedness)")
PY
