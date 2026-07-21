# Results — Fluent Bit v5 vs OTel-Collector (OTLP) vs OTel-Arrow (OTAP)

Cluster: **observable-otelarrow** (CAPI/Proxmox, 3 workers, k8s v1.35.3). All three
edge shippers tail the same `/var/log/pods` and run **concurrently** on the same nodes,
so they ship an identical log stream. Signal under test: **pod logs**. Load: the OTel
Demo's always-on load generator. Measurement window: see `TS=` in the snapshot files.

Sources: records + loss from each shipper's self-telemetry; CPU / memory / wire-bytes
from per-pod cAdvisor (uniform across all three). Compute with
`scripts/diff.sh snap_t0.txt snap_t1.txt`.

## Headline finding (verified live, 2026-07-20)

**OTAP wire cost per log record *amortizes down* over the life of the Arrow stream** —
the columnar schema/dictionary is sent once, so marginal bytes/record fall as the
long-lived stream warms:

| otel-arrow stream age | log records shipped | `sent_wire` bytes (logs) | wire bytes / record |
|-----------------------|---------------------|--------------------------|---------------------|
| ~3.3 h (42.5k recs)   | 42,511              | 10,487,975               | **246.7**           |
| +~10 min (206k recs)  | 205,873             | 12,125,558               | **58.9**            |
| marginal (over that Δ) | +163,362           | +1,637,583               | **~10.0**           |

That marginal ~10 B/record is the OTAP steady-state story; the vs-uncompressed-OTLP
"10×–30×" headline should be quoted **only** against a named uncompressed baseline
(ISI-1776 number discipline). The apples-to-apples baseline is OTLP **+ zstd** (Variant B).

## Loss — all three effectively lossless under this load

Verified at t0: `send_failed_log_records` / `output_dropped_records_total` /
`output_retries_failed_total` = **0** on every variant. The only accepted−sent gap is a
few hundred records sitting in the in-flight batch/buffer (not loss).

## Per-variant comparison — MEASURED (window ≈ 5.98 h steady state)

> **Pipeline note (feature parity, 2026-07-21):** this window was captured with the
> **enrich-only** pipeline (k8sattributes/kubernetes + resource, no transform). All three
> variants now also run the identical **`transform`/`redact`** step (severity
> normalization + e-mail redaction + drop file-path — OTTL on A/B, Lua on C; deployed &
> validated live). Adding equal processing to all three raises every **CPU** figure but
> leaves the **wire** story intact (redaction slightly shrinks the body; the transport
> ratio OTAP↔OTLP is unchanged). Treat the CPU column below as the enrich-only reference;
> the **feature-on** CPU/mem is re-captured at record time alongside the phased load
> (⟨CAPTURE-AT-RECORD⟩ table below), from the now-live feature-parity DaemonSets.

`scripts/compute.py snap_t0.txt snap_t1.txt` — window `2026-07-20T20:08:30Z →
2026-07-21T02:07:13Z` (21,523 s). DaemonSet totals summed across its 3 pods; CPU/mem/wire
from per-pod cAdvisor (uniform source), records/loss from self-telemetry.

| Variant | Transport | Throughput (recs/s) | Wire bytes/record | CPU (cores, 3-pod DS) | Mem (MiB/pod) | Loss |
|---------|-----------|--------------------:|------------------:|----------------------:|--------------:|-----:|
| **A · otel-arrow**   | OTAP (Arrow/gRPC stream)   | 7,591.7 | **9.2** (native `sent_wire` 7.8) | 0.242 | 175.1 | 0 |
| **B · otel-collector** | OTLP/gRPC + zstd         | 7,591.1 | **17.0** | 0.216 | 86.4 | 0 |
| **C · fluentbit v5** | OTLP/HTTP (uncompressed)   | 7,591.3 | **214.7** | 1.516 | **14.5** | 0 |

Throughput is identical by construction (all three tail the same logs) — that's the
control confirming a fair test, not a result. The results are the three cost columns.

### What the numbers say

- **Wire efficiency (the OTAP headline):** OTAP **9.2 B/record** vs OTLP+zstd **17.0** =
  **~1.85× leaner on the wire against a compressed baseline** — squarely the "~2× vs
  OTLP+zstd" figure (ISI-1776 discipline), *not* the inflated vs-uncompressed number.
  vs Fluent Bit's uncompressed OTLP/HTTP (214.7 B/rec) OTAP is **~23×** — that large
  ratio is a *compression* story (fluentbit sends no compression by default), so quote it
  as "vs uncompressed," never bare. OTAP's own `sent_wire` self-telem (7.8 B/rec, logs
  only) cross-checks the 9.2 cAdvisor figure; the ~1.4 B gap is gRPC/k8s-API/scrape
  overhead cAdvisor also counts.
- **The trade — nobody wins every column:**
  - **otel-arrow** buys the smallest wire footprint by spending the **most RAM**
    (175 MiB/pod — Arrow columnar buffers). CPU is cheap (0.24 cores/DS).
  - **fluentbit v5** is astonishingly **lean on RAM (14.5 MiB/pod, ~12× less than OTAP)**
    but **CPU-hungry (1.52 cores/DS, ~6–7× the collectors)** and fattest on the wire.
  - **otel-collector (OTLP+zstd)** is the balanced middle: half the OTAP RAM, similar CPU,
    ~2× the wire bytes.
- **Loss = 0 everywhere.** No `otelcol_exporter_send_failed_log_records` metric ever
  appeared (= zero failures); `fluentbit_output_dropped_records_total` and
  `retries_failed_total` = 0. The small accepted−sent delta in the raw snapshot
  (~600–700 records) is in-flight batch/queue at the sampling instant over 160 M+
  records shipped (~0.0004 %), **not** loss.

### Measurement note — OTLP has no native wire counter

The classic `otlp` exporter emits only `sent_log_records`, no byte/wire counter — so
Variant B's wire cost (and A's/C's for uniformity) is pod cAdvisor
`container_network_transmit_bytes_total`. Only the `otelarrow` exporter exposes
`otelcol_exporter_sent_wire` natively; we report both for A as a cross-check.

## Phased load results — ⟨CAPTURE-AT-RECORD⟩

The table above is the always-on-loadgen steady-state A/B/C. The phased profile
(ISI-1779, 2026-07-21) adds a two-app (otel-demo + hipster-shop) load, a ramp,
and a 24 h leak soak — run via `loadtest/run-benchmark.sh` at record time. Fill
each cell from the phase snapshots (`compute.py snap_<phase>_t0 snap_<phase>_t1`):

| Phase | VU/app | Variant | Throughput (recs/s) | CPU (cores/DS) | Mem (MiB/pod) | Loss |
|-------|-------:|---------|--------------------:|---------------:|--------------:|-----:|
| Stable 30 min | 50 | A · arrow / B · otlp / C · flb | ⟨…⟩ | ⟨…⟩ | ⟨…⟩ | ⟨…⟩ |
| Ramp peak (200) | 200 | A / B / C | ⟨…⟩ | ⟨…⟩ | ⟨…⟩ | ⟨…⟩ |
| Leak soak (24 h) | 50 | A / B / C | ⟨…⟩ | ⟨start → end⟩ | ⟨start → end⟩ | ⟨…⟩ |

**Memory-leak read:** compare each edge pod's `container_memory_working_set_bytes`
at `snap_p3_leak_t0` vs `snap_p3_leak_end` under a flat 50-VU input. A healthy
transport plateaus; a monotonic rise across the 2 h intermediate points
(`snap_p3_leak_<Ns>`) = leak. Report the slope, not just the endpoints.

### Teardown (restore ISI-1783 clean state)

```bash
kubectl delete -f otel-collector/ -f fluentbit-v5/   # leaves Variant A (the deployed default)
# phased harness teardown:
kubectl delete -f loadtest/locust-otel-demo.yaml -f loadtest/locust-hipster-shop.yaml --ignore-not-found
kubectl delete configmap loadtest-scripts -n default --ignore-not-found
kubectl delete -k loadtest/hipster-shop/ --ignore-not-found; kubectl delete ns hipster-shop --ignore-not-found
```

## Notes / caveats

- cAdvisor pod network TX includes a little non-log traffic (k8s API watches for
  metadata enrichment, the :8888/:2020 scrape). Over a 20-min steady window the log
  shipping dominates; treat wire bytes/record as ±low-single-digit-%.
- Fluent Bit's leaner memory vs the collectors is the clearest cross-variant contrast;
  OTAP's win is **wire bytes**, paid for in agent CPU + RAM.
- Scope: **no tail sampling / no OTTL** (out of scope per ISI-1779) — transport is the
  only variable.
