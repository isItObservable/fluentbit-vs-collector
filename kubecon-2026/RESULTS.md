# Results — KubeCon 2026 four-arm pipeline benchmark

Four telemetry-pipeline engines, each run **serial and single-engine** (only one in the cluster at
a time) against the **same** otel-demo + hipster-shop topology, the same 12h soak profile, and the
same newest-stable version pins. Every arm passed the pre-test validation gate before its run was
trusted.

**Cluster:** Kubernetes v1.35.3, 1 control-plane + 3× 16 GiB workers, Istio ambient, Cilium CNI.
**Load:** locust → otel-demo, k6 → hipster-shop; 50→100→150→200 VU/app rampup, then 12h soak at a
steady 50 VU/app. **Signals:** full logs + metrics + traces every arm.

## Headline matrix — stability, loss, leak

| Arm | Engine (under test) | Transport | Spans delivered (12h) | Logs delivered (12h) | Drop rate | Restarts / SIGSEGV | Memory (soak) | Leak |
|-----|---------------------|-----------|----------------------:|---------------------:|-----------|--------------------|---------------|------|
| **A** | Fluent Bit **5.1.5** | OTLP/HTTP **+ gzip** | — ¹ | — ¹ | **0.0047 %** | **0 / 0** | **38 MiB** (3.7 % of 1 GiB) | ✅ flat |
| **B** | OTel Collector contrib **0.163.1** | OTLP/HTTP **+ zstd** | **144.0 M** | **92.6 M** | refused=0, send_failed=0 (**0 %**) | **0 / 0** | flat (queue=0) ² | ✅ flat |
| **C** | df_engine (Rust otap-dataflow) **0.61.0** — OTLP in/out | OTLP | **137.8 M** | **67.5 M** | **0.0022 %** spans / **0.0097 %** logs | **0 / 0** | flat ² (throughput CV 0.8 %) | ✅ flat |
| **D** | df_engine **0.61.0** — OTAP in → OTLP out | OTAP edge (Arrow + zstd) → df_engine → backend direct | **91.6 M** | **64.9 M** | **0.00 %** | **0 / 0** ³ | **28.2 MiB** avg (heap, flat) | ✅ flat |

¹ Arm A throughput was captured from Fluent Bit's own gateway counters (it does not split
spans/logs): **48.87 M records** over the 12h soak, with backend receipt confirmed continuous at
sampled intervals.
² Absolute soak-average memory for arms B and C was not captured in this run's readout; their
stability (0 restarts, 0 queue growth) and loss are fully measured.
³ One log-collector pod restarted once at soak start; the **engine-under-test** logged 0 restarts
across the full 12h.

## Normalized throughput (records delivered per minute, 12h soak)

| Arm | Records delivered (12h) | records / min | records / sec |
|-----|------------------------:|--------------:|--------------:|
| B | 236.6 M | 328,600 | 5,477 |
| C | 205.3 M | 285,140 | 4,752 |
| D | 156.5 M | 217,310 | 3,622 |

> Read as **"sustained delivery with zero backpressure," not a horse-race** — the arms share a
> load *methodology* (50 VU/app steady) but were not pinned to a common fixed record target, so
> absolute volume differs per independent serial run. The directly comparable verdicts are
> **loss, stability, and leak** — all four arms pass.

## Wire efficiency & cost economics (gzip + parity re-run)

This is the axis the re-run was built to settle fairly. Two measures, both normalized per span
over the rampup window (so every arm is measured against the same denominator):

- **Wire B/span** — bytes actually put on the wire per delivered span. Method:
  `sum(dt.kubernetes.pod.network_transmitted_data)` over the rampup window (per-minute buckets,
  summed) ÷ delivered span count, excluding the substrate cluster. This is the honest transport
  number *with each engine's compression enabled*.
- **mc/1M-spans** — engine CPU millicore-seconds spent per 1 M spans delivered (rampup-average
  engine CPU ÷ delivered spans × 1 M). The cost of doing the work.

### Wire bytes per span — every arm compressing

| Engine / transport | Wire B/span |
|--------------------|------------:|
| OTAP edge (Arrow + zstd) | **1.27** |
| OTel Collector (OTLP + zstd) | **2.04** |
| **Fluent Bit 5.1.5 (OTLP/HTTP + gzip)** | **2.27** |
| *— contrast: Fluent Bit uncompressed (prior run)* | *28.46* |

Fluent Bit **with gzip** lands at **2.27 B/span — within ~11 % of the Collector's 2.04** and the
same order as OTAP's 1.27. The 28.46 → 2.27 drop (**~12.5× smaller on the wire**) was **entirely
a compression-configuration artifact**, not FB engine overhead. Quote the 10–20×+ "fatter wire"
figure **only** against *uncompressed* OTLP and label it as such.

### CPU cost per 1 M spans

| Engine | mc / 1M-spans |
|--------|--------------:|
| OTAP terminus (df_engine, OTAP in) | **0.75** |
| OTel Collector contrib 0.163.1 | **7.64** |
| df_engine native (OTLP in/out) | **7.97** |
| OTAP edge (Arrow encoder) | **9.77** |
| **Fluent Bit 5.1.5 (+ gzip)** | **9.59** |

### Key findings

- **(a) Parity fix.** In the first pass Arms A and B were **under-meshed** vs the df_engine arms
  (C/D) — fewer Istio mesh spans per app span, which skewed every per-span figure. The re-run
  re-wired the apps and mesh to the **same ambient + waypoint + 100 %-tracing parity** as C/D (see
  [`DEPLOYMENT.md`](./DEPLOYMENT.md)) and gated on a 72–77 % mesh ratio before soaking, so the
  numbers above are like-for-like.
- **(b) gzip trades CPU for wire.** Turning gzip on cut Fluent Bit's wire from **28.5 → 2.27
  B/span** but raised its CPU cost from ~6.8 to **9.59 mc/1M-spans** — making it, on this run, the
  **most CPU-expensive** full engine. Compression is not free; it moves cost from the network to
  the CPU.
- **(c) With everyone compressing, the wire gap collapses.** Once all engines compress, the spread
  is only **~1.8×** (Arrow 1.27 < Collector 2.04 ≈ FB+gzip 2.27) — **not** the 22×+ you see when
  Fluent Bit ships uncompressed. The dramatic "Arrow is 20× leaner than Fluent Bit" story is a
  story about *compression*, not about *Arrow*.
- **(d) OTAP terminus is near-free; the pack cost lives on the edge.** The df_engine OTAP
  *terminus* (decode Arrow → OTLP out) costs just **0.75 mc/1M** — the Arrow columnar pack/encode
  cost is paid on the **edge** encoder (**9.77 mc/1M**), not at the receiving end. Splitting the
  OTAP arm into edge + terminus shows where the work actually is.

### Live dashboards (isItObservable Dynatrace)

These numbers mirror the two live dashboards used to drive the talk — **D1** (benchmark soak /
economics, `4bc20329`) and **D2** (wire & cost comparison, `6928d1c8`). Import the parameterized
dashboard JSON from [`../dashboards/`](../dashboards/) into your own tenant to reproduce the views
(cluster name is a `$K8sCluster` variable; no tenant-specific IDs are embedded).

## Verdict

**All four arms PASS the 12h soak.** Zero engine crashes, zero SIGSEGV, loss under 0.01 % on every
arm (0.00 % on Arm D), and flat memory with no leak trend.

### The two failure modes from the prior benchmark are gone

- **Fluent Bit mesh crash:** older v5.0.9 reproducibly SIGSEGV'd over Istio ztunnel HTTP/2 on
  multi-hour runs. **v5.1.5 ran a full 12h soak over the mesh with 0 crashes.** The crash does not
  reproduce.
- **OTel-Arrow dictionary overflow:** the older Go Arrow engine died on soak. The Rust df_engine
  0.61.0 ran **two** 12h soaks (OTLP and OTAP) with **0 restarts and no dictionary overflow**.

## The validation gate caught a real "strange thing"

On the reference collector arm, otel-demo came up healthy — pods Running, frontend serving — but
**zero spans reached the collector**. The gate's receive-check flagged `accepted == 0` in seconds,
before a 12h soak was wasted on a dead pipeline. Root cause: the otel-demo Deployments were missing
`OTEL_EXPORTER_OTLP_ENDPOINT`, so the apps instrumented fine but shipped their telemetry nowhere.
The pods looked perfect; the numbers were zero. **A healthy-looking demo app is the most dangerous
input to a benchmark** — run `validate-app.sh` and `validate-gate.sh` before you trust any run.

## Version pins (frozen at setup)

| Component | Pinned |
|-----------|--------|
| Fluent Bit | 5.1.5 |
| OTel Collector contrib | 0.163.1 (Arm B engine; Arm D edge + bridge) |
| df_engine (Rust otap-dataflow) | 0.61.0 (Arms C + D engine) |
| Dynatrace Operator | 1.11.0 |
| Kubernetes | 1.35.3 · Istio 1.29.2 (ambient) · Cilium 1.17.4 |
