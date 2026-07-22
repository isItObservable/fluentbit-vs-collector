#!/usr/bin/env bash
# ISI-1779 B1-v2 — recover a run's measurement window from Kubernetes itself.
#
# Usage: ./capture-window.sh <run-id> [kubeconfig]
#        ./capture-window.sh R1-P1-collector
#
# WHY THIS EXISTS
# ---------------
# The register's End timestamp must be "the moment load stops, before any
# teardown" (plan §5a). The timed run is 120 minutes; an agent heartbeat is 30.
# So the heartbeat that starts the run is NEVER the heartbeat that ends it, and
# reconstructing End from "when I next woke up" bakes idle tail into the window
# -- exactly the failure §5a calls out.
#
# It does NOT need a capture loop (board directive D8 forbids one, and a loop
# perturbs what it measures). Kubernetes already records the instant every ramp
# pod stopped, to the second, for free.
#
# WHICH FIELD -- measured live on observable-otelarrow 2026-07-22T14:40Z:
#
#   Job.status.completionTime            set ONLY on success. A Job whose pod
#                                        exits non-zero leaves it null:
#                                          probe-ok    -> 2026-07-22T14:40:41Z
#                                          probe-fail  -> None
#   pod .state.terminated.finishedAt     set for BOTH outcomes:
#                                          probe-ok   exit 0 -> 14:40:37Z
#                                          probe-fail exit 1 -> 14:40:46Z
#
# So END comes from the POD, not the Job. Two reasons:
#   1. Robustness. `--exit-code-on-error 0` is supposed to stop Locust failing a
#      run on a stray 500 (ISI-1822: 13 x 500 out of 78,258 requests marked a
#      healthy ramp `Failed`). If that flag is ever missing or ineffective, the
#      Job field goes null and the window becomes unrecoverable -- silently.
#   2. Accuracy. completionTime lags the pod by the controller's observation
#      delay: 14:40:41Z vs 14:40:37Z, 4s, on an idle cluster.
#
# END is the MAX finishedAt across all ramp pods in both namespaces: the four
# staggered steps end at the same wall-clock, and load is over when the last
# one stops.
set -euo pipefail

RUN_ID="${1:?run id required, e.g. R1-P1-collector}"
export KUBECONFIG="${2:-${KUBECONFIG:-/tmp/otelarrow.kubeconfig}}"
SEL='ramp=isi1779'

read -r START END < <(kubectl get pods -A -l "$SEL" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
starts,ends=[],[]
for p in d.get("items",[]):
    s=p.get("status",{})
    if s.get("startTime"): starts.append(s["startTime"])
    for cs in s.get("containerStatuses") or []:
        t=(cs.get("state") or {}).get("terminated") or {}
        if t.get("finishedAt"): ends.append(t["finishedAt"])
print(min(starts) if starts else "NO-RAMP-PODS", max(ends) if ends else ("STILL-RUNNING" if starts else "NO-RAMP-PODS"))')

echo "Run:   $RUN_ID"
echo "Start: $START   (first ramp pod start; cross-check against the date -u you recorded)"
echo "End:   $END   (max terminated.finishedAt across all ramp pods)"

if [[ "$END" == "NO-RAMP-PODS" ]]; then
  echo "no pods matching -l $SEL in any namespace -- the ramp has not been applied,"
  echo "or the pods were deleted before the window was captured (window UNRECOVERABLE)."
  exit 2
fi
if [[ "$END" == "STILL-RUNNING" ]]; then
  echo "load still running -- no End yet. Do NOT tear down."
  exit 1
fi

python3 - "$START" "$END" <<'PY'
import sys,datetime
f="%Y-%m-%dT%H:%M:%SZ"
try: a,b=[datetime.datetime.strptime(x,f) for x in sys.argv[1:3]]
except ValueError: sys.exit(0)
m=(b-a).total_seconds()/60
print(f"Duration: {m:.1f} min")
print("PASS: within 120 min +/-2" if abs(m-120)<=2 else
      f"WARN: expected ~120 min, got {m:.1f} -- one of the timestamps is wrong (plan 5a self-check)")
PY
echo
echo "Now run: ./pod-census.sh $RUN_ID end   # BEFORE any teardown"
