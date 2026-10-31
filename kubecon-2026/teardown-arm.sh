#!/usr/bin/env bash
# ============================================================================
# teardown-arm.sh — repeatable TEARDOWN automation.
#
#   ./teardown-arm.sh <fluentbit|collector|arrow|otap>
#
# Serial single-engine model: fully remove engine E + the demo apps so the next
# arm deploys into a clean, uncontended cluster. The backend operator, istio,
# storage, and the bench-* namespace SHELLS stay (foundation persists across
# arms); only the engine workload + apps are removed. Verifies the engine ns is
# empty before exit.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ARM="${1:?usage: teardown-arm.sh <fluentbit|collector|arrow|otap>}"
NS=$(arm_ns "$ARM") || { echo "unknown arm: $ARM" >&2; exit 2; }
MF="$ART_DIR/manifests"
LABEL="${BENCH_LABEL:-benchmark=kubecon-2026}"

log "=== teardown arm=$ARM ==="
log "engine: delete $MF/arm-$ARM/"
[ -d "$MF/arm-$ARM" ] && kubectl delete -f "$MF/arm-$ARM/" --ignore-not-found --wait=true || true
# sweep anything left in the engine ns (keep the ns shell + its no-agent label)
kubectl -n "$NS" delete deploy,ds,sts,svc,cm,secret,job -l "$LABEL" --ignore-not-found || true

log "apps: uninstall otel-demo + hipster-shop (next arm gets a clean, uncontended env)"
helm uninstall otel-demo -n otel-demo 2>/dev/null || true
kubectl delete ns hipster-shop --ignore-not-found --wait=true || true

log "load: clear any residual generators"
kubectl -n bench-load delete job,deploy --all --ignore-not-found || true

# verify the engine ns is drained (explicit clean-and-recheck posture)
remaining=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -vc 'Completed\|Terminating' || true)
if [ "${remaining:-0}" -eq 0 ]; then
  log "PASS — engine ns $NS drained; cluster ready for the next arm."
else
  log "WARN — $remaining pod(s) still in $NS:"; kubectl -n "$NS" get pods
fi
