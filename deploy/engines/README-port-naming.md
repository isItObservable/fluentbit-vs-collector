# Engine Service port names are load-bearing (found in R1P1)

**Rule: the OTLP gRPC port on every engine Service must be named `grpc-otlp`, with
`appProtocol: grpc`. Never `otlp-grpc`.**

## Why

Istio derives a port's application protocol from the **prefix** of the Service port
name, in the form `<protocol>[-<suffix>]`. The recognised protocol tokens are
`grpc`, `grpc-web`, `http`, `http2`, `https`, `tcp`, `tls`, `udp`, `mongo`, `mysql`,
`redis`.

`otlp-grpc` has the convention backwards. It parses as protocol `otlp`, which is not
recognised, so the port falls back to **plain TCP** and Istio builds the outbound
cluster **without HTTP/2**.

Envoy's OpenTelemetry tracer exports over `envoy_grpc`, which *requires* HTTP/2.
Against a TCP-classified cluster every single export fails.

## How it presents (all three symptoms look like success)

Nothing logs an error. The evidence only shows up in Envoy's upstream cluster stats,
and Istio's default stats matcher **hides `tracing.*`**, so the sidecar looks idle:

```
tracing.opentelemetry.spans_sent   : 24275   <- sidecars WERE producing spans
tracing.opentelemetry.spans_dropped:     0
```

The upstream cluster tells the real story:

```
cx_connect_fail :    0     <- TCP connects fine, so "connectivity" checks pass
rq_total        : 7971
rq_error        : 7908     <- every request fails
rq_success      :   63
cx_total        : 7909     <- one connection torn down per failed request
```

Two controls actively mislead you:

- **otel-demo `frontend-proxy` delivers Envoy spans fine** — it has no sidecar, so it
  connects to the engine directly and negotiates HTTP/2 itself, never touching
  Istio's cluster config.
- **The apps' own OTLP survives** — their SDKs retry on a long-lived connection and
  scrape through as the handful of successes (the 63 above).

To see `tracing.*` at all, temporarily annotate one pod with
`sidecar.istio.io/statsInclusionPrefixes: tracing` — and **remove it afterwards**, it
is a parity deviation under §2 of the plan.

## After the fix (same counter, post reset)

```
cx_total: 4   rq_error: 0   rq_success: 2651
```

Connection reuse restored, zero failures, and **21,780** Istio-generated spans in
Dynatrace under `benchmark.telemetry_source == "istio-mesh"`.

## Why this matters to the benchmark, not just to correctness

Mesh spans are roughly **20% of the intended span volume**. Left unfixed, all six
runs would have measured all three engines on materially less traffic than the plan
specifies — silently, with a green-looking deployment and nothing in any log. It is
applied identically to all three engines so the comparison stays fair (§2).

`validate-phase.sh` CHECK 4 catches the *consequence* (zero mesh spans). This file
records the *cause*, because the consequence has three other possible causes (4a/4b/4c).
