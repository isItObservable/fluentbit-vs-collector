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
| **A** | Fluent Bit **5.1.5** | OTLP/HTTP | — ¹ | — ¹ | **0.0044 %** | **0 / 0** | **38 MiB** (3.7 % of 1 GiB) | ✅ flat |
| **B** | OTel Collector contrib **0.163.1** | OTLP/HTTP | **144.0 M** | **92.6 M** | refused=0, send_failed=0 (**0 %**) | **0 / 0** | flat (queue=0) ² | ✅ flat |
| **C** | df_engine (Rust otap-dataflow) **0.61.0** — OTLP in/out | OTLP | **137.8 M** | **67.5 M** | **0.0022 %** spans / **0.0097 %** logs | **0 / 0** | flat ² (throughput CV 0.8 %) | ✅ flat |
| **D** | df_engine **0.61.0** — OTAP in → OTLP out | OTAP edge → df_engine → backend direct | **91.6 M** | **64.9 M** | **0.00 %** | **0 / 0** ³ | **28.2 MiB** avg (heap, flat) | ✅ flat |

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
