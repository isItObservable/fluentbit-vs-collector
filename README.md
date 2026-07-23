# Fluent Bit v5 vs OpenTelemetry Collector vs OTel-Arrow — a reproducible benchmark

<img src="image/logo.png" width="120" align="right" alt="Is It Observable">

**What this measures:** how much CPU and memory three different telemetry
engines burn to ingest and forward the *same* traces, logs and metrics from the
*same* two applications to the *same* Dynatrace tenant, over an identical
120-minute load profile.

**The topology is deliberately flat:**

```
  otel-demo  ─┐                            ┌─ traces
              ├─→  ONE engine under test ──┼─ logs      →  Dynatrace (OTLP)
  hipster-shop┘        (one at a time)     └─ metrics
        │
        └── Istio sidecars → mesh spans + access logs → the same engine
```

There is **no gateway** and **no second hop**. Apps and Istio send OTLP
straight to the engine under test; the engine exports straight to Dynatrace.
The engine is the only configured variable. Earlier revisions of this benchmark
put a gateway between the two — that design is gone, and any document that
describes an "edge → gateway hop" is describing the old one.

| Arm | Engine | Image |
|-----|--------|-------|
| **P1** | OpenTelemetry Collector (contrib) | `otel/opentelemetry-collector-contrib:0.154.0` |
| **P2** | Fluent Bit v5 | `fluent/fluent-bit:5.0.9` |
| **P3** | OTel-Arrow native (`df_engine` / otap-dataflow, Rust) | `ghcr.io/isitobservable/df_engine:0.50.0` |

One arm runs at a time. A round is all three arms; the campaign is two rounds,
so every number gets a replication.

---

## Headline result so far

Round 1, collector vs Fluent Bit v5, over two equal 120-minute windows:

> **Fluent Bit v5 spends ~36% less CPU per record than the OpenTelemetry
> Collector, and ~20% more memory per record** (peak working set +59%).

It is a **trade, not a win**. Quoting only the CPU column — or quoting the
*absolute* CPU delta of −38.6%, which credits Fluent Bit for ~3.5% of records it
was never handed — overstates the result. Full numbers, caveats and the two
disclosures that qualify them are in **[results/RESULTS.md](results/RESULTS.md)**.

The third arm (OTel-Arrow native) **has not produced a valid run**:
`df_engine:0.50.0` panicked on all four pipeline cores within a minute of start,
while still reporting `Ready` with zero restarts. See
[results/RESULTS.md](results/RESULTS.md#p3--otel-arrow-native--no-valid-run).

---

## Reproduce it

Four documents, in order. Each one ends where the next one starts.

| | |
|---|---|
| **[docs/01-provision-cluster.md](docs/01-provision-cluster.md)** | what the cluster must look like, and how to check yours qualifies |
| **[docs/02-deploy-environment.md](docs/02-deploy-environment.md)** | Dynatrace, Istio, the apps, the engine — one arm, end to end |
| **[docs/03-run-benchmark.md](docs/03-run-benchmark.md)** | the gate, the 120-minute run, the census, the teardown |
| **[docs/04-read-results.md](docs/04-read-results.md)** | how to turn a window into numbers you can defend |

Short version, once `.env` is filled in:

```bash
cp .env.example .env && $EDITOR .env
set -a && . ./.env && set +a

./cluster/preflight.sh                      # does this cluster qualify?
ENGINE=otel-collector ./deploy/deploy-arm.sh   # engine + apps + Istio + labels
./benchmark/validate-phase.sh $ENGINE --window 15m   # 6-check gate — must be green
kubectl apply -f loadtest/ramp-jobs-$ENGINE.yaml     # the 120-minute timed run
# ... 120 minutes ...
./benchmark/capture-window.sh R1-P1-collector       # End, from Kubernetes
./benchmark/pod-census.sh    R1-P1-collector end    # validity gate
./benchmark/readout.sh       R1-P1-collector <start> <end>
./benchmark/teardown.sh      R1-P1-collector        # dry run; --confirm to delete
```

## Layout

```
cluster/      preflight.sh — refuses a cluster that cannot host a valid run
deploy/       ONE source of truth per component
  _templates/   the per-arm files are RENDERED from these; edit here, not there
  render.sh     regenerates engines/apps/istio artifacts for all three arms
  engines/      the three engines under test
  apps/         otel-demo Helm values + a resolved Online Boutique manifest
  istio/        istiod values + Telemetry CRs (tracing + access logs only)
  dynatrace/    DynaKube
  deploy-arm.sh deploy one arm in the one order that works
loadtest/     the 120-minute ramp Jobs — one file per arm, identical modulo name
benchmark/    validate-phase.sh · attr-landing.sh · capture-window.sh
              pod-census.sh · readout.sh · normalise.sh · teardown.sh
results/      RESULTS.md · RUN-REGISTER.md · the Dynatrace dashboard JSON
publication-scrub.sh   the gate that keeps this branch publishable
```

**Edit `deploy/_templates/`, not the rendered files.** `deploy/render.sh`
regenerates all twelve per-arm artifacts; `./deploy/render.sh --check` fails if
a committed file has drifted. A hand-edit to a rendered file survives until
someone re-renders, and then vanishes — silently, mid-campaign, in a file
nobody was looking at.

## Requirements

- A Kubernetes cluster that meets [docs/01](docs/01-provision-cluster.md) — in
  practice 3 workers × 4 vCPU / 12 GiB or better.
- `kubectl`, `helm`, `python3` (with `pyyaml`), and Dynatrace
  [`dtctl`](https://github.com/dynatrace/dtctl) for the read side.
- A Dynatrace environment with an OTLP ingest token. The token lives in a
  Kubernetes Secret; it is never written to this repo. Grep the tree — the only
  matches are `${DT_API_TOKEN}`, `__DT_API_TOKEN__` and `secretKeyRef`.

## Branches

| branch | what it is |
|--------|------------|
| `master` | the original *Fluent Bit vs OpenTelemetry Collector* tutorial |
| `collector-vs-fluentbitv5` | **this branch** — the advanced engine benchmark |

## Scope limits, stated up front

- **No tail sampling, no Prometheus scraping.** Istio/Envoy Prometheus metrics
  are excluded from every run — no Prometheus receiver, no ServiceMonitor, no
  Envoy scrape, in any arm. Istio *spans* and *access logs* are in scope; so are
  app-emitted OTLP metrics.
- **Every ratio must state its baseline.** "~2× leaner on the wire" against
  OTLP+zstd and "~23×" against uncompressed OTLP are the same measurement with
  different denominators. An unlabelled ratio is not a result.
- **One run per arm so far.** Round 2 exists to replicate Round 1. Until it has
  run, treat every figure here as a single observation.
