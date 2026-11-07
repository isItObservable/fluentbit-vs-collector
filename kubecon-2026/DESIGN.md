# Design — Fluent Bit gzip + parity wiring

This benchmark compares four telemetry pipelines on a **fair wire**. Two design decisions make
the comparison honest: (1) Fluent Bit compresses its OTLP output with **gzip**, and (2) every arm
runs the apps and the mesh with **identical parity wiring** so each engine sees a comparable
stream of spans, mesh spans, and logs. This document covers both.

## 1. Fluent Bit — gzip on every OTLP output

### Why
An earlier pass ran Fluent Bit's `opentelemetry` output **uncompressed**, while the OTel Collector
used OTLP + **zstd** and the OTAP arm used Apache **Arrow + zstd**. That produced a wire figure of
~**28.5 B/span** for Fluent Bit vs ~2 B/span for the others — and a tempting but misleading "Fluent
Bit is 10–20× fatter on the wire" headline. That gap is a **compression-configuration artifact**,
not an engine property: HTTP/OTLP payloads compress extremely well (mostly repeated attribute keys
and resource blocks), so shipping them raw is the whole story.

Fluent Bit v5's `out_opentelemetry` supports `compress: gzip`, and the receiving
`in_opentelemetry` (gateway) and the backend both decode `Content-Encoding: gzip` transparently.
Turning it on makes Fluent Bit a like-for-like wire citizen.

### The change
In the two-tier topology (DaemonSet agent → gateway Deployment → backend), **every**
`opentelemetry` output carries `compress: gzip`:

```yaml
# agent → gateway (cluster-internal, tls off)
outputs:
  - name: opentelemetry
    host: bench-fluentbit-otlp.bench-fluentbit.svc.cluster.local
    port: 4318
    logs_uri: /v1/logs
    tls: off
    compress: gzip            # <-- the change

# gateway → backend (tls on)
outputs:
  - name: opentelemetry
    host: <YOUR_TENANT>.live.dynatrace.com
    port: 443
    tls: on
    compress: gzip            # <-- the change
    metrics_uri: /api/v2/otlp/v1/metrics
    traces_uri:  /api/v2/otlp/v1/traces
    logs_uri:    /api/v2/otlp/v1/logs
    header: Authorization Api-Token ${DT_INGEST_TOKEN}
```

Everything else is byte-identical to the uncompressed baseline — gzip is the **only** delta — so
the before/after wire figure isolates compression cleanly. Full manifest:
[`manifests/arm-fluentbit/20-fluentbit.yaml`](./manifests/arm-fluentbit/20-fluentbit.yaml).

### Result
~**10× compression on the wire** (uncompressed protobuf `proc_bytes` ÷ pod eth0 TX bytes), wire
cost **28.5 → 2.27 B/span** (**~12.5×** smaller), within **~11 %** of the Collector's 2.04 B/span.
The trade: engine CPU rose (gzip is not free), making Fluent Bit the most CPU-expensive full
engine on this run at **9.59 mc/1M-spans**. See [`RESULTS.md`](./RESULTS.md).

### Measuring the wire (distroless note)
Fluent Bit v5 images are **distroless** — no shell for `kubectl exec`. Measure the wire
cluster-side instead of in-pod:

- **Wire bytes** = `container_network_transmit_bytes_total{pod=bench-fluentbit-gateway*,interface="eth0"}`
  (the gateway's only external egress is the backend on :443), read via
  `kubectl get --raw /api/v1/nodes/<node>/proxy/metrics/cadvisor`, **or** the backend-side
  `sum(dt.kubernetes.pod.network_transmitted_data)` over the window.
- **Uncompressed bytes** = Fluent Bit's own `fluentbit_output_proc_bytes_total` (that counter is
  the *uncompressed* protobuf payload, pre-gzip).
- **B/span** = wire-byte delta over the window ÷ spans delivered in the window.

## 2. Parity wiring (same for every arm)

The engine is the only thing that should differ between arms. Everything feeding it must be
identical. Parity is enforced in three places — detail and manifests in
[`DEPLOYMENT.md`](./DEPLOYMENT.md):

1. **App export target.** All otel-demo + hipster-shop workloads point
   `OTEL_EXPORTER_OTLP_ENDPOINT` (and hipster's `COLLECTOR_SERVICE_ADDR`) at the arm's gateway
   Service. Fluent Bit is **HTTP-only (:4318)**, so apps use `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`
   on every arm for protocol parity (not gRPC on the Collector arm and HTTP on the FB arm).
2. **Mesh tracing.** Istio **ambient + a waypoint per namespace**, with a `Telemetry` CR at
   `randomSamplingPercentage: 100` so mesh span coverage is identical across arms. The mesh
   `extensionProvider` points at the current arm's gateway.
3. **Attribution.** `benchmark.arm` / `benchmark.engine` / `benchmark.run` ride along on both the
   app spans (via `OTEL_RESOURCE_ATTRIBUTES`) and the mesh spans (via Istio `customTags`), so every
   span is filterable to its arm in the backend.

When switching arms you re-point (not re-deploy) the apps and the mesh `extensionProvider` at the
new gateway, flip the three `benchmark.*` values, and restart the waypoints + ztunnel to pick up
the new mesh config. The pre-soak **parity gate** then confirms the new arm is shipping a
comparable stream (mesh ratio 72–77 %, ±25 % vs the C/D reference) before any soak is trusted —
see [`STEPS.md`](./STEPS.md).
