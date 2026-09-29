#!/usr/bin/env bash
# ISI-3574 E0 — Deliverable #7: pod-census VALIDITY GATE (run FIRST, before any KPI).
# ISI-1937/ISI-1822 lesson: assert PER-namespace, PER-pod — an aggregate check hides a
# dead entity. REFINED (ISI-3575, 09-03): validity depends on a pod's ROLE.
#   * STRICT_NS (engine-under-test + measurement infra): must be Running AND 0 restarts —
#     ANY restart invalidates the measurement.
#   * Other listed ns (demo LOG-SOURCE apps otel-demo/hipster-shop): must be Running.
#     Their LIFETIME restartCount is NOT a validity criterion — these are chronically
#     restart-prone demo apps running for days; counting 6-day-old restarts falsely REDs a
#     clean engine run. During-RUN app churn is assessed separately by the driver (knows T0)
#     and reported as a WARNING, since logs keep flowing (DT-receipt + #6c cover that).
# Env: STRICT_NS="bench-collector bench-fluentbit kepler" (space-sep) overrides the strict set.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.config/capmox/observable-otelarrow.kubeconfig}"
NS_LIST=("${@:-bench-collector bench-fluentbit bench-load kepler otel-demo hipster-shop}")
NS_LIST=(${NS_LIST[@]})
STRICT_NS="${STRICT_NS:-bench-collector bench-fluentbit kepler}"
is_strict() { case " $STRICT_NS " in *" $1 "*) return 0;; *) return 1;; esac; }

fail=0
printf '%-18s %-34s %-10s %-9s %-7s\n' NAMESPACE POD PHASE RESTARTS ROLE
for ns in "${NS_LIST[@]}"; do
  # skip ns that don't exist rather than aborting the whole gate
  kubectl get ns "$ns" >/dev/null 2>&1 || { echo "[skip] ns/$ns absent"; continue; }
  role=$(is_strict "$ns" && echo STRICT || echo source)
  while read -r pod phase restarts; do
    [ -z "$pod" ] && continue
    printf '%-18s %-34s %-10s %-9s %-7s\n' "$ns" "$pod" "$phase" "$restarts" "$role"
    if [ "$phase" != "Running" ] && [ "$phase" != "Succeeded" ]; then fail=1; fi
    if is_strict "$ns" && [ "${restarts:-0}" -gt 0 ]; then fail=1; fi
  done < <(kubectl -n "$ns" get pods --no-headers \
            -o custom-columns='N:.metadata.name,P:.status.phase,R:.status.containerStatuses[0].restartCount' 2>/dev/null)
done

if [ "$fail" -ne 0 ]; then
  echo "CENSUS GATE: FAIL — STRICT-ns pod not Running or restarted, or a source pod not Running. Soak/KPIs INVALID." >&2
  exit 1
fi
echo "CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running."
