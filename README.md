# Benchmark: Fluent Bit v5 vs OpenTelemetry Collector vs OTel-Arrow

Branch: **`fluentbit-v5-vs-otel-arrow`** (one branch per benchmark, per repo convention;
predecessor was `fluentbitv4.0`).

This episode benchmarks **three ways to ship the same Kubernetes pod logs** from a
node-local edge agent to a gateway, and compares the *transport* cost. The only
variable is the edge→gateway hop:

| Variant | Edge component | Edge→gateway transport | Self-telemetry |
|---------|----------------|------------------------|----------------|
| **A · otel-arrow** | OTel Collector contrib `0.154.0` DaemonSet | **OTAP** — columnar Apache Arrow over a long-lived gRPC stream (`otelarrow` exporter → `otelarrow` receiver) | `:8888/metrics` |
| **B · otel-collector** | Same collector build/pipeline | plain **OTLP/gRPC + zstd** (`otlp` exporter → `otlp` receiver) | `:8888/metrics` |
| **C · fluentbit v5** | Fluent Bit `5.0.9` DaemonSet | **OTLP/HTTP** (`opentelemetry` output → `otlp` receiver) | `:2020/api/v2/metrics/prometheus` |

All three tail the **same** `/var/log/pods/*/*/*.log`, apply equivalent Kubernetes
metadata enrichment (`k8sattributes` ≈ Fluent Bit `kubernetes` filter), and run
**concurrently** so they ship an identical log stream during the same window — a clean
A/B/C rather than three sequential cluster rebuilds.

## Methodology (kept comparable to the v4 run)

Same four axes the v4 fluentbit-vs-collector episode measured:

1. **Throughput** — log records/sec shipped (`rate(otelcol_exporter_sent_log_records)`;
   Fluent Bit `rate(fluentbit_output_proc_records_total)`).
2. **Wire efficiency** *(the OTAP headline)* — bytes on the wire per log record.
   - OTAP / OTLP: `otelcol_exporter_sent_wire / otelcol_exporter_sent_log_records`.
   - Fluent Bit: `fluentbit_output_proc_bytes_total / fluentbit_output_proc_records_total`
     (uncompressed unless `compress gzip`).
3. **CPU / memory** — per edge pod, from `kubectl top` (metrics-server) so every
   variant is measured from the *same* source; cross-checked against
   `otelcol_process_cpu_seconds` / `otelcol_process_memory_rss` self-telemetry.
4. **Loss** — `send_failed` / `dropped` counters and the accepted-vs-sent delta
   (`otelcol_receiver_accepted_log_records` − `otelcol_exporter_sent_log_records`;
   Fluent Bit `fluentbit_output_dropped_records_total` + `retries_failed`).

### Load — phased profile against two apps (ISI-1779, 2026-07-21)

Load is driven against **two** apps — **otel-demo** *and* **hipster-shop** (Online
Boutique) — with a controlled, phased VU profile so the transported log/trace volume
is *aligned with the load*. Two Locust drivers share one phase-aware `LoadTestShape`,
so 50 VU hit each app at the same wall-clock time:

1. **Stable baseline** — 50 VU/app, 30 min → recovery gate.
2. **Ramp-up** — +50 VU every 30 min for 2 h (50→100→150→200) → recovery gate.
3. **Leak soak** — 50 VU/app, 24 h → collector RSS trend for **memory-leak detection**.

Full harness + orchestration in `loadtest/` (`loadtest/README.md`). Because all three
shippers still tail the same host logs, the log stream stays identical across
variants — the phased profile controls the *volume vs time* and adds the two-app +
24 h-leak axes; the legacy always-on `loadtest_job.yaml` is superseded.

### Realistic feature parity (all three variants)

A benchmark of a *bare* tail→ship pipeline isn't representative — real deployments
enrich **and transform**. So every variant runs the **same production-shaped feature
set**, applied identically, so the only variable stays the edge→gateway transport:

| Feature | otel-arrow / otel-collector | fluentbit v5 |
|---------|-----------------------------|--------------|
| K8s metadata enrichment | `k8sattributes` processor | `kubernetes` filter |
| Cluster attribute | `resource` processor | `modify` filter |
| **Transform** — severity normalization, e-mail PII redaction, drop file-path key | `transform` (OTTL `log_statements`) | `lua` filter (`redact.lua`) |

The three transform operations are byte-for-byte equivalent across shippers, so the
extra CPU is charged to *all* variants equally and the comparison stays honest. OTTL
runs **before** OTAP encoding, so the wire format is orthogonal to it.

### Scope limits (deliberate)

- **No tail sampling.** The v4 episode compared Fluent Bit's tail-sampling build against
  the collector's `tail_sampling` processor across six policies. OTAP is a **transport**
  optimization, not a sampling one, so tail sampling stays out of scope — it'd add a
  second variable. (OTTL transforms are *in* — see feature parity above — because they
  run identically on all three and reflect a real pipeline; sampling would change the
  *volume* each variant ships and break the identical-stream control.)
- **Isolated sinks.** Each variant's gateway drops received data (`nop`) so we measure
  the edge→gateway transport only, with no Dynatrace double-ingest skew. (The
  production otel-arrow stack in ISI-1783 keeps its real Dynatrace egress; these
  baseline gateways are benchmark-only.)
- Number discipline (ISI-1776): OTAP efficiency is quoted **relative to a named
  baseline** — ~2× vs OTLP+zstd is the honest headline; the 10×/15–30× figures are
  vs *uncompressed* OTLP and must be labelled as such.

## Layout

```
otel-arrow/       Variant A — agent (OTAP) + gateway   (= the ISI-1783 deployed default)
otel-collector/   Variant B — agent (OTLP+zstd) + gateway + RBAC
fluentbit-v5/     Variant C — Fluent Bit v5 DaemonSet + config + OTLP/HTTP gateway
loadtest/         phased load harness — 2 Locust drivers (otel-demo + hipster-shop),
                  shared phase-aware LoadTestShape, hipster-shop/ deploy, run-benchmark.sh
scripts/collect.sh  snapshot all three (run twice); compute.py -> the table
RESULTS.md        the A/B/C comparison table
```

## Run

```bash
export KUBECONFIG=~/.config/capmox/observable-otelarrow.kubeconfig
# Variant A is already live (ISI-1783). Add B and C:
kubectl apply -f otel-collector/   # OTLP baseline agent+gateway+rbac
kubectl apply -f fluentbit-v5/      # Fluent Bit v5 DS+config+gateway
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# let all three ship the same logs for >=20 min, then:
scripts/collect.sh /tmp/snap_t0.txt         # wait >=20m
scripts/collect.sh /tmp/snap_t1.txt
python3 scripts/compute.py /tmp/snap_t0.txt /tmp/snap_t1.txt   # -> the A/B/C table
```
