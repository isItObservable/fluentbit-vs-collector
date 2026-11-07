# Application deployment — parity across all four arms

The two load-bearing apps — [**otel-demo**](https://github.com/open-telemetry/opentelemetry-demo)
and **hipster-shop** (Online Boutique) — are deployed **once** and kept running across all four
arms. Only the telemetry *destination* (and the three `benchmark.*` labels) change when you switch
arms. This document is the parity contract: get these four things identical on every arm or the
per-span economics are not comparable.

> The first benchmark pass failed parity: Arms A and B were **under-meshed** relative to the
> df_engine arms (C/D) — fewer Istio mesh spans per app span — which made their per-span wire/cost
> figures look artificially different. This re-run re-wires the apps and mesh to match C/D exactly
> and gates on it. See the parity gate in [`STEPS.md`](./STEPS.md).

## 1. `appProtocol` on every gRPC/HTTP service port — BOTH namespaces

Istio ambient classifies L7 traffic (and therefore emits mesh spans) only when it knows the
protocol. Every Service port that carries gRPC or HTTP in **both** `otel-demo` and `hipster-shop`
must declare `appProtocol` (`grpc` or `http`). Ports that are genuinely raw TCP (e.g. a `tcp-*`
port) are left without it — correctly, they carry no classified mesh spans.

```yaml
# example: a gRPC service port gains appProtocol so the waypoint classifies and traces it
spec:
  ports:
    - name: grpc
      port: 8080
      targetPort: 8080
      appProtocol: grpc        # <-- required for mesh span emission
```

> A fresh `helm upgrade`/`helm install` of otel-demo **wipes `appProtocol`** off the Service
> ports — re-apply it per service after any chart redeploy, or the arm silently goes under-meshed.

## 2. Istio ambient + a waypoint per namespace

Both app namespaces run in **ambient** mode with a **waypoint** Gateway so east-west traffic is
L7-classified and traced:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: hipster-shop            # one per app namespace (also otel-demo)
  labels: { istio.io/waypoint-for: service }
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - { name: mesh, port: 15008, protocol: HBONE, allowedRoutes: { namespaces: { from: Same } } }
```

Example manifest (waypoint + Telemetry, both namespaces):
[`manifests/parity/waypoint-and-telemetry.example.yaml`](./manifests/parity/waypoint-and-telemetry.example.yaml).

## 3. 100 % tracing + access logging via one Telemetry CR per namespace

A single `Telemetry` CR per namespace carries **both** `tracing` and `accessLogging` at
`randomSamplingPercentage: 100`, pointing at the arm's gateway through named mesh
`extensionProviders`.

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata: { name: bench-tracing, namespace: hipster-shop }
spec:
  tracing:
    - providers: [ { name: bench-otlp } ]      # -> current arm's gateway, path /v1/traces
      randomSamplingPercentage: 100
      customTags:
        benchmark.arm:    { literal: { value: A } }         # flip per arm: A|B|C|D
        benchmark.engine: { literal: { value: fluentbit } } # flip per arm
        benchmark.run:    { literal: { value: kubecon-2026 } }
  accessLogging:
    - providers: [ { name: bench-otlp-als } ]  # -> current arm's gateway, path /v1/logs
      disabled: false
```

> **One CR, both signals.** `tracing` and `accessLogging` must live in the **same** `Telemetry` CR
> within a namespace scope — two separate CRs in the same scope cause a silent "last writer wins"
> and you lose one signal.

The mesh `extensionProviders` (`bench-otlp` for traces, `bench-otlp-als` for logs) are defined
once in the Istio `meshConfig` and re-pointed at the active arm's gateway when you switch arms:

```yaml
# istio meshConfig (configmap istio -n istio-system) — re-point service per arm
extensionProviders:
  - name: bench-otlp
    opentelemetry: { service: bench-fluentbit-otlp.bench-fluentbit.svc.cluster.local, port: 4318, http: { path: /v1/traces, timeout: 5s } }
  - name: bench-otlp-als
    opentelemetry: { service: bench-fluentbit-otlp.bench-fluentbit.svc.cluster.local, port: 4318, http: { path: /v1/logs,   timeout: 5s } }
```

After editing `meshConfig`, **restart `istiod`, both waypoints, and ztunnel** so the new provider
and sampling take effect.

## 4. `benchmark.*` attribution on app spans

App SDK spans are labelled via the workloads' `OTEL_RESOURCE_ATTRIBUTES` so they filter to the arm
the same way the mesh `customTags` do:

```
OTEL_RESOURCE_ATTRIBUTES=benchmark.arm=A,benchmark.engine=fluentbit,benchmark.run=kubecon-2026
OTEL_EXPORTER_OTLP_ENDPOINT=http://bench-fluentbit-otlp.bench-fluentbit.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

## Switching arms (parity-preserving)

1. Tear down the previous engine arm (keep the apps running).
2. Deploy the new engine arm (new `bench-<engine>` namespace workloads).
3. Re-point the apps: set `OTEL_EXPORTER_OTLP_ENDPOINT` (and hipster `COLLECTOR_SERVICE_ADDR`) at
   the new gateway Service; structure-preserving swap of `benchmark.arm` / `benchmark.engine` in
   `OTEL_RESOURCE_ATTRIBUTES` (leave `benchmark.run` as the campaign id).
4. Re-point the mesh `extensionProvider` services at the new gateway; flip the Telemetry
   `customTags`; restart `istiod` + waypoints + ztunnel.
5. Verify `appProtocol` is present on all gRPC/HTTP ports in both namespaces (re-apply if a chart
   redeploy wiped it).
6. Run the pre-soak **parity gate** ([`STEPS.md`](./STEPS.md)) before trusting the arm.
