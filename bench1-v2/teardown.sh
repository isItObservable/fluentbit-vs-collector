#!/usr/bin/env bash
# ISI-1779 B1-v2 — tear down one phase, in the one order that is safe.
#
# Usage: ./teardown.sh <run-id>            # DRY RUN — prints, deletes nothing
#        ./teardown.sh <run-id> --confirm  # actually deletes
#
# WHY THIS EXISTS
# ---------------
# The runbook specified this step as one sentence: "Then delete both apps and
# the engine and confirm the namespaces are clean." Every other step of the
# phase is scripted and gated. This one is irreversible, is executed last (when
# a 120-minute run is already in the bank), and sits next to two traps that a
# hand-typed kubectl will walk straight into:
#
#   TRAP 1 — teardown destroys the End timestamp.
#     End lives ONLY on the ramp pods' .state.terminated.finishedAt. Nothing is
#     captured locally. Delete first and 120 minutes of measurement becomes
#     unreadable, permanently. So G1 refuses to delete anything until the
#     register carries a real End for this run.
#
#   TRAP 2 — `kubectl delete ns hipster-shop` would destroy a CONSTANT.
#     hipster-shop/loadgenerator is a pre-campaign leftover (created
#     2026-07-21T15:59:35Z) that is in NO manifest and MUST survive every
#     teardown: it contributes identical load to all six runs, so removing it
#     mid-campaign manufactures a difference that is not the engine. Verified
#     2026-07-23: no manifest this script deletes DEFINES it -- the string
#     appears only in a comment and as the ramp jobs' container image. G4
#     re-checks that mechanically every run, and P1 verifies it survived.
#     This script NEVER deletes a namespace, only manifests and one Helm release.
#
# Istio is deliberately NOT torn down: the next phase reconfigures it in place
# with its own values (runbook step 6), and CAAPH reconciliation is paused for
# the campaign (ISI-1826).
set -uo pipefail

RUN_ID="${1:?run id required, e.g. R1-P2-fluentbit}"
shift
CONFIRM=""; ABORTED=0
for a in "$@"; do
  case "$a" in
    --confirm) CONFIRM="--confirm" ;;
    # --aborted: the phase STOPPED AT THE GATE and no timed run was ever
    # started, so there is no window to protect. Used for R1-P3-arrow on
    # 2026-07-23 (ISI-1817): df_engine panicked on all four pipeline cores
    # before the run began.
    #
    # This skips ONLY the gates that guard a BANKED MEASUREMENT (G1 End, G2 End
    # census, G3 ramp finished). It deliberately keeps every gate that guards
    # the PROTECTED CONSTANT (G4 + P1), because that hazard is identical whether
    # or not a run happened — and it is the irreversible one.
    #
    # Each skip is ANNOUNCED. A skipped check must never render as a passed
    # check (ISI-1830).
    --aborted) ABORTED=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done
export KUBECONFIG="${KUBECONFIG:-/tmp/otelarrow.kubeconfig}"
cd "$(dirname "$0")"

case "$RUN_ID" in
  *collector*) ENGINE=otel-collector ;;
  *fluentbit*) ENGINE=fluentbit-v5 ;;
  *arrow*)     ENGINE=otel-arrow-native ;;
  *) echo "cannot derive engine from run id '$RUN_ID'"; exit 2 ;;
esac

REG=results/RUN-REGISTER.md
PROTECTED_NS=hipster-shop
PROTECTED_NAME=loadgenerator
fail(){ echo "REFUSING TO TEAR DOWN -- $*"; exit 2; }

echo "== teardown $RUN_ID (engine $ENGINE)"
[[ "$CONFIRM" == "--confirm" ]] || echo "   DRY RUN -- pass --confirm to actually delete"
echo

if [[ $ABORTED -eq 1 ]]; then
  echo "!! ABORTED MODE -- no timed run was banked for $RUN_ID."
  echo "   SKIPPING G1 (End recorded), G2 (End census), G3 (ramp finished):"
  echo "   all three protect a measurement window, and there is none."
  echo "   G4 + P1 (protect ${PROTECTED_NS}/${PROTECTED_NAME}) still RUN -- that"
  echo "   hazard does not care whether a run happened."
  echo
  # Refuse if a real End IS present: that means a run WAS banked and --aborted
  # is being misused to bulldoze the gates that exist to protect it.
  AROW="$(grep -F "| \`${RUN_ID}\`" "$REG" | head -1)"
  AEND="$(awk -F'|' '{print $8}' <<<"$AROW" | tr -d ' `')"
  if [[ "$AEND" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    fail "--aborted refused: $RUN_ID HAS a recorded End ($AEND), so a run WAS
   banked. Use the normal path; the G1/G2/G3 gates exist to protect it."
  fi
  # And refuse while anything is still generating load.
  LIVE_RAMP="$(kubectl get pods -A -l ramp=isi1779 --no-headers 2>/dev/null | grep -c 'Running' || true)"
  if [[ "${LIVE_RAMP:-0}" -gt 0 ]]; then
    fail "--aborted refused: $LIVE_RAMP ramp pod(s) still Running. Load is
   flowing; this is not an aborted phase."
  fi
  echo "G3' ok  no ramp pods Running (nothing was ever started)"
  echo
fi

# ---------------------------------------------------------------- G1: End captured
if [[ $ABORTED -eq 0 ]]; then
ROW="$(grep -F "| \`${RUN_ID}\`" "$REG" | head -1)"
[[ -n "$ROW" ]] || fail "no register row for $RUN_ID in $REG"
END_CELL="$(awk -F'|' '{print $8}' <<<"$ROW" | tr -d ' `')"
if [[ -z "$END_CELL" || "$END_CELL" == *PENDING* || "$END_CELL" == *UNSET* ]]; then
  fail "the register has no End for $RUN_ID (cell: '${END_CELL:-empty}').
   End exists ONLY on the ramp pods and teardown deletes them. Run
   ./results/capture-window.sh $RUN_ID first, then record it."
fi
[[ "$END_CELL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "End cell '$END_CELL' is not an ISO-8601 UTC timestamp"
echo "G1 ok   End recorded: $END_CELL"

# ---------------------------------------------------------------- G2: End census recorded
CENSUS_ROW="$(grep -F "| \`${RUN_ID}\` | End" "$REG" | head -1)"
[[ -n "$CENSUS_ROW" && "$CENSUS_ROW" != *UNSET* ]] \
  || fail "the End pod-census row for $RUN_ID is still UNSET.
   D12: run ./pod-census.sh $RUN_ID end BEFORE teardown -- a mid-run pod
   replacement is unfalsifiable once the pods are gone."
echo "G2 ok   End census row present"

# ---------------------------------------------------------------- G3: ramp really stopped
if ./results/capture-window.sh "$RUN_ID" >/dev/null 2>&1; then
  echo "G3 ok   all ramp pods finished"
else
  fail "capture-window.sh does not report a clean finish (still running, or
   partial). Load may still be flowing. Re-check before deleting anything."
fi
fi   # end G1/G2/G3 (skipped in --aborted)

# ---------------------------------------------------------------- G4: protected object safe
# In aborted mode the ramp manifest is excluded: no ramp job was ever created,
# so it has nothing to delete and cannot define the protected object.
#
# It is excluded EXPLICITLY rather than by tolerating a missing file, because
# `[[ -f ]] || fail` below is a real guard for the normal path — a phase whose
# manifests have gone missing must not tear down. Note this is a fail-LOUD
# guard, not a silent skip: for the arrow arm it refuses outright, since
# loadtest/ramp-jobs-otel-arrow-native.yaml does not exist (ISI-1844 owns
# creating it).
if [[ $ABORTED -eq 1 ]]; then
  MANIFESTS=(apps/hipster-shop-${ENGINE}.yaml engines/${ENGINE}.yaml)
  echo "G4 note aborted mode: loadtest/ramp-jobs-${ENGINE}.yaml excluded from the"
  echo "        scan and from the deletes -- no ramp job was ever created."
else
  MANIFESTS=(loadtest/ramp-jobs-${ENGINE}.yaml apps/hipster-shop-${ENGINE}.yaml engines/${ENGINE}.yaml)
fi
for m in "${MANIFESTS[@]}"; do [[ -f "$m" ]] || fail "manifest missing: $m"; done
if python3 - "${MANIFESTS[@]}" <<'PY'
import sys,yaml
hits=[]
for f in sys.argv[1:]:
    for d in yaml.safe_load_all(open(f)):
        if not d or 'metadata' not in d: continue
        md=d['metadata']
        if md.get('name')=='loadgenerator' and md.get('namespace','hipster-shop')=='hipster-shop':
            hits.append(f"{f}: {d['kind']}/{md['name']}")
print("\n".join(hits))
sys.exit(1 if hits else 0)
PY
then echo "G4 ok   no manifest defines ${PROTECTED_NS}/${PROTECTED_NAME}"
else fail "a manifest now DEFINES ${PROTECTED_NS}/${PROTECTED_NAME} (above).
   Deleting it would remove a constant present in every other run and
   manufacture a difference that is not the engine. Fix the manifest first."
fi

PROTECTED_BEFORE="$(kubectl get deploy -n "$PROTECTED_NS" "$PROTECTED_NAME" \
  -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
[[ -n "$PROTECTED_BEFORE" ]] \
  && echo "G4 ok   ${PROTECTED_NS}/${PROTECTED_NAME} live, created $PROTECTED_BEFORE (must survive)" \
  || echo "G4 warn ${PROTECTED_NS}/${PROTECTED_NAME} not found -- already gone before this teardown"
echo

# ---------------------------------------------------------------- deletes
run(){ if [[ "$CONFIRM" == "--confirm" ]]; then echo "+ $*"; "$@"; else echo "  would run: $*"; fi; }

if [[ $ABORTED -eq 0 ]]; then
  run kubectl delete -f "loadtest/ramp-jobs-${ENGINE}.yaml" --ignore-not-found
else
  echo "  skipped: ramp-jobs delete (aborted mode -- none were created)"
fi
run kubectl delete -f "apps/hipster-shop-${ENGINE}.yaml"  --ignore-not-found
run helm uninstall otel-demo -n otel-demo
run kubectl delete -f "engines/${ENGINE}.yaml" --ignore-not-found
run kubectl delete cm isi1779-run-lock -n default --ignore-not-found
for ns in default otel-demo hipster-shop; do
  run kubectl annotate ns "$ns" isi1779.benchmark/run-lock- --overwrite
done
echo

# ---------------------------------------------------------------- post-conditions
if [[ "$CONFIRM" != "--confirm" ]]; then
  echo "dry run complete -- nothing was deleted."; exit 0
fi

sleep 10
echo "== post-conditions"
rc=0
PROTECTED_AFTER="$(kubectl get deploy -n "$PROTECTED_NS" "$PROTECTED_NAME" \
  -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
if [[ -n "$PROTECTED_BEFORE" ]]; then
  if [[ "$PROTECTED_AFTER" == "$PROTECTED_BEFORE" ]]; then
    echo "P1 ok   ${PROTECTED_NS}/${PROTECTED_NAME} survived, unchanged ($PROTECTED_AFTER)"
  else
    echo "P1 FAIL ${PROTECTED_NS}/${PROTECTED_NAME} was DESTROYED OR RECREATED."
    echo "        before='$PROTECTED_BEFORE' after='${PROTECTED_AFTER:-gone}'"
    echo "        It is a constant across all six runs. Restore it before the next phase."
    rc=1
  fi
fi
LEFT="$(kubectl get all -A -l benchmark=isi1779 --no-headers 2>/dev/null | grep -c . )"
if (( LEFT == 0 )); then echo "P2 ok   no benchmark=isi1779 objects left in any namespace"
else echo "P2 FAIL $LEFT benchmark=isi1779 object(s) still present:"
     kubectl get all -A -l benchmark=isi1779 --no-headers 2>/dev/null | sed 's/^/        /'; rc=1; fi
for ns in default otel-demo hipster-shop; do
  a="$(kubectl get ns "$ns" -o jsonpath='{.metadata.annotations.isi1779\.benchmark/run-lock}' 2>/dev/null)"
  [[ -z "$a" ]] || { echo "P3 FAIL run-lock annotation still on ns/$ns: $a"; rc=1; }
done
(( rc == 0 )) && echo "P3 ok   run-lock cleared on all three namespaces"
echo
(( rc == 0 )) && echo "TEARDOWN CLEAN -- next phase may start." \
              || echo "TEARDOWN INCOMPLETE -- do NOT start the next phase."
exit $rc
