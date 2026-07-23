#!/usr/bin/env bash
# B1-v2 — compare two arms NORMALISED BY THROUGHPUT.
#
# Usage: ./normalise.sh <runA-id> <A-start> <A-end> <runB-id> <B-start> <B-end>
#
# WHY THIS EXISTS
# ---------------
# The fairness rules give every arm an identical LOAD CONFIGURATION: same VU
# ladder, same wall clock, same loadshape. They cannot give it identical
# ACHIEVED THROUGHPUT, and on 2026-07-23 the two Round 1 arms did not have it.
#
# Measured over equal 95-minute windows (R1P1 vs R1P2):
#
#   istio-mesh spans   6,757,423  ->  6,273,233   -7.17%
#   app-sdk spans      6,746,670  ->  6,143,271   -8.94%
#
# istio-mesh spans are emitted per request hop by the sidecar, so they track how
# many requests the apps actually SERVED. The gap is persistent, not a warm-up
# transient -- minutes 0-30 read -9.70% and minutes 60-90 still read -6.60%.
#
# WHY IT MATTERS: an engine that is handed ~7% less data will use less CPU for
# that reason alone. Comparing ABSOLUTE resource figures across arms therefore
# credits an engine for work it was never asked to do. The defensible
# comparison is per unit of work -- mCores per million records.
#
# This does NOT invalidate the run. It is a read-time normalisation, exactly
# like benchmark/service-key.dql: the telemetry config stays frozen and the engine
# stays the only configured variable. It changes how the numbers are READ.
#
# NORMALISE MEMORY TOO, NOT JUST CPU. The first version of this script
# normalised CPU only, and a comparison tool silently defines what gets
# compared: nobody noticed that memory moved the OTHER WAY until the numbers
# were re-read by hand. On Round 1 Fluent Bit spent ~36% less CPU per record
# than the collector and ~20% MORE memory per record (peak +59%). If a resource
# is not in this script, it is not in your headline.
#
# It also does not, by itself, explain the gap. Do not attribute it to the
# engine without evidence -- on the figures so far Fluent Bit uses substantially
# LESS CPU than the collector, which would predict MORE app headroom and more
# throughput, not less. State the gap, normalise for it, and let the full-window
# readout stand on its own.
set -uo pipefail
: "${CLUSTER_NAME:?set CLUSTER_NAME (see .env.example)}"

A_ID="${1:?runA id}"; A_FROM="${2:?A start}"; A_TO="${3:?A end}"
B_ID="${4:?runB id}"; B_FROM="${5:?B start}"; B_TO="${6:?B end}"

engine_of(){ case "$1" in *collector*) echo otel-collector;; *fluentbit*) echo fluentbit-v5;;
                          *arrow*) echo otel-arrow-native;; *) echo UNKNOWN;; esac; }

dql(){ dtctl query "$1" -o json 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('ERR'); raise SystemExit
r=d.get('records',d) if isinstance(d,dict) else d
print(r[0][sys.argv[1]] if r and sys.argv[1] in r[0] else 0)" "$2"; }

arm(){ # id from to -> "mesh appsdk logs cpu mem_avg mem_peak"
  local eng; eng="$(engine_of "$1")"
  local mesh appsdk logs cpu mem mempeak
  mesh=$(dql "fetch spans, from:\"$2\", to:\"$3\" | filter benchmark.engine == \"$eng\" and benchmark.telemetry_source == \"istio-mesh\" | summarize n = count()" n)
  appsdk=$(dql "fetch spans, from:\"$2\", to:\"$3\" | filter benchmark.engine == \"$eng\" and isNull(benchmark.telemetry_source) | summarize n = count()" n)
  # logs: NO k8s.cluster.name filter -- fluentbit never lands it on logs 
  logs=$(dql "fetch logs, from:\"$2\", to:\"$3\" | filter benchmark.engine == \"$eng\" | summarize n = count()" n)
  cpu=$(dql "timeseries c = avg(dt.kubernetes.container.cpu_usage), from:\"$2\", to:\"$3\", filter: { k8s.cluster.name == \"${CLUSTER_NAME}\" and matchesValue(k8s.workload.name, \"bench-*\") } | fieldsAdd m = arrayAvg(c) | summarize v = avg(m)" v)
  mem=$(dql "timeseries m = avg(dt.kubernetes.container.memory_working_set), from:\"$2\", to:\"$3\", filter: { k8s.cluster.name == \"${CLUSTER_NAME}\" and matchesValue(k8s.workload.name, \"bench-*\") } | fieldsAdd a = arrayAvg(m) | summarize v = avg(a)" v)
  mempeak=$(dql "timeseries m = avg(dt.kubernetes.container.memory_working_set), from:\"$2\", to:\"$3\", filter: { k8s.cluster.name == \"${CLUSTER_NAME}\" and matchesValue(k8s.workload.name, \"bench-*\") } | fieldsAdd a = arrayMax(m) | summarize v = max(a)" v)
  echo "$mesh $appsdk $logs $cpu $mem $mempeak"
}

echo "== throughput-normalised comparison"
read -r AM AA AL AC AMEM APEAK < <(arm "$A_ID" "$A_FROM" "$A_TO")
read -r BM BA BL BC BMEM BPEAK < <(arm "$B_ID" "$B_FROM" "$B_TO")

python3 - "$A_ID" "$AM" "$AA" "$AL" "$AC" "$AMEM" "$APEAK" \
         "$B_ID" "$BM" "$BA" "$BL" "$BC" "$BMEM" "$BPEAK" <<'PY'
import sys
def f(x):
    try: return float(x)
    except Exception: return 0.0
aid,am,aa,al,ac,amem,apeak, bid,bm,ba,bl,bc,bmem,bpeak = sys.argv[1:15]
am,aa,al,ac,amem,apeak = f(am),f(aa),f(al),f(ac),f(amem)/1048576,f(apeak)/1048576
bm,ba,bl,bc,bmem,bpeak = f(bm),f(ba),f(bl),f(bc),f(bmem)/1048576,f(bpeak)/1048576
at, bt = am+aa+al, bm+ba+bl
def pct(a,b): return f"{100*(b-a)/a:+.2f}%" if a else "n/a"
print(f"{'':22}{aid:>22}{bid:>22}{'delta':>12}")
for name,a,b in (("istio-mesh spans",am,bm),("app-sdk spans",aa,ba),
                 ("logs",al,bl),("TOTAL records",at,bt)):
    print(f"  {name:20}{a:>22,.0f}{b:>22,.0f}{pct(a,b):>12}")
print()
print(f"  {'engine CPU (mCores)':20}{ac:>22,.1f}{bc:>22,.1f}{pct(ac,bc):>12}")
print(f"  {'engine MEM avg (MiB)':20}{amem:>22,.1f}{bmem:>22,.1f}{pct(amem,bmem):>12}")
print(f"  {'engine MEM peak (MiB)':20}{apeak:>22,.1f}{bpeak:>22,.1f}{pct(apeak,bpeak):>12}")
if at and bt:
    acn, bcn = ac/(at/1e6), bc/(bt/1e6)
    amn, bmn = amem/(at/1e6), bmem/(bt/1e6)
    print()
    print(f"  {'mCores / 1M records':20}{acn:>22,.2f}{bcn:>22,.2f}{pct(acn,bcn):>12}   <- comparable")
    print(f"  {'MiB / 1M records':20}{amn:>22,.2f}{bmn:>22,.2f}{pct(amn,bmn):>12}   <- comparable")
print()
print("  istio-mesh spans track request HOPS, so a gap there means the arms did not")
print("  serve the same request volume. Absolute CPU credits an engine for work it")
print("  was never handed; per-1M-record figures do not. Quote the normalised rows.")
print("  READ BOTH RESOURCES. On Round 1 the CPU row and the memory row pointed in")
print("  OPPOSITE directions; a headline that quotes only one of them is not honest.")
PY
