#!/usr/bin/env python3
"""ISI-1821 / board directive D12 — rework dashboard 764f7082 to be pod-level.

Why (validated live on observable-otelarrow, ISI-1811 + re-proven 2026-07-22):
  A pod REPLACEMENT is invisible to dt.kubernetes.container.restarts — that metric
  counts in-place container restarts only. Over the 48h window 2026-07-20T11:00Z ->
  2026-07-22T11:00Z, workloads otel-agent-collector and otel-agent-otlp-collector each
  showed SIX pod names (a rollout) while a restarts timeseries over the same window
  returned ZERO datapoints. A newborn pod also reports ~2 MiB, so any workload-level
  min()/avg() blends it in.

Therefore every resource tile groups by k8s.pod.name (a replacement becomes its own
row instead of being averaged away), every tile is scoped by k8s.cluster.name
(workload names are NOT unique across the clusters on this tenant), and a pod-census
validity gate sits directly under the header — it decides whether the window's numbers
may be reported at all.

Input : live dashboard, downloaded first (never rebuild from the local copy blind).
Output: <stem>.deploy.json (with id, for dtctl apply) and the stripped source export.
"""
import json
import re
import sys

DASH_ID = "764f7082-0039-4f3f-ad39-47b5abc5bb73"
CLUSTER = "observable-otelarrow"
ENGINE_SEL = f'k8s.cluster.name == "{CLUSTER}" and startsWith(k8s.workload.name, "bench-")'

live = json.load(open(sys.argv[1]))
assert live["id"] == DASH_ID, live["id"]
c = live["content"]
tiles, layouts = c["tiles"], c["layouts"]

# --- 1. header -------------------------------------------------------------
tiles["0"]["markdown"] = f"""# Fluent Bit v5 vs OTel Collector vs OTel-Arrow — benchmark comparison

**This dashboard is the measurement surface for ISI-1779 (plan rev 7 §5). There are no snapshots — set the timeframe and read the run.**

### How to read a run
1. Open `results/RUN-REGISTER.md` on branch `fluentbit-v5-vs-otel-arrow` and pick a row (`R1-P1-collector` … `R2-P3-arrow`).
2. Paste that row's **Start (UTC)** and **End (UTC)** into the dashboard timeframe picker, verbatim.
3. **Read the POD CENSUS first.** It is a validity gate, not a detail tile — if any pod in the window is short-lived, or the pod count does not match the register's *expected replicas*, **the window's numbers are not reportable** and the run must be repeated. Everything below the census assumes the census is green.
4. Every tile is timeframe-driven and grouped by `k8s.pod.name` / `benchmark.engine`, so the window alone selects the engine and the round. **No tile carries its own `from:` clause** — if you see numbers without setting a timeframe, you are reading the default window, not a run.
5. Compare `R1-P<n>-<engine>` with `R2-P<n>-<engine>` for replication; compare engines *within one round* for the headline.

### Why pod-level, not workload-level (board directive D12)
A pod **replacement** — reschedule, eviction, node drain, rollout — produces a new pod name and is **invisible** to `dt.kubernetes.container.restarts`, which counts in-place container restarts only. A newborn pod reports ~2 MiB, so a workload-level `avg()`/`min()` silently blends it into the aggregate. Grouping by `k8s.pod.name` makes a replacement appear as its own row instead of disappearing into the average. Verified live on `{CLUSTER}`: over 2026-07-20T11:00Z→2026-07-22T11:00Z two workloads each showed **six** pod names while the restarts metric returned **zero** rows.

### What is on the grid
Engine workloads are the three `bench-*` deployments on cluster `{CLUSTER}`: `bench-otel-collector-collector`, `bench-fluentbit-v5`, `bench-otel-arrow-native`. Only one is deployed at a time (plan §1) — **a correctly-scoped window contains exactly one engine workload. If you see two, the window is wrong**, most likely an End timestamp captured after the next phase started.

CPU is in **millicores**, memory in **MiB**."""

# --- 2. NEW tile 11: pod census — the validity gate -------------------------
# coverage_pct, not a strict live==window equality: the first and last bucket of any
# window are partially covered by the metric's own cadence, so a healthy pod reads
# ~96.7% on a 2h/1min window, never 100%. A mid-window replacement in a 120-min run
# reads far below 90%. Threshold validated against both cases live.
tiles["11"] = {
    "type": "data",
    "title": "POD CENSUS — VALIDITY GATE. Read this before any other tile.",
    "query": f"""timeseries mem = avg(dt.kubernetes.container.memory_working_set), by:{{k8s.workload.name, k8s.pod.name}}, filter: {ENGINE_SEL}
| fieldsAdd live_buckets = arraySize(arrayRemoveNulls(mem)), window_buckets = arraySize(mem)
| fieldsAdd coverage_pct = 100.0 * arraySize(arrayRemoveNulls(mem)) / arraySize(mem)
| fieldsAdd verdict = if(100.0 * arraySize(arrayRemoveNulls(mem)) / arraySize(mem) >= 90, "ok - pod alive for the whole window", else:"PARTIAL LIFETIME -> WINDOW INVALID, do not report numbers")
| fields engine = k8s.workload.name, pod = k8s.pod.name, live_buckets, window_buckets, coverage_pct, verdict
| sort coverage_pct asc, pod asc""",
    "visualization": "table",
    "visualizationSettings": {
        "chartSettings": {},
        "singleValue": {},
        "table": {},
        "thresholds": [],
    },
}
layouts["11"] = {"x": 0, "y": 9, "w": 16, "h": 8}

# --- 3. NEW tile 12: pod count vs expected replicas -------------------------
tiles["12"] = {
    "type": "data",
    "title": "Pods seen per engine — must equal 'Expected replicas' in RUN-REGISTER.md",
    "query": f"""timeseries mem = avg(dt.kubernetes.container.memory_working_set), by:{{k8s.workload.name, k8s.pod.name}}, filter: {ENGINE_SEL}
| summarize pods_in_window = countDistinctExact(k8s.pod.name), by:{{engine = k8s.workload.name}}
| sort engine asc""",
    "visualization": "table",
    "visualizationSettings": {
        "chartSettings": {},
        "singleValue": {},
        "table": {},
        "thresholds": [],
    },
}
layouts["12"] = {"x": 16, "y": 9, "w": 8, "h": 8}

# --- 4. resource tiles: workload-level -> pod-level -------------------------
tiles["1"]["title"] = "CPU per engine POD (millicores) — timeframe = the run window"
tiles["1"]["query"] = (
    f"timeseries cpu = avg(dt.kubernetes.container.cpu_usage), by:{{k8s.workload.name, k8s.pod.name}}, filter: {ENGINE_SEL}"
)

tiles["2"]["title"] = "Memory working set per engine POD (MiB) — slope across the run is the leak signal"
tiles["2"]["query"] = f"""timeseries mem = avg(dt.kubernetes.container.memory_working_set), by:{{k8s.workload.name, k8s.pod.name}}, filter: {ENGINE_SEL}
| fieldsAdd mem_mib = mem[] / 1048576
| fields k8s.workload.name, k8s.pod.name, timeframe, interval, mem_mib"""

tiles["3"]["title"] = "Resource summary PER POD — CPU avg/p95/max (mc), memory avg/peak (MiB) over the window"
tiles["3"]["query"] = f"""timeseries {{ cpu = avg(dt.kubernetes.container.cpu_usage), mem = avg(dt.kubernetes.container.memory_working_set) }}, by:{{k8s.workload.name, k8s.pod.name}}, filter: {ENGINE_SEL}
| fieldsAdd cpu_avg_mc = arrayAvg(cpu), cpu_p95_mc = arrayPercentile(cpu, 95), cpu_max_mc = arrayMax(cpu),
            mem_avg_mib = arrayAvg(mem) / 1048576, mem_peak_mib = arrayMax(mem) / 1048576
| fields engine = k8s.workload.name, pod = k8s.pod.name, cpu_avg_mc, cpu_p95_mc, cpu_max_mc, mem_avg_mib, mem_peak_mib
| sort cpu_avg_mc desc"""

tiles["4"]["title"] = "Stability PER POD — restarts & OOM kills (0 = healthy; a REPLACED pod shows 0 here, the census catches it)"
tiles["4"]["query"] = f"""timeseries cpu = avg(dt.kubernetes.container.cpu_usage), by:{{k8s.workload.name, k8s.pod.name}}, filter: {ENGINE_SEL}
| fields engine = k8s.workload.name, pod = k8s.pod.name
| lookup [ timeseries {{ r = sum(dt.kubernetes.container.restarts), o = sum(dt.kubernetes.container.oom_kills) }}, by:{{k8s.pod.name}}, filter: k8s.cluster.name == "{CLUSTER}"
           | fieldsAdd restarts = arrayMax(r), oom_kills = arrayMax(o)
           | fields k8s.pod.name, restarts, oom_kills ],
         sourceField: pod, lookupField: k8s.pod.name
| fieldsAdd restarts = coalesce(lookup.restarts, 0), oom_kills = coalesce(lookup.oom_kills, 0)
| fields engine, pod, restarts, oom_kills
| sort pod asc"""

# --- 5. tile 6 was the only tile not scoped by cluster ----------------------
tiles["6"]["query"] = f"""timeseries v = avg(system.cpu.utilization), by:{{ benchmark.engine, service.name, k8s.cluster.name }}, filter: isNotNull(benchmark.engine) and k8s.cluster.name == "{CLUSTER}"
| summarize metric_series = count(), by:{{ engine = benchmark.engine }}
| sort metric_series desc"""

# --- 6. caveats ------------------------------------------------------------
tiles["10"]["markdown"] = f"""### Caveats that change how these numbers are read

- **A pod REPLACEMENT is invisible to `dt.kubernetes.container.restarts`** (board directive D12, from ISI-1811). That metric counts in-place container restarts only; a reschedule, eviction, node drain or rollout produces a new pod name and leaves the metric empty. Re-proven live on this cluster: 48h window `2026-07-20T11:00Z→2026-07-22T11:00Z`, six pod names across two workloads, **zero** restart datapoints. This is why the **pod census** — not the stability tile — is the validity gate.
- **Restarts / OOM kills** use `arrayMax`, not `arraySum`, and are looked up **per pod**. The Dynatrace k8s counters report the container's restart count and are only emitted when non-zero; summing across intervals double-counts one restart once per sample. The tile is driven off the CPU metric and looks the counters up, so a healthy pod shows an explicit **0** rather than a blank tile you cannot distinguish from a broken query.
- **Census threshold is 90% coverage, not 100%.** The first and last bucket of any window are partially covered by the metric's own cadence, so a perfectly healthy pod reads ~96.7% on a 2h/1-minute window and never exactly 100%. A pod replaced mid-run in a 120-minute window reads far below 90% (measured: 27–56% on real rollouts). Do not "tighten" this to strict equality — you would fail every valid run.
- **Ingest volume by signal covers spans and logs.** Those are record-countable in Grail. OTLP **metric datapoints** are not — a metric arrives as a series, not a countable record — so the metrics signal is represented by the *series-arriving-per-engine* tile (liveness and breadth), and datapoint throughput is taken from the engine's own exported-datapoint counter at gate time (`validate-phase.sh` check 5). Do not read the metric-series count as a volume comparison.
- **`app-sdk` vs `istio-mesh`** is split on `benchmark.telemetry_source`, which only the Istio `Telemetry` CR sets. `benchmark.engine` cannot make this split — the engines stamp it on every record they process, app and mesh alike.
- **Scope exclusion D1 (board, 2026-07-22):** Istio/Envoy Prometheus metrics are excluded from every run — no Prometheus receiver, no ServiceMonitor, no Envoy scrape, on any engine, in any phase. App-emitted OTLP metrics **are** in scope and are measured. Istio-generated spans and access logs are in scope.
- **Workload names collide across clusters** on this tenant (`observable-kagent`, `observable-agentsandbox`, `observable-otelarrow` all report `dt.kubernetes.container.*`). **Every** tile — including the app-OTLP metric-series tile — is therefore scoped by `k8s.cluster.name == "{CLUSTER}"`. Do not remove that filter.
- Every ratio quoted from this dashboard must state its baseline: **vs OTLP+zstd** is the honest comparison; vs uncompressed is a different, much larger number and must be labelled."""

# --- 7. reflow: census block inserted at y9, everything below shifts down ---
NEW_LAYOUT = {
    "0":  {"x": 0,  "y": 0,  "w": 24, "h": 9},   # header
    "11": {"x": 0,  "y": 9,  "w": 16, "h": 8},   # pod census (gate)
    "12": {"x": 16, "y": 9,  "w": 8,  "h": 8},   # pods seen vs expected
    "1":  {"x": 0,  "y": 17, "w": 12, "h": 7},   # cpu per pod
    "2":  {"x": 12, "y": 17, "w": 12, "h": 7},   # mem per pod
    "3":  {"x": 0,  "y": 24, "w": 24, "h": 7},   # resource summary per pod
    "4":  {"x": 0,  "y": 31, "w": 8,  "h": 6},   # stability per pod
    "5":  {"x": 8,  "y": 31, "w": 8,  "h": 6},   # ingest volume
    "6":  {"x": 16, "y": 31, "w": 8,  "h": 6},   # metric series
    "7":  {"x": 0,  "y": 38, "w": 12, "h": 7},   # ingest rate
    "8":  {"x": 12, "y": 38, "w": 12, "h": 7},   # sdk vs mesh
    "9":  {"x": 0,  "y": 45, "w": 12, "h": 6},   # spans by app
    "10": {"x": 12, "y": 45, "w": 12, "h": 9},   # caveats
}
c["layouts"] = NEW_LAYOUT

# --- 8. assertions ---------------------------------------------------------
assert set(c["tiles"]) == set(c["layouts"]), (set(c["tiles"]) ^ set(c["layouts"]))
assert c["variables"] == [], c["variables"]
for tid, t in c["tiles"].items():
    q = t.get("query")
    if q is None:
        continue
    assert not re.search(r"\bfrom:", q), f"tile {tid} carries its own timeframe"
    assert f'k8s.cluster.name == "{CLUSTER}"' in q, f"tile {tid} not scoped by cluster"
# every resource tile must be pod-grouped
for tid in ("1", "2", "3", "4", "11", "12"):
    assert "k8s.pod.name" in c["tiles"][tid]["query"], f"tile {tid} not pod-grouped"
# grid width
for tid, l in c["layouts"].items():
    assert l["x"] + l["w"] <= 24, f"tile {tid} overflows the 24-column grid"

stem = "isi1779-benchmark-comparison"
json.dump(live, open(f"{stem}.deploy.json", "w"), indent=2, ensure_ascii=False)
export = {k: v for k, v in live.items() if k not in ("id", "owner", "version", "modificationInfo", "isPrivate")}
json.dump(export, open(f"{stem}.dashboard.json", "w"), indent=2, ensure_ascii=False)
print(f"OK  tiles={len(c['tiles'])} layouts={len(c['layouts'])} "
      f"stripped={sorted(set(live) - set(export))}")
