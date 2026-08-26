# B1-v2 FINAL REPORT — Fluent Bit v5 vs OTel Collector vs OTel-Arrow (ISI-1779 / ISI-1773)

Episode benchmark, cluster `observable-otelarrow` (k8s v1.35.3, Istio 1.29.2, hipster-shop + otel-demo).
Protocol: one engine at a time, identical apps/Istio/load, 8-check validation gate before every run,
pod-census discipline (D12), no in-run snapshots (D8). All numbers normalised per 1M records.

**Report generated 2026-08-26. Three soak tests were finalizing when it was written — see §2 (pending).**

---

## 1. Headline results

### Efficiency (120-min CLEAN canonical ramps, 50→200 VU both apps)

| Engine | CPU avg | Spans delivered | mCores / 1M spans | Memory |
|---|--:|--:|--:|---|
| **Fluent Bit v5.0.9** | 79.8 mc | 13.58 M | **5.87** | ~124 MiB avg |
| **OTel Collector 0.154.0** | 150.3 mc | 14.45 M | **10.40** | ~95.6 MiB avg |
| **OTel-Arrow native (df_engine 0.51.0)** | 162.6 mc | 14.43 M | **11.27** | ~157.9 MiB avg |

Fluent Bit is the CPU-efficiency winner on ingest. Caveats that must be stated alongside:
fluentbit delivered **no app-OTLP metrics** in this campaign (metrics processor chain 100% failure —
data lost, not just unlabelled), and logs landed without `k8s.cluster.name` (read-time defect).

### Stability (24h leak soaks, 50 VU/app)

| Engine | 24h soak verdict |
|---|---|
| OTel Collector | 🟢 **NO LEAK** — flat plateau ~88.6 MiB after ~8h warm-up |
| OTel-Arrow native | 🔄 **run in progress** (attempt 3, started 2026-08-26T16:01Z) |
| Fluent Bit v5.0.9 | 🔴 **SIGSEGV crash-loop** — 24 crashes (run 1) / 13 crashes (re-validation), byte-identical fingerprint `flb_http_response_init @ flb_http_common.c:903` (HTTP/2 input server path). Leak readout INVALID (crash resets confound it). |

### The OTAP question (OTel-Arrow Protocol hop arms, 120-min)

| Arm | Combined CPU | Spans | mc / 1M spans | Verdict |
|---|--:|--:|--:|---|
| Config A: collector→OTAP→df_engine→DT | 190.7 mc | 13.40 M | 14.23 | OTAP hop **adds** +26% CPU vs native arrow |
| Config B: + 2nd OTAP hop (via gateway collector) | 190.2 mc | 10.15 M | 18.74 | 2nd hop **does not help** (+32% vs A) |

**OTAP does not improve otel-arrow efficiency in this topology** — every hop adds cost.

### Fluent Bit crash root-cause (final state of evidence)

- Crash is in the **HTTP/2 transport layer** (`flb_http2_response_begin` → `flb_http_common.c:903`),
  upstream of signal parsing; OTLP output to Dynatrace stays HTTP-200 throughout.
- **Not signal-specific**: isolation run (4 arms: metrics-only / traces-only / logs-only /
  connection-churn control) = 0 crashes in every arm over ~3h.
- **Not load-magnitude**: 2h synthetic ramps at up to 200 VU never crashed; the 24h live-mesh soak
  crash-loops. Trigger = live-mesh connection lifecycle (idle connections crossing the 10s downstream
  IO timeout), stochastic timing (inter-crash gaps 26 min … 6h22m), reproducible across 2 independent
  24h runs.
- `http2:off` mitigation **breaks gRPC ingestion** (Istio's primary path) — non-viable as a config
  fix; the real fix is an upstream patch. A diagnostic `http2:off` soak is pending (§2).

---

## 2. Chronological test register (all tests, by date)

| # | Date (UTC) | Test | Result | Evidence |
|---|---|---|---|---|
| 1 | 2026-07-22 15:58→17:59 | R1-P1 collector ramp (120m) | PASS — baseline 6.54 mc/1M | `RUN-REGISTER.md` |
| 2 | 2026-07-23 08:34→10:35 | R1-P2 fluentbit ramp (120m) | PASS w/ 🛑 metrics-loss finding | `RUN-REGISTER.md` |
| 3 | 2026-07-23 17:01→19:01 | R2-P1 collector ramp (replication) | PASS — replicates within ~2% | `RUN-REGISTER.md` |
| 4 | 2026-07-25 10:26→12:26 | R1-P3 arrow ramp | PASS 8/8 (0.51.0 rebuilt engine) | `RUN-REGISTER.md` |
| 5 | 2026-07-25 13:02→15:03 | R2-P3 arrow ramp (replication) | PASS — fresh deploy, valid replication | `RUN-REGISTER.md` |
| 6 | 2026-07-28 | CLEAN P1 collector (canonical re-run) | PASS — 150.3 mc, 10.40 mc/1M | `RUN-REGISTER.md`, ISI-1927 |
| 7 | 2026-07-28 | CLEAN P2 fluentbit (canonical re-run) | PASS — 79.8 mc, 5.87 mc/1M, 🛑 no metrics | `RUN-REGISTER.md`, ISI-1928 |
| 8 | 2026-07-29 09:12→11:12 | **OTAP Config A** ramp | 14.23 mc/1M — hop adds +26% | `results/otap-config-a/`, ISI-1949 |
| 9 | 2026-07-29 | CLEAN P3 arrow (canonical re-run) | PASS — 162.6 mc, 11.27 mc/1M | ISI-1937 |
| 10 | 2026-07-29 11:54→13:55 | **OTAP Config B** (2nd hop) ramp | 18.74 mc/1M — 2nd hop does not help | ISI-1950 |
| 11 | 2026-07-29 19:04→07-30 19:12 | **S1 collector 24h soak** | 🟢 NO LEAK (flat ~88.6 MiB plateau) | `RUN-REGISTER.md`, ISI-1811 |
| 12 | 2026-08-04 11:49→08-05 12:13 | **S2 fluentbit 24h soak** | 🔴 24× SIGSEGV crash-loop; leak readout INVALID | `RUN-REGISTER.md`, ISI-1823 |
| 13 | 2026-08-06 01:34→08-07 01:52 | **S2 fluentbit re-validation soak** | 🔴 crash REPRODUCES — 13× SIGSEGV, byte-identical fingerprint | `results/s2-fluent-revalidate/`, ISI-2093 |
| 14 | 2026-08-26 08:57→11:59 | **Crash isolation by signal type** (4 arms) | 0 crashes all arms — NOT signal-specific | `results/isi3264-crash-isolation/`, ISI-3264 |
| 15 | **2026-08-26 16:01 → (24h)** | **S3 arrow native 24h soak — RUNNING** | pending | `soak/S3-arrow` (NAS), ISI-3301 |
| 16 | pending (after #15) | **S4 OTAP-hop 24h soak** | scheduled | ISI-3302 |
| 17 | pending (after #16) | **S2m fluentbit `http2:off` diagnostic soak** | scheduled | ISI-3303 |

Invalid/void runs kept for the record: S3 attempt 1 (2026-07-25 16:35, VOID — node failure at T+8h,
all soak pods on one node; SPOF lesson recorded). R1P3/R2P3/S3 on df_engine 0.50.0 (2026-07-23,
cancelled — engine `DictionaryKeyOverflowError` crash; superseded by the 0.51.0 rebuild).

---

## 3. Per-engine summary for the episode

### Fluent Bit v5.0.9
- **Efficiency: best** (5.87 mc/1M spans — 44% cheaper than collector, 48% cheaper than arrow).
- **Metrics: broken** in this pipeline shape — 100% processor failure, app metrics lost.
- **Stability: fails a 24h production role** — reproducible HTTP/2-input SIGSEGV crash-loop.
- Fix path: upstream patch to `flb_http_common.c:903` (or a 5.x patch carrying it). No config
  workaround preserves gRPC.

### OTel Collector 0.154.0
- **Stability: best** — clean 24h soak, no leak, no restarts.
- Efficiency: 10.40 mc/1M spans; full signal fidelity (spans+logs+metrics all SAFE).

### OTel-Arrow native (df_engine 0.51.0)
- Efficiency: 11.27 mc/1M spans (within ~8% of collector); memory footprint higher (~158 MiB).
- Metrics routed to noop exporter for fairness (df_engine lacks cumulativetodelta) — declared
  NO-DATA, not a failure.
- OTAP hops add cost, don't reduce it (Config A +26%, Config B +32%).
- 24h soak: attempt 3 in progress (this report updates when it lands).

---

## 4. Method notes that keep these numbers honest

- Census discipline: pod identity (name + creationTimestamp) verified at Start AND End of every
  window; a pod replacement invalidates the run (memory resets fake flat trends).
- `dt.kubernetes.container.restarts` is sparse and missed 24 real restarts once — kubectl
  `restartCount` is ground truth for crashes.
- Crash-loop fingerprint in memory data: quarter-floors collapse to ~2 MiB (newborn RSS after each
  SIGSEGV) — recognisable in Dynatrace, and never a leak signal.
- DQL absolute windows must be quoted (`from:"2026-07-29T19:04:16Z"`); every register row is
  replayable.
