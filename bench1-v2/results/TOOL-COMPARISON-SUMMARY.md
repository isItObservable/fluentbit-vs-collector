# Tool-comparison feed — per-test summary (rampup + soak) for the episode

**Purpose:** the per-test numbers that feed the actual tool comparison (Fluent Bit v5 vs OTel
Collector vs OTel-Arrow). One row/card per executed test, newest verdicts first within each
block. Pending soaks are marked and will be filled as they land (S3 ends 2026-08-27 ~16:42Z,
then S4, then S2m).

Cluster: `observable-otelarrow` · apps: otel-demo + hipster-shop behind Istio · gate 8/8 before
every run · census discipline on every window · full provenance in `RUN-REGISTER.md` +
`FINAL-REPORT.md`.

---

## A. Rampup tests (120 min, 50→200 VU both apps)

### A.1 CLEAN canonical re-runs — **quote these numbers**

| Run | Engine | Window (UTC, 2026) | CPU avg | Memory avg | Spans | mCores/1M spans | Loss |
|---|---|---|---:|---:|---:|---:|---:|
| CLEAN-P1 (ISI-1927) | OTel Collector 0.154.0 | 07-28 09:09→11:10 | 150.25 mc | 95.57 MiB | 14.45 M | **10.40** | 0 |
| CLEAN-P2 (ISI-1928) | Fluent Bit 5.0.9 | 07-28 13:02→15:03 | 79.79 mc | 123.71 MiB | 13.58 M | **5.87** | 0 |
| CLEAN-P3 (ISI-1937) | OTel-Arrow df_engine 0.51.0 | 07-28 18:32→20:33 | 162.63 mc | 157.89 MiB | 14.43 M | **11.27** | 0 |

Signal-fidelity notes that MUST travel with these numbers:
- **Collector**: spans+logs+metrics all delivered (SAFE ×3). The only engine with full fidelity.
- **Fluent Bit**: 🛑 **zero app-OTLP metrics** (metrics processor chain 100% failure — lost, not
  delayed); benchmark-tagged logs read 0 (read-time defect, logged separately: engine counters
  show 0 dropped records). Spans fully delivered.
- **Arrow**: metrics routed to `exporter:noop` **by design** (fairness decision Q2 — df_engine
  lacks cumulativetodelta) — declared NO-DATA, not a failure. Spans+logs delivered.

### A.2 Exploratory rounds R1/R2 (2026-07-22 → 07-25) — provenance, superseded by CLEAN

| Run | Engine | Date | Outcome |
|---|---|---|---|
| R1-P1 | collector | 07-22 | baseline 6.54 mc/1M; cumulativetodelta fix applied after |
| R1-P2 | fluentbit | 07-23 | 117.1 mc avg; 🛑 metrics-loss found (gate was signal-blind) |
| R2-P1 | collector | 07-23 | replicates R1P1 within ~2% (6.39 mc/1M) |
| R1-P3 / R2-P3 | arrow 0.51.0 | 07-25 | rebuilt engine survives both 120-min ramps (0.50.0 had crashed ~26 min) |

### A.3 OTAP hop arms (120 min, 2026-07-29) — does the OTel-Arrow Protocol hop pay off?

| Run | Topology | Combined CPU | Memory | Spans | mc/1M | Verdict |
|---|---|---:|---:|---:|---:|---|
| OTAP Config A (ISI-1949) | collector→**OTAP**→df_engine→DT | 190.69 mc | 501.67 MiB | 13.40 M | 14.23 | hop costs **+26%** vs native arrow |
| OTAP Config B (ISI-1950) | + 2nd OTAP hop via gateway collector | 190.2 mc | 579.6 MiB | 10.15 M | 18.74 | 2nd hop **does not help** (+32% vs A) |

**Verdict: OTAP does not improve otel-arrow efficiency in this topology — every hop adds cost.**

---

## B. Soak tests (24 h, 50 VU/app constant, leak oracle = memory floor)

| Run | Engine | Window (UTC, 2026) | Restarts | Leak verdict |
|---|---|---|---:|---|
| S1 (ISI-1811) | OTel Collector | 07-29 19:04 → 07-30 19:12 | 0 | 🟢 **NO LEAK** — warm-up ~8h then flat plateau ~88.6 MiB, final-16h creep ≤0.2%, census 24/24 |
| S2 (ISI-1823) | Fluent Bit 5.0.9 | 08-04 11:49 → 08-05 12:13 | **24** | 🔴 **SIGSEGV crash-loop** (exit 139, `flb_http_common.c:903`) — leak readout INVALID (each crash resets RSS) |
| S2-revalidate (ISI-2093) | Fluent Bit 5.0.9 | 08-06 01:34 → 08-07 01:52 | **13** | 🔴 crash **REPRODUCES** — byte-identical fingerprint, sustained across full 24h (gaps 26 min…6h22m, stochastic) |
| S3 attempt 3 (ISI-3301) | OTel-Arrow df_engine 0.51.0 | 08-26 16:42 → **running** | 0 @ T+20h | 🔄 pending — pod `…psb7t` never restarted, census clean, telemetry flowing (~48k spans/30m) |
| S4 (ISI-3302) | OTAP hop (Config A, 2 pods) | after S3 | — | ⏳ artifacts staged in-branch, gate support added |
| S2m (ISI-3303) | Fluent Bit `http2:off` (diagnostic) | after S4 | — | ⏳ purpose: prove HTTP/2 is the crash cause + first valid fluentbit leak number |

Invalid attempts kept for the record: S3 attempt 1 (07-25, VOID — node kubelet loss at T+8h, all
soak pods on one node); arrow ramps on df_engine 0.50.0 (07-23, cancelled — engine dictionary-
overflow crash, fixed upstream and rebuilt as 0.51.0).

---

## C. Crash isolation diagnostic (ISI-3264, 2026-08-26)

4 arms × 45 min, telemetrygen per-signal into fresh Fluent Bit 5.0.9:
metrics-only / traces-only / logs-only / connection-churn control → **0 crashes in every arm**.
The crash is **not signal-specific** and not load-magnitude; it requires live-mesh connection
lifecycle (idle connections crossing the 10 s downstream IO timeout) over hours. Authoritative
reproduction = the two live-mesh 24h soaks above.

---

## D. The comparison feed — numbers to quote on camera

| Dimension | Fluent Bit v5.0.9 | OTel Collector 0.154.0 | OTel-Arrow (df_engine 0.51.0) |
|---|---|---|---|
| CPU efficiency (ramp, normalised) | 🥇 **5.87 mc/1M spans** | 10.40 | 11.27 |
| Memory (ramp avg) | 123.71 MiB | 🥇 **95.57 MiB** | 157.89 MiB |
| Signal fidelity | spans ✅ · logs ⚠️ read-defect · metrics 🛑 **lost** | 🥇 spans+logs+metrics ✅ | spans+logs ✅ · metrics NO-DATA (by design) |
| 24h stability | 🔴 **crash-loop (24× + 13× SIGSEGV)** | 🥇 **no leak, no restarts** | 🔄 soak finishing |
| Crash root cause | HTTP/2 input server race (`flb_http_common.c:903`), live-mesh connection lifecycle, not payload | — | — |
| OTAP hop impact | — | — | **negative**: +26% CPU (1 hop), +32% (2 hops) — protocol hop does not pay off in this topology |

Storyline the data supports: *Fluent Bit wins raw ingest CPU-efficiency but fails the
production-stability bar and silently loses metrics; the OTel Collector is the stability and
fidelity benchmark; OTel-Arrow trades some efficiency for its columnar/protocol advantages —
which do NOT translate into lower CPU here, and its OTAP transport hop adds cost rather than
saving it.*
