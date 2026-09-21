# Architecture — how the benchmark is built

This benchmark compares two node-level telemetry agents — the **OpenTelemetry
Collector-contrib** and **Fluent Bit v5** — shipping the *same* signals from the *same*
Kubernetes cluster to the *same* backend, so the only variable is the engine.

## Signal sources (identical for both engines)

| Signal | Source | How it's collected |
|--------|--------|--------------------|
| **Logs** | every pod on the node (`/var/log/pods/**`) | Collector `filelog` receiver / Fluent Bit `tail` input, both as a **DaemonSet** |
| **Metrics** | Istio control plane (`istiod :15014`) + **Kepler** power exporter (`:9102`, high-cardinality) | Collector `prometheus` receiver / Fluent Bit `prometheus_scrape` input, on a **StatefulSet** |
| **Traces** | the **OpenTelemetry Demo** + **Online Boutique (hipster-shop)** apps under load | OTLP to a **Deployment** — collector accepts gRPC `:4317` + HTTP `:4318`; Fluent Bit accepts OTLP/HTTP `:4318` only |

## Per-engine topology

Each engine runs the same three-workload split so the per-component cost lines stay
comparable:

```
DaemonSet   (logs)     — one pod per node, tails node logs
StatefulSet (metrics)  — scrapes istiod + Kepler, converts, exports
Deployment  (traces)   — OTLP receiver -> [tail sampling, Tier 4 — both engines] -> export
```

Manifests to deploy this are in [`../manifests/`](../manifests/); the per-tier pipeline
configs are in [`../tiers/`](../tiers/).

## The tier ladder (each tier adds one signal)

| Tier | Signals | New this tier | Notes |
|------|---------|---------------|-------|
| **1** | logs | node log tail | baseline footprint |
| **2** | + metrics | istiod + Kepler high-cardinality scrape | widest engine gap (metrics pipeline) |
| **3** | + traces | OTLP trace path @200 span/s | full three-signal footprint |
| **4** | + tail sampling | collector `tail_sampling` processor **and** Fluent Bit `sampling` (`type: tail`) processor | like-for-like tail-sampling comparison (both engines) — *re-run in progress* |

Because each tier only *adds* to the tier below it, the row-to-row delta is the **incremental
cost of the added signal**. Both engines support in-pipeline tail sampling (collector
`tail_sampling`; Fluent Bit v5 `sampling` `type: tail`), so Tier 4 is a like-for-like
tail-sampling comparison, not a capability premium.

## How a run is executed

Serial single-engine, one engine live at a time: deploy engine → **census gate** (all pods
Running, 0 restarts) → **2-hour ramp-up validity gate** (telemetry received at the backend +
load reaching the apps) → **24-hour soak** → read KPIs → tear down → repeat for the other
engine. Full step-by-step in [`RERUN-GUIDE.md`](./RERUN-GUIDE.md); results in
[`RESULTS.md`](./RESULTS.md).

## KPIs measured

Throughput (records or spans/sec), CPU (working-set millicores), memory (tail-flat leak
check — mid-third vs tail-third drift), loss (accepted == sent), and cost-per-1M records.
Readout tooling is in [`../kpi/`](../kpi/).
