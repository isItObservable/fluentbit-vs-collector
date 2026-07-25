#!/usr/bin/env bash
# ISI-1879 — df_engine liveness for 0.51.0 (otel-arrow main @ eaf8f4cc).
#
# WHY A NEW VERSION: the DNF-era engine-alive.sh (results/r1p3-retry/) required a
# metric set literally named `receiver.otlp`. Between 0.50.0 (@7502e7d) and
# 0.51.0 (@eaf8f4cc) upstream migrated node metrics (#3437 per-signal
# produced/consumed for all nodes, #3532 enum attributes, #3560 batch metric
# changes). The single `receiver.otlp` set was SPLIT into
# receiver.otlp.{requests,acknowledgements,rejections,transport}, and the total
# set count on a healthy 2-core pipeline rose from ~145 to 633. The old script
# therefore reports a healthy 0.51.0 pipeline as DEAD (false positive) — which is
# exactly what happened in the first driver run.
#
# The death signal is unchanged and version-independent: when the pipeline cores
# panic, df_engine deregisters every pipeline metric set and the admin API serves
# only the process-level `engine` set (collapse to 1). We assert the four stage
# sets still exist; the receiver is matched by PREFIX so a future rename of the
# split sets does not re-introduce the same brittleness.
set -uo pipefail
NS=default; POD=""; SNAP=""
case "${1:-}" in
  --live) shift
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
python3 - "$SNAP" <<'PY'
import json, sys
sets = json.load(open(sys.argv[1])).get("metric_sets", [])
names = {s.get("name") for s in sets}
print(f"      {len(sets)} metric_sets, {len(names)} distinct names")
# receiver matched by prefix (split into .requests/.acknowledgements/... in 0.51.0)
have_receiver = any(n and n.startswith("receiver.otlp") for n in names)
exact = ["processor.attributes", "otap.processor.batch", "pipeline"]
checks = [("receiver.otlp*", have_receiver)] + [(r, r in names) for r in exact]
missing = [n for n, ok in checks if not ok]
for n, ok in checks:
    print(f"{'PASS' if ok else 'FAIL'}  metric_set {n}")
if missing:
    print(f"\nENGINE DEAD — {len(missing)} required pipeline metric set(s) absent: {' '.join(missing)}")
    print("  process alive (`engine` set served) but pipeline cores gone.")
    sys.exit(1)
print("\nENGINE ALIVE — every required pipeline metric set is registered.")
PY
