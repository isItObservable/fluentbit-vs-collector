# Manifests

Foundation + per-arm engine manifests for the four-arm benchmark. Apply via `../deploy-arm.sh`;
these are the raw manifests it applies.

| File / dir | Purpose |
|------------|---------|
| `00-namespaces.yaml` | per-arm engine namespaces (labeled so no backend agent wraps the engine) |
| `00-storage-local-path.yaml` | local-path StorageClass (if your cluster lacks a default) |
| `10-dynakube.yaml` | Dynatrace DynaKube for pod resource monitoring — reads the `benchmark-cluster` secret |
| `arm-fluentbit/` | Arm A — Fluent Bit 5.1.5 (agent DaemonSet + gateway), **OTLP/HTTP + gzip** on every output |
| `arm-collector/` | Arm B — OTel Collector contrib 0.163.1 (reference), OTLP + zstd |
| `arm-arrow/`  | Arm C — df_engine 0.61.0, OTLP in/out + forwarder for Api-Token egress |
| `arm-otap/`   | Arm D — edge collector (OTAP egress) → df_engine relay → backend direct; bridge collector for df_engine internal metrics only |
| `parity/` | app-side parity wiring example — Istio waypoint + 100% tracing/access-logging Telemetry for both app namespaces (see `../DEPLOYMENT.md`) |

## Before you apply
1. Fill in your backend endpoint + tokens: `cp ../dynatrace-secret.example.yaml ../dynatrace-secret.yaml`,
   edit, and `kubectl -n dynatrace apply -f ../dynatrace-secret.yaml`.
2. Replace `<YOUR_TENANT>` in `10-dynakube.yaml`, `arm-fluentbit/`, `arm-collector/`, `arm-arrow/`,
   and `arm-otap/` with your Dynatrace tenant (or point the OTLP exporters at your own backend).

## Engine image
Arms C and D use the published Rust OTAP Dataflow engine image
`ghcr.io/henrikrexed/df-engine:0.61.0` (public, built from `open-telemetry/otel-arrow`
`rust/otap-dataflow/v0.61.0`). Swap in your own build if you prefer.

## Version pins (frozen at setup)
Fluent Bit 5.1.5 · OTel Collector contrib 0.163.1 · df_engine 0.61.0 · Dynatrace Operator 1.11.0 ·
Kubernetes 1.35.3 · Istio 1.29.2 (ambient) · Cilium 1.17.4.
