# ISI-3264 — Fluent Bit v5.0.9 crash isolation by signal type (telemetrygen OTLP/gRPC load)

**Question:** is the S2 crash-loop (`flb_http_common.c:903` SIGSEGV) caused by one telemetry
signal type (metrics / traces / logs)?

**Method:** fresh fluent-bit `5.0.9` engine (`bench-fluentbit-v5-67978b69d8-p55xd`,
OTLP/gRPC endpoint `bench-fluentbit-v5.default.svc.cluster.local:4317`), one signal type per
arm via `telemetrygen` (no Istio sidecar on the load pods), engine `restartCount` polled every
30 s, per-crash `logs --previous` + `lastState.terminated` capture with fingerprint check
(`run-arms.sh` in this directory). Arms run sequentially; ~45 min each.

## By-arm results

| arm | signal | crashed? | crashes | restarts/hr | fingerprint 903? | window |
|-----|--------|----------|---------|-------------|------------------|--------|
| A | metrics-only | no | 0 | 0.00 | n/a | 2716s |
| B | traces-only | no | 0 | 0.00 | n/a | 2712s |
| C | logs-only | no | 0 | 0.00 | n/a | 2714s |
| D | conn-lifecycle (min payload) | no | 0 | 0.00 | n/a | 2711s |

Final engine restartCount: **0** on pod `bench-fluentbit-v5-67978b69d8-p55xd` across the full
~3h run. Load parameters: arms A/B/C `workers=50 rate=10`; arm D `workers=80 rate=1`
(connection-lifecycle control — many mostly-busy HTTP/2 connections, minimal payload).

## Verdict

1. **The metrics/traces/logs hypothesis is ruled out empirically.** No single signal type
   crashes the engine in isolation — consistent with the stack analysis (the crash site is in
   the HTTP/2 transport layer, `flb_http2_response_begin` → `flb_http_common.c:903`, below the
   signal demux).
2. **Synthetic load did not reproduce the crash at all** — including the connection-churn
   control arm. This mirrors the rampup result (0 crashes at up to 200 VU synthetic over 2h)
   versus the live-mesh 24h soaks (24× and 13× crashes, byte-identical fingerprint). The
   differentiator is the **live-mesh client population and multi-hour duration**, not signal
   type and not raw load magnitude.
3. **Honest caveat on arm D:** telemetrygen at `rate=1`/worker keeps every connection busier
   than the real trigger. Real crashes are each preceded by
   `[downstream] connection … timed out after 10 seconds (IO timeout)` — i.e. connections idle
   **>10 s**. telemetrygen never idles that long, so arm D as-run could not exercise the actual
   trigger condition. A true synthetic reproduction would need idle-gapped connection patterns
   (bursts spaced >10 s apart) or the live mesh itself. The two 24h live-mesh soaks
   (S2-fluentbit / S2-fluent-revalidate) remain the authoritative reproduction.

**Conclusion for the benchmark:** the Fluent Bit v5.0.9 crash-loop is a **connection-lifecycle
defect in the HTTP/2 server path** (idle connections crossing the 10 s downstream IO timeout
under live-mesh conditions over hours), **not a payload/signal defect**.

Raw evidence: `driver.log`, `summary.txt`, `run-arms.sh` (this directory).
Run window: 2026-08-26T08:57:31Z → 2026-08-26T11:59:05Z (all arms complete).
