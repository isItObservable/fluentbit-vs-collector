#!/usr/bin/env bash
# ============================================================================
# B1-v2 — produce a run's readout from its RUN-REGISTER window.
# ----------------------------------------------------------------------------
#   ./benchmark/readout.sh <run-id> <start-utc> <end-utc>
#   ./benchmark/readout.sh R1-P1-collector 2026-07-22T15:58:43Z 2026-07-22T17:59:21Z
#
# Prints the three things the methodology asks for per test — LOAD, RESOURCE, SPANS —
# in the same order and the same shapes for every arm.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS (2026-07-23)
# ---------------------------------------------------------------------------
# R1P1's headline numbers (190.7 mCores / 108 MiB / 122 buckets / 18,499,537
# spans) were produced by hand at the end of the phase. The query SHAPES were
# in the dashboard, but nothing in the repo pinned WHICH shape, WHICH interval
# or WHICH filter produced a given figure. Two arms compared with
# almost-identical queries is the same class of defect as two arms run with
# almost-identical load: it still yields a number, and the number is wrong in a
# way no one can see afterwards.
#
# This is the read-side counterpart to render.sh. Same principle: "only the
# engine differs between the arms" should be something you can PROVE, not
# something you assert. Hence --selftest.
#
# ---------------------------------------------------------------------------
# THE CENSUS IS A GATE, NOT A TILE
# ---------------------------------------------------------------------------
# Methodology rule D12: a failed census VOIDS the run and it gets
# repeated. So the census runs FIRST and this script REFUSES to print resource
# or span numbers if it fails. A caveat next to a wrong number is not a fix --
# in a published comparison, the number is what people read.
#
# ---------------------------------------------------------------------------
# TIMEFRAMES ARE ABSOLUTE AND QUOTED
# ---------------------------------------------------------------------------
# `from:"2026-07-22T15:58:43Z"` -- the quotes are load-bearing. Unquoted is a
# PARSE_ERROR, and timestamp("...") fails with "has to be a long, but was a
# string" (validated against the Dynatrace tenant). The whole no-snapshot design
# (plan D8) depends on replaying a register window hours or days later, which a
# relative `now()-N` cannot express.
#
# INTERVAL is pinned to 1m rather than left to auto-selection. Dynatrace picks
# the interval from the window LENGTH, so a 120.6-minute arm and a 120.0-minute
# arm can land on different bucket sizes and their per-bucket coverage
# percentages then are not comparable quantities.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-${CLUSTER_NAME:?set CLUSTER_NAME (see .env.example)}}"
INTERVAL="${INTERVAL:-1m}"
CENSUS_MIN_COVERAGE="${CENSUS_MIN_COVERAGE:-90}"

if [[ "${1:-}" == "--selftest" ]]; then
  # Replay R1-P1-collector and assert this script reproduces the numbers that
  # were reported by hand for it. If this fails, P2/P3 readouts produced by this
  # script are NOT comparable to the banked P1 row and must not be published.
  exec "$HERE/readout.sh" R1-P1-collector 2026-07-22T15:58:43Z 2026-07-22T17:59:21Z --expect-p1
fi

RUN_ID="${1:?run id required, e.g. R1-P2-fluentbit}"
START="${2:?start UTC required, e.g. 2026-07-23T08:34:49Z}"
END="${3:?end UTC required, e.g. 2026-07-23T10:34:49Z}"
EXPECT_P1=0
[[ "${4:-}" == "--expect-p1" ]] && EXPECT_P1=1

# TWO timeframe strings, and they are NOT interchangeable: `interval:` is a
# `timeseries` parameter only. Appending it to a `fetch` is a syntax error, and
# because this script pipes DQL errors to /dev/null and prints whatever records
# came back, that error surfaced as an EMPTY SPANS SECTION rather than a failure
# — the census, load and resource blocks all printed normally above it. Caught
# by --selftest on the P1 window; a silently-missing section is exactly the kind
# of thing that reads as "no spans" instead of "broken query".
TF="from:\"$START\", to:\"$END\", interval:$INTERVAL"       # timeseries only
TF_FETCH="from:\"$START\", to:\"$END\""                      # fetch only

dql() {
  dtctl query -f - -o json 2>/dev/null <<< "$1" \
    | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: print("[]"); raise SystemExit
r = d.get("result", d)
print(json.dumps(r.get("records", r if isinstance(r, list) else [])))'
}

hdr() { printf '\n=== %s ===\n' "$*"; }

echo "B1-v2 readout — run $RUN_ID"
echo "window $START -> $END   interval=$INTERVAL   cluster=$CLUSTER"

# ---------------------------------------------------------------------------
# 0. CENSUS GATE — must pass before anything else is printed
# ---------------------------------------------------------------------------
hdr "CENSUS GATE (D12) — coverage >= ${CENSUS_MIN_COVERAGE}%, pods == expected replicas"
census=$(dql "timeseries mem = avg(dt.kubernetes.container.memory_working_set), by:{k8s.workload.name, k8s.pod.name}, $TF, filter: k8s.cluster.name == \"$CLUSTER\" and startsWith(k8s.workload.name, \"bench-\")
| fieldsAdd live_buckets = arraySize(arrayRemoveNulls(mem)), window_buckets = arraySize(mem)
| fieldsAdd coverage_pct = 100.0 * arraySize(arrayRemoveNulls(mem)) / arraySize(mem)
| fields engine = k8s.workload.name, pod = k8s.pod.name, live_buckets, window_buckets, coverage_pct
| sort coverage_pct asc")

verdict=$(CENSUS="$census" MINCOV="$CENSUS_MIN_COVERAGE" python3 -c '
import json, os, sys
rows = json.loads(os.environ["CENSUS"] or "[]")
mincov = float(os.environ["MINCOV"])
if not rows:
    print("FAIL|no engine pod reported dt.kubernetes.container.* in this window")
    sys.exit()
bad = []
for r in rows:
    cov = float(r.get("coverage_pct") or 0)
    print("  %-34s %-46s %s/%s buckets  %.2f%%" % (
        r.get("engine"), r.get("pod"), r.get("live_buckets"), r.get("window_buckets"), cov),
        file=sys.stderr)
    if cov < mincov:
        bad.append("%s coverage %.2f%% < %s%%" % (r.get("pod"), cov, mincov))
if len(rows) != 1:
    bad.append("pod count %d != expected replicas 1 -> window covers more than one pod lifetime" % len(rows))
print(("FAIL|" + "; ".join(bad)) if bad else "PASS|1 pod, full-window coverage")
')
echo "$verdict" | sed 's/^\(PASS\|FAIL\)|/CENSUS \1 — /'

# ---------------------------------------------------------------------------
# COVERAGE-GAP DISCRIMINATOR — added 2026-07-23 
# ---------------------------------------------------------------------------
# D12 says a failed census VOIDS the run. That is right for the failure it was
# written against — a pod REPLACED mid-window, which the restarts metric cannot
# see. But the census measures metric COVERAGE, and coverage has a second,
# entirely different cause: nobody was COLLECTING.
#
# Measured live during R1P2: the engine pod's coverage read 93.10% (54/58) with
# two nulls mid-window. The pod was never replaced — same name, same
# creationTimestamp, 0 restarts. Checking every pod on the cluster settled it:
# **all 112 pods shared the identical mid-window gap**, i.e. a cluster-wide
# Dynatrace k8s collection hiccup of ~2 minutes.
#
# At ~2 minutes over a 120-minute window that costs ~1.6% and nothing else. But
# a 15-minute collection outage would drag a PERFECTLY VALID run under the 90%
# line and void two hours of cluster time for a reason that has nothing to do
# with the engine. That is a false negative in the validity gate, and it is
# silent — low coverage looks identical either way.
#
# The discriminator is cheap: a pod-lifetime gap belongs to ONE pod, a
# collection gap is shared by ALL of them. This never auto-passes a failed
# census — D12 stands — it just tells you which of the two you are looking at,
# so the decision to void is made on evidence instead of on a percentage.
if [[ "$verdict" != PASS* ]] || printf '%s' "$census" | grep -q '"coverage_pct": *[0-9]*\.[0-9]'; then
  shared=$(dql "timeseries mem = avg(dt.kubernetes.container.memory_working_set), by:{k8s.pod.name}, $TF, filter: k8s.cluster.name == \"$CLUSTER\"
| fieldsAdd nulls = arraySize(mem) - arraySize(arrayRemoveNulls(mem))
| summarize pods = count(), with_gap = countIf(nulls > 0)")
  SH="$shared" python3 -c '
import json, os
rows = json.loads(os.environ["SH"] or "[]")
if not rows:
    print("  gap discriminator: no cluster-wide data returned"); raise SystemExit
r = rows[0]
pods = int(float(r.get("pods") or 0)); gap = int(float(r.get("with_gap") or 0))
if pods and gap == pods:
    print("  gap discriminator: ALL %d pods on the cluster show a gap in this window" % pods)
    print("    -> COLLECTION outage, NOT a pod-lifetime gap. The engine pod was not")
    print("       replaced. Confirm pod identity with pod-census.sh before voiding.")
elif gap:
    print("  gap discriminator: %d of %d cluster pods show a gap" % (gap, pods))
    print("    -> partial. If the engine pod is among the few, suspect its lifetime;")
    print("       if most pods are affected, suspect collection.")
else:
    print("  gap discriminator: no other pod on the cluster has a gap")
    print("    -> a gap here would be specific to the engine pod. Treat as a")
    print("       LIFETIME problem and check pod identity immediately.")
'
fi

if [[ "$verdict" == FAIL* ]]; then
  echo
  echo "REFUSING TO PRINT NUMBERS. A failed census VOIDS the run (D12) — it gets"
  echo "re-run, not reported with a caveat."
  echo "Read the gap discriminator above FIRST: if the whole cluster shares the gap,"
  echo "this is a collection outage and the run may well be valid — confirm the pod"
  echo "name and creationTimestamp are unchanged before throwing the window away."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. LOAD
# ---------------------------------------------------------------------------
hdr "LOAD"
python3 -c '
import sys
from datetime import datetime
s, e = sys.argv[1], sys.argv[2]
f = "%Y-%m-%dT%H:%M:%SZ"
d = (datetime.strptime(e, f) - datetime.strptime(s, f)).total_seconds() / 60
print("  8-job staggered ramp, both apps simultaneously, 50->100->150->200 VU per app")
print("  duration %.1f min (target 120, tolerance +/-2)%s" % (d, "" if abs(d-120) <= 2 else "   <-- OUT OF TOLERANCE"))
' "$START" "$END"

# ---------------------------------------------------------------------------
# 2. RESOURCE — per pod, never per workload (D12)
# ---------------------------------------------------------------------------
hdr "RESOURCE — engine pod (cpu_usage is in mCores; verified empirically)"
res=$(dql "timeseries { cpu = avg(dt.kubernetes.container.cpu_usage), mem = avg(dt.kubernetes.container.memory_working_set) }, by:{k8s.workload.name, k8s.pod.name}, $TF, filter: k8s.cluster.name == \"$CLUSTER\" and startsWith(k8s.workload.name, \"bench-\")
| fieldsAdd cpu_avg_mc = arrayAvg(cpu), cpu_p95_mc = arrayPercentile(cpu, 95), cpu_max_mc = arrayMax(cpu),
            mem_avg_mib = arrayAvg(mem) / 1048576, mem_peak_mib = arrayMax(mem) / 1048576
| fields engine = k8s.workload.name, pod = k8s.pod.name, cpu_avg_mc, cpu_p95_mc, cpu_max_mc, mem_avg_mib, mem_peak_mib
| sort cpu_avg_mc desc")
RES="$res" python3 -c '
import json, os
for r in json.loads(os.environ["RES"] or "[]"):
    print("  %s" % r.get("pod"))
    print("    CPU  avg %.1f mc   p95 %.1f mc   max %.1f mc" % (
        float(r.get("cpu_avg_mc") or 0), float(r.get("cpu_p95_mc") or 0), float(r.get("cpu_max_mc") or 0)))
    print("    MEM  avg %.1f MiB  peak %.1f MiB" % (
        float(r.get("mem_avg_mib") or 0), float(r.get("mem_peak_mib") or 0)))
'

hdr "STABILITY — restarts / OOM kills (0 = healthy; a REPLACED pod also shows 0, the census above is what catches that)"
dql "timeseries cpu = avg(dt.kubernetes.container.cpu_usage), by:{k8s.workload.name, k8s.pod.name}, $TF, filter: k8s.cluster.name == \"$CLUSTER\" and startsWith(k8s.workload.name, \"bench-\")
| fields engine = k8s.workload.name, pod = k8s.pod.name
| lookup [ timeseries { r = sum(dt.kubernetes.container.restarts), o = sum(dt.kubernetes.container.oom_kills) }, by:{k8s.pod.name}, $TF, filter: k8s.cluster.name == \"$CLUSTER\"
           | fieldsAdd restarts = arrayMax(r), oom_kills = arrayMax(o)
           | fields k8s.pod.name, restarts, oom_kills ],
         sourceField: pod, lookupField: k8s.pod.name
| fieldsAdd restarts = coalesce(lookup.restarts, 0), oom_kills = coalesce(lookup.oom_kills, 0)
| fields pod, restarts, oom_kills" \
 | python3 -c 'import json,sys
for r in json.load(sys.stdin): print("  %s  restarts=%s  oom_kills=%s" % (r.get("pod"), r.get("restarts"), r.get("oom_kills")))'

# ---------------------------------------------------------------------------
# 3. SPANS — total, engine-tagged coverage, and the ingest-path split
# ---------------------------------------------------------------------------
# TWO ratios, because "coverage" was ambiguous and the ambiguity was hiding a
# tautology (2026-07-23):
#
#   arm coverage    = tagged / spans-from-THIS-cluster.  This is the quality
#                     figure — "did the engine tag everything it handled?"
#                     Measured on R1P1: 18,499,537/18,499,537 = 100.00%, and
#                     `countIf(cluster == X and isNull(benchmark.engine))` is
#                     literally 0. Inside a cluster filter it CANNOT come out
#                     below 100%, because k8s.cluster.name is itself stamped by
#                     the engine. Printing only this reads as a perfect score
#                     that no failure could ever dent.
#
#   tenant share    = tagged / ALL spans on the tenant, unfiltered. This is what
#                     the banked R1P1 figure "99.04%" actually was:
#                     18,499,537 / 18,678,323. The 178,786-span remainder is
#                     OTHER CLUSTERS on this tenant (another cluster,
#                     a third cluster), not anything the engine dropped.
#
# ⚠️ DO NOT COMPARE tenant share ACROSS ARMS. It moves when unrelated clusters
# get busier, so a P1-vs-P2 difference in it says nothing about the engines. Arm
# coverage is the comparable one. Both are printed, labelled, so the 99.04% on
# the R1P1 row can still be reconciled against this script.
hdr "SPANS — benchmark-tagged total, arm coverage, and tenant share"
spans=$(dql "fetch spans, $TF_FETCH
| summarize tenant_all   = count(),
            tagged       = countIf(isNotNull(benchmark.engine)),
            cluster_all  = countIf(k8s.cluster.name == \"$CLUSTER\"),
            cluster_untagged = countIf(k8s.cluster.name == \"$CLUSTER\" and isNull(benchmark.engine))")
SP="$spans" python3 -c '
import json, os
for r in json.loads(os.environ["SP"] or "[]"):
    tagged  = int(float(r.get("tagged") or 0))
    tenant  = int(float(r.get("tenant_all") or 0))
    cluster = int(float(r.get("cluster_all") or 0))
    untag   = int(float(r.get("cluster_untagged") or 0))
    print("  benchmark-tagged spans        %14s" % format(tagged, ","))
    print("  arm coverage  (vs cluster)    %13.2f%%   %s of %s  — untagged in-cluster: %s" % (
        (100.0*tagged/cluster if cluster else 0), format(tagged, ","), format(cluster, ","), format(untag, ",")))
    print("  tenant share  (vs all spans)  %13.2f%%   %s of %s  — remainder is OTHER clusters, do NOT compare across arms" % (
        (100.0*tagged/tenant if tenant else 0), format(tagged, ","), format(tenant, ",")))
'

# ---------------------------------------------------------------------------
# LOGS — added 2026-07-23 . READ THE FILTER NOTE.
# ---------------------------------------------------------------------------
# This section exists because the dashboard's two log tiles filter logs by
#   k8s.cluster.name == "the benchmark cluster" and isNotNull(benchmark.engine)
# and that returns ZERO for the Fluent Bit arm.
#
# Measured: 1,813,982 log records tagged benchmark.engine=fluentbit-v5, and
# k8s.cluster.name NULL on every single one -- while the collector arm's logs
# carry it normally (1,213,807 in a 15-min P1 slice). Fluent Bit's logs
# content_modifier reports ZERO errors; the k8s.cluster.name upsert simply does
# not land. Spans are unaffected -- the same upsert works there.
#
# So the dashboard as written would report "collector 1.2M logs, Fluent Bit 0
# logs" and it would look entirely believable. Fluent Bit is in fact delivering
# MORE logs than the collector. That is a wrong number of the worst kind: large,
# directional, and plausible.
#
# Read-time fix, in the spirit of benchmark/service-key.dql -- the telemetry config
# is frozen for the campaign, so this is corrected where it is READ, not where it
# is produced. benchmark.engine is campaign-unique (nothing outside this
# benchmark sets it, verified: the only non-null values on the tenant are the
# three engine names), so it discriminates safely on its own.
#
# ⚠️ The DASHBOARD still needs the same fix before anyone reads the logs tiles.
hdr "LOGS — filtered on benchmark.engine ONLY (see the note: cluster filter zeroes this arm)"
logs=$(dql "fetch logs, $TF_FETCH
| filter isNotNull(benchmark.engine)
| summarize records = count(), by:{ engine = benchmark.engine }
| sort records desc")
LG="$logs" python3 -c '
import json, os
rows = json.loads(os.environ["LG"] or "[]")
if not rows:
    print("  no engine-tagged logs in this window")
for r in rows:
    print("  %-20s %14s records" % (r.get("engine"), format(int(float(r.get("records") or 0)), ",")))
'
xcheck=$(dql "fetch logs, $TF_FETCH
| filter k8s.cluster.name == \"$CLUSTER\" and isNotNull(benchmark.engine)
| summarize records = count()")
XC="$xcheck" python3 -c '
import json, os
rows = json.loads(os.environ["XC"] or "[]")
n = int(float(rows[0].get("records") or 0)) if rows else 0
print("  cross-check, WITH the dashboard cluster filter: %s records" % format(n, ","))
if n == 0:
    print("    ^ this is the defect. The dashboard tiles would show ZERO logs for")
    print("      this arm. Do not read the logs tiles until they are corrected.")
'

hdr "SPANS — ingest path split (derived from telemetry.sdk.name + Istio naming, NOT from benchmark.telemetry_source)"
dql "$(sed '/^fetch spans/,$!d' "$HERE/service-key.dql" \
       | sed "1s|^fetch spans|fetch spans, $TF_FETCH|")
| summarize spans = sum(spans), by:{ engine, ingest }
| sort spans desc" \
 | python3 -c 'import json,sys
rows=json.load(sys.stdin)
tot=sum(float(r.get("spans") or 0) for r in rows)
for r in rows:
    v=float(r.get("spans") or 0)
    print("  %-18s %-12s %14s  (%.2f%%)" % (r.get("engine"), r.get("ingest"), format(int(v),","), 100.0*v/tot if tot else 0))
print("  %-31s %14s" % ("TOTAL", format(int(tot),",")))'

# ---------------------------------------------------------------------------
# selftest assertions — R1P1's hand-produced headline figures
# ---------------------------------------------------------------------------
if [[ $EXPECT_P1 -eq 1 ]]; then
  hdr "SELFTEST — does this script reproduce R1-P1-collector's reported figures?"
  echo "  Reported by hand by hand, and what this script must print:"
  echo "    census        122/122 buckets, 1 pod"
  echo "    CPU avg       190.7 mc"
  echo "    MEM avg       108 MiB          (script prints 108.2)"
  echo "    spans         18,499,537"
  echo "    \"99.04%\"      = TENANT SHARE, 18,499,537 / 18,678,323 — NOT arm coverage."
  echo "                    Arm coverage is 100.00%; in-cluster untagged spans = 0."
  echo "                    The hand-produced row did not distinguish the two."
  echo "  Any OTHER divergence means the banked P1 row and this script disagree —"
  echo "  reconcile BEFORE publishing P2."
fi
