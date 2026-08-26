#!/usr/bin/env bash
# ISI-3302 — df_engine OTAP-RELAY liveness (0.51.0, receiver:otap).
#
# Same death-signal contract as results/r1p3-arrow-rebuild/engine-alive-051.sh:
# when the pipeline cores panic, df_engine deregisters every pipeline metric
# set and the admin API serves only the process-level `engine` set. We assert
# the stage sets still exist.
#
# WHY A VARIANT (not a reuse): engine-alive-051.sh matches the receiver set by
# the PREFIX `receiver.otlp`. The Config A relay's input node is receiver:otap
# (ISI-1884 RESULT 3: receiver:otap -> out, all three signals, 0 panic), so
# that script reports a HEALTHY relay as DEAD. Only the receiver prefix check
# differs; exact sets are unchanged (processor.attributes / otap.processor.batch
# / pipeline).
#
# Usage:
#   ./results/s4-otap-soak/engine-alive-051-otap.sh --live -n default -p POD
#   ./results/s4-otap-soak/engine-alive-051-otap.sh snapshot.json
set -uo pipefail
NS=default; POD=""; SNAP=""
case "${1:-}" in
  --live) shift
    while [ $# -gt 0 ]; do case "$1" in -n) NS=$2; shift 2;; -p) POD=$2; shift 2;; *) shift;; esac; done
    [ -n "$POD" ] || { echo "FATAL: --live needs -p POD"; exit 2; }
    kubectl -n "$NS" port-forward "pod/$POD" 18098:8080 >/dev/null 2>&1 &
    pf=$!; trap 'kill $pf 2>/dev/null' EXIT; sleep 4
    SNAP=$(mktemp)
    curl -sf "http://127.0.0.1:18098/api/v1/metrics?format=json&reset=false&keep_all_zeroes=true" -o "$SNAP" \
      || { echo "FAIL  admin API unreachable on $NS/$POD"; exit 1; }
    ;;
  ""|-h|--help) echo "usage: $0 <snapshot.json> | $0 --live -n NS -p POD"; exit 2;;
  *) SNAP=$1; [ -f "$SNAP" ] || { echo "FATAL: no such snapshot $SNAP"; exit 2; };;
esac
python3 - "$SNAP" <<'PY'
import json, sys
sets = json.load(open(sys.argv[1])).get("metric_sets", [])
names = {s.get("name") for s in sets}
print(f"      {len(sets)} metric_sets, {len(names)} distinct names")
# relay input node: receiver.otap (the OTLP prefix variant would false-FAIL it)
have_receiver = any(n and n.startswith("receiver.otap") for n in names)
exact = ["processor.attributes", "otap.processor.batch", "pipeline"]
checks = [("receiver.otap*", have_receiver)] + [(r, r in names) for r in exact]
missing = [n for n, ok in checks if not ok]
for n, ok in checks:
    print(f"{'PASS' if ok else 'FAIL'}  metric_set {n}")
if missing:
    print(f"\nENGINE DEAD — {len(missing)} required pipeline metric set(s) absent: {' '.join(missing)}")
    print("  process alive (`engine` set served) but pipeline cores gone.")
    sys.exit(1)
print("\nENGINE ALIVE — every required pipeline metric set is registered.")
PY
