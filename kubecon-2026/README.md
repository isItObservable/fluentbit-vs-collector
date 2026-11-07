# KubeCon 2026 benchmark — Fluent Bit vs OTel Collector vs OTel-Arrow (OTLP & OTAP)

A reproducible, like-for-like soak benchmark of four telemetry-pipeline engines. Each engine is
run **serial and single-engine** (only one in the cluster at a time) against the **same**
[otel-demo](https://github.com/open-telemetry/opentelemetry-demo) + hipster-shop topology, the
same 12h soak profile, and the same version pins — so the numbers are defensible.

> **Results:** see [`./RESULTS.md`](./RESULTS.md) for the 4-arm comparison matrix, the wire /
> cost economics (mc/1M-spans and wire B/span), and the old-vs-new findings. **TL;DR:** on
> today's releases all four pipelines survive a 12h soak with **loss under 0.01 %** and **flat
> memory**; the two failure modes from the prior benchmark (Fluent Bit mesh SIGSEGV, OTel-Arrow
> dictionary overflow) **no longer reproduce**; and with **every engine compressing the wire**
> (Fluent Bit gzip, Collector zstd, OTAP Arrow+zstd) the wire gap between them collapses to
> ~1.8× — not the 22×+ you see when Fluent Bit ships uncompressed.
>
> **Companion docs:** [`DESIGN.md`](./DESIGN.md) (Fluent-Bit-gzip + parity wiring design) ·
> [`DEPLOYMENT.md`](./DEPLOYMENT.md) (app-deployment parity: appProtocol, ambient + waypoints,
> 100% tracing, benchmark attrs) · [`STEPS.md`](./STEPS.md) (staircase → parity gate → soak →
> KPI).

## The four arms

| Arm | Engine | Transport to backend |
|-----|--------|----------------------|
| `fluentbit` | Fluent Bit 5.1.5 | OTLP/HTTP **+ gzip** (agent→gateway and gateway→backend) |
| `collector` | OTel Collector contrib 0.163.1 (reference) | OTLP/HTTP **+ zstd** |
| `arrow` | df_engine (Rust otap-dataflow) 0.61.0 — OTLP in/out | OTLP |
| `otap` | df_engine 0.61.0 — OTAP (Arrow stream) in → OTLP out; bridge collector exports only df_engine's internal metrics | OTAP edge (Arrow + zstd) → df_engine → backend direct |

> **Wire compression is ON for every arm that can do it.** An earlier run shipped Fluent Bit
> *uncompressed* (~28.5 B/span) while the Collector used zstd and OTAP used Arrow+zstd — so the
> "Fluent Bit is 10–20× fatter on the wire" headline was a compression-config artifact, not an
> engine property. This run turns **gzip ON** on Fluent Bit's OTLP output so all four arms are
> compared like-for-like on the wire. See [`DESIGN.md`](./DESIGN.md).

## Prerequisites

- A Kubernetes cluster (the published runs used v1.35.3, 1 CP + 3× 16 GiB workers) with a default
  StorageClass and a LoadBalancer (e.g. MetalLB).
- `kubectl` pointed at your cluster (`export KUBECONFIG=...`).
- An OTLP-capable backend and its endpoint + token. Copy `dynatrace-secret.example.yaml` to
  `dynatrace-secret.yaml` and fill in **your** endpoint/token (the file is git-ignored; never
  commit real credentials).
- **Measurement purity:** do not wrap the engine-under-test in a vendor agent. If you run a
  backend agent (OneAgent, etc.), exclude the engine pod (`oneagent=false` or equivalent) so it
  isn't instrumented by the thing measuring it.

## One command per arm

```bash
export KUBECONFIG=/path/to/your/kubeconfig

# 1. deploy ONE arm (apps + engine), e.g. the reference collector
./deploy-arm.sh collector          # fluentbit | collector | arrow | otap

# 2. the "strange things" guard — BOTH gates must pass before you trust a run
./validate-app.sh                  # otel-demo is actually working end to end
./validate-gate.sh collector       # engine receives + exports (+ optional backend receipt)

# 3. run load: 50->100->150->200 VU/app rampup, then 12h soak at steady 50 VU/app
#    (load manifests under ./load/ ; adjust to your load tool)

# 4. read KPIs: throughput, loss (accepted==sent), memory tail-flat leak check
./kpi/loss-accounting.sh collector
./kpi/leak-readout.sh collector

# 5. tear down before the next arm (serial, single-engine)
./teardown-arm.sh collector
```

Repeat for each arm. **Never run two engines at once** — contention invalidates the comparison.

## The validation gate (why it exists)

A benchmark is only as honest as its load target. The prior run saw "strange things" — crashes,
suspected silent loss, and (the one that actually fired here) a demo app that was **pod-Running
but shipping telemetry nowhere**. Two scripts turn those fears into hard pre-run checks:

- **`validate-app.sh`** — proves otel-demo works end to end: frontend-proxy is **1/1 (not
  meshed)**, core pages 200, and a full **browse → add-to-cart → checkout** journey returns 2xx/3xx
  with error-rate under 2 %.
- **`validate-gate.sh`** — proves the pipeline works: pods 0-restart, engine **accepted > 0 /
  refused == 0**, engine **exports > 0**, and (optional) the data **lands in your backend**.

> On the reference collector arm, the gate caught `accepted == 0` in seconds — the otel-demo
> Deployments were missing `OTEL_EXPORTER_OTLP_ENDPOINT`, so the apps instrumented fine but
> shipped nowhere. Without the gate, that is a confident, completely wrong benchmark result.

### Optional: backend-receipt check
`validate-gate.sh` step 5 is backend-specific and **off by default**. To enable it, point
`BACKEND_RECEIPT_CMD` at a script that prints a record count for a signal+window:
```bash
export BACKEND_RECEIPT_CMD=./backend-receipt-dynatrace.sh   # you provide this for your backend
./validate-gate.sh collector
```

## The pre-soak PARITY gate (why a healthy engine is not enough)

Beyond the "is the pipeline alive" gate above, a comparison is only valid if **every arm shipped
comparable telemetry**. An under-meshed arm (fewer Istio mesh spans) or an arm whose app emitted
far fewer spans would make its cost-per-span look artificially good. So after the 2h rampup, and
**before** committing to the 12h soak, each arm must clear a **parity gate** measured per
namespace (`otel-demo` and `hipster-shop`) over the rampup window:

1. **App SDK spans + Istio mesh spans + logs** all PRESENT and ramping with load (Spearman
   ρ ≥ 0.8 load-correlation).
2. **Mesh/app span ratio ≈ 72–77 %** — the same mesh coverage profile as the reference df_engine
   arms (C/D). This is the check that caught Arms A/B being *under-meshed* in the first pass and
   forced this re-run.
3. **Per-namespace span + log totals within ±25 %** of the Arm C/D reference window.
4. (Fluent Bit arm) **compression ON** — gateway wire-bytes/span is single-digit, not the ~28.5
   uncompressed figure.

GO → clean up rampup load → start the soak. NO-GO → root-cause (do **not** soak on a non-parity
arm). Full procedure in [`STEPS.md`](./STEPS.md); app-deployment parity wiring in
[`DEPLOYMENT.md`](./DEPLOYMENT.md).

## Methodology (one paragraph)
Serial single-engine; same apps and load every arm; newest-stable version pins frozen on one day;
full logs + metrics + traces; a **50→100→150→200 VU/app staircase** (30 min/step) over a 2h rampup
→ **parity gate** (per-ns app+mesh+logs, ρ ≥ 0.8, mesh ratio 72–77 %, ±25 % vs C/D) → clean →
**12h soak** at steady 50 VU/app → KPI capture. KPIs = throughput, loss (accepted == sent), a
**tail-flat memory leak check**, and the **wire / cost economics** (wire B/span, mc/1M-spans). See
[`STEPS.md`](./STEPS.md) and [`./RESULTS.md`](./RESULTS.md).
