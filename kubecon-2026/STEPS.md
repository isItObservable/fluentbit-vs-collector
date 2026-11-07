# Benchmark steps — rampup staircase → parity gate → 12h soak → KPI

Run this procedure **per arm**, serial and single-engine. Never run two engines at once.

## 0. Deploy & smoke
```bash
export KUBECONFIG=/path/to/your/kubeconfig
./deploy-arm.sh <fluentbit|collector|arrow|otap>   # engine + (first time) apps
./validate-app.sh                                  # otel-demo works end to end
./validate-gate.sh <arm>                           # engine receives (accepted>0 / refused=0) + exports
```
Confirm app-deployment parity is in place (appProtocol on all gRPC/HTTP ports both namespaces,
ambient + waypoints, Telemetry at 100 %, `benchmark.*` attribution) — see
[`DEPLOYMENT.md`](./DEPLOYMENT.md).

## 1. Rampup staircase — 50 → 100 → 150 → 200 VU/app (30 min/step, 2h total)

Drive both apps together (locust → otel-demo, k6 → hipster-shop) and step the load every 30
minutes:

| Step | VU/app | Apply at | Load manifest |
|------|-------:|----------|---------------|
| 1 | 50 | T0 | `load/30-loadgen-rampup.yaml` |
| 2 | 100 | T0 + 30 min | `load/30-locust-otel-demo-job1.yaml` |
| 3 | 150 | T0 + 60 min | `load/30-locust-otel-demo-job2.yaml` |
| 4 | 200 | T0 + 90 min | `load/30-locust-otel-demo-job3.yaml` |

(hipster-shop k6 ramps 50→200 over matching 30-min stages.) The staircase gives the gate a
load-correlation signal: delivered spans/logs should climb step-for-step with VU.

## 2. Pre-soak PARITY GATE (mandatory — do NOT soak on NO-GO)

At T0 + 120 min, measure the rampup window per namespace (`otel-demo`, `hipster-shop`) from the
backend and check **all** of:

1. **Signals present & ramping** — app SDK spans **+** Istio mesh spans **+** logs all present, and
   span/log volume correlates with the VU staircase (Spearman **ρ ≥ 0.8**).
2. **Mesh ratio 72–77 %** — mesh (Istio-emitted) spans as a fraction of total spans, matching the
   Arm C/D reference profile. This is the under-mesh guard.
3. **±25 % vs C/D** — per-namespace span + log totals within ±25 % of the Arm C/D reference
   window.
4. **(Fluent Bit arm) compression ON** — gateway wire-bytes/span is single-digit (≈2–3), not the
   ~28.5 uncompressed figure.

**GO** → proceed to clean + soak. **NO-GO** → root-cause (under-mesh, missing `appProtocol`,
missing `OTEL_EXPORTER_OTLP_ENDPOINT`, app crash-loop) and re-run the rampup. A conditional GO is
acceptable only when a caveat is app-side and non-confounding (e.g. a hipster-shop
`currencyservice` crash-loop under 200 VU affects all arms equally) — record the caveat.

## 3. Clean → 12h soak at steady 50 VU/app
```bash
# delete the rampup load jobs, then apply the steady soak load
kubectl delete -f load/30-locust-otel-demo-job1.yaml -f load/30-locust-otel-demo-job2.yaml -f load/30-locust-otel-demo-job3.yaml --ignore-not-found
kubectl apply  -f load/31-loadgen-soak.yaml        # steady 50 VU/app
# soak window = T0_SOAK .. T0_SOAK + 12h
```
During the soak, sample periodically: engine 0 new restarts / 0 SIGSEGV, memory CV flat
(tail-flat leak check), drop/error rate flat, wire-bytes/span steady, delivered spans+logs
climbing.

## 4. KPI capture (at SOAK_END)

Capture and record:

- **Stability** — engine restarts / SIGSEGV (expect 0 / 0).
- **Loss** — drop rate = dropped / delivered (accept < 0.01 %); accepted == sent.
- **Memory** — soak-average + tail-flat drift (no monotonic leak).
- **Wire B/span** — `sum(dt.kubernetes.pod.network_transmitted_data)` over the rampup window ÷
  delivered spans (excl. substrate). This is the compressed-wire figure.
- **mc/1M-spans** — rampup-average engine CPU millicores ÷ delivered spans × 1 M.
- **Per-namespace span + log profile** — otel-demo and hipster-shop separately.

Then tear down before the next arm:
```bash
./teardown-arm.sh <arm>     # leaves the apps; removes the engine
```

See [`RESULTS.md`](./RESULTS.md) for the banked A/B/C/D numbers and the economics tables.
