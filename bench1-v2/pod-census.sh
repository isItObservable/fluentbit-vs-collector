#!/usr/bin/env bash
# ISI-1779 B1-v2 — pod census capture (board directive D12).
#
# Run this TWICE per phase: immediately after the Start timestamp, and immediately
# before the End timestamp — before any teardown. Paste the emitted rows straight
# into the "Pod census" table in results/RUN-REGISTER.md.
#
# Why it exists: a pod REPLACEMENT (reschedule, eviction, node drain, rollout) is
# INVISIBLE to dt.kubernetes.container.restarts, which counts in-place container
# restarts only. A replaced pod gets a new name and leaves that metric empty, while
# its newborn ~2 MiB working set poisons any workload-level min()/avg(). Verified
# live on observable-otelarrow over 2026-07-20T11:00Z -> 2026-07-22T11:00Z: six pod
# names across two workloads, zero restart datapoints.
#
# The check is NOT "restarts == 0". It is: same pod name, same creationTimestamp, at
# Start and at End, and pod count == expected replicas.
#
# Usage: ./pod-census.sh <run-id> <start|end> [kubeconfig]
#   ./pod-census.sh R1-P1-collector start
set -euo pipefail

RUN_ID="${1:?run id required, e.g. R1-P1-collector}"
WHEN="${2:?'start' or 'end' required}"
export KUBECONFIG="${3:-${KUBECONFIG:-/tmp/otelarrow.kubeconfig}}"

case "$WHEN" in
  start|Start|START) WHEN=Start ;;
  end|End|END)       WHEN=End ;;
  *) echo "second argument must be 'start' or 'end', got '$2'" >&2; exit 2 ;;
esac

# ISI-3302: otap-config-a is the campaign's only 2-replica topology (edge
# collector + df_engine relay, both bench-* in ns default). Allow an env
# override instead of hard-failing a legitimate Config A census — the exact
# trap ISI-1949 hit (kpi.txt: "census-end.sh printed FAIL expected 1").
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-1}"

echo "# pod census — ${RUN_ID} @ ${WHEN} — captured $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# cluster: $(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo '?')"
echo

rows=$(kubectl get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' \
  | awk '$2 ~ /^bench-/' || true)

if [ -z "$rows" ]; then
  echo "NO bench-* POD FOUND — the engine is not running. Do not record a window." >&2
  exit 1
fi

count=$(printf '%s\n' "$rows" | wc -l)

printf '%s\n' "$rows" | awk -v run="$RUN_ID" -v when="$WHEN" \
  '{ printf "| `%s` | %s | `%s` | `%s` | %s | %s | <fill: MATCH or REPLACED -> RUN INVALID> |\n", run, when, $2, $3, $4, $6 }'

echo
if [ "$count" -ne "$EXPECTED_REPLICAS" ]; then
  echo "CENSUS FAIL — ${count} engine pod(s) found, expected ${EXPECTED_REPLICAS}. The window is INVALID." >&2
  exit 1
fi
echo "CENSUS OK — ${count} engine pod, matching expected replicas (${EXPECTED_REPLICAS})."
echo "At End: verify the pod name AND creationTimestamp are byte-identical to the Start row."
echo "A restart count of 0 proves nothing here — a replacement never increments it."
