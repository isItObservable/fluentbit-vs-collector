#!/usr/bin/env bash
# ISI-1817 R1P3 retry — engine-side liveness for df_engine, in one HTTP GET.
#
# WHY THIS EXISTS
# df_engine dies by losing its pipeline worker threads while the PROCESS stays up.
# Kubernetes then reports the pod `1/1 Running`, `restarts=0`, Ready — and every
# sink-side check that reads a lookback window keeps returning real, large,
# pre-panic numbers (ISI-1817: gate green over an engine dead six minutes).
#
# The cheap tell is not that the counters are ZERO. It is that the pipeline metric
# sets STOP EXISTING. When the cores die the engine deregisters them, so the admin
# API returns only the process-level `engine` set:
#
#   healthy (ISI-1843 END snapshot) : 289 metric_sets, 17 distinct names
#   dead    (this run, 40 min after): 1 metric_set, name `engine`
#
# `keep_all_zeroes=true` is passed deliberately — it proves the sets are absent, not
# merely suppressed for being zero. A "counters are zero" check could not tell those
# apart, and a cumulative counter proves the engine WORKED, never that it WORKS.
#
# Usage:
#   ./engine-alive.sh <snapshot.json>            grade a banked snapshot
#   ./engine-alive.sh --live -n NS -p POD        port-forward a live pod and grade it
set -uo pipefail

# The four sets that MUST exist on a running pipeline, one per pipeline stage. Chosen
# so a partial failure (e.g. only the exporter gone) still fails.
REQUIRED=(receiver.otlp processor.attributes otap.processor.batch pipeline)

NS=default; POD=""; SNAP=""
case "${1:-}" in
  --live)
    shift
    while [ $# -gt 0 ]; do case "$1" in -n) NS=$2; shift 2;; -p) POD=$2; shift 2;; *) shift;; esac; done
    [ -n "$POD" ] || { echo "FATAL: --live needs -p POD"; exit 2; }
    kubectl -n "$NS" port-forward "pod/$POD" 18099:8080 >/dev/null 2>&1 &
    pf=$!; trap 'kill $pf 2>/dev/null' EXIT; sleep 4
    SNAP=$(mktemp)
    curl -sf "http://127.0.0.1:18099/api/v1/metrics?format=json&reset=false&keep_all_zeroes=true" -o "$SNAP" \
      || { echo "FAIL  admin API unreachable on $NS/$POD"; exit 1; }
    ;;
  ""|-h|--help) echo "usage: $0 <snapshot.json> | $0 --live -n NS -p POD"; exit 2;;
  *) SNAP=$1; [ -f "$SNAP" ] || { echo "FATAL: no such snapshot $SNAP"; exit 2; };;
esac

python3 - "$SNAP" "${REQUIRED[@]}" <<'PY'
import json, sys
snap, required = sys.argv[1], sys.argv[2:]
sets = json.load(open(snap)).get("metric_sets", [])
names = {s.get("name") for s in sets}
print(f"      {len(sets)} metric_sets, {len(names)} distinct names")
missing = [r for r in required if r not in names]
for r in required:
    print(f"{'PASS' if r in names else 'FAIL'}  metric_set {r}")
if missing:
    print(f"\nENGINE DEAD — {len(missing)} required pipeline metric set(s) absent: {' '.join(missing)}")
    print("  The process is alive (the `engine` set is still served) but the pipeline")
    print("  cores are gone. Kubernetes will still report the pod Ready with 0 restarts.")
    sys.exit(1)
print("\nENGINE ALIVE — every required pipeline metric set is registered.")
PY
