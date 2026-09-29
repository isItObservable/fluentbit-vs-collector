# Re-run guide — reproduce the Collector vs Fluent Bit benchmark

This guide lets you reproduce the whole benchmark end to end: stand up both engines,
apply the per-tier pipelines, drive the load, run each arm through the **2-hour ramp-up
validity gate → 24-hour soak**, and read out the same KPIs used in
[`RESULTS.md`](./RESULTS.md).

The benchmark is **serial single-engine**: only one engine is live at a time. You deploy an
engine, validate it, run its ramp-up gate and soak, tear it down, then repeat for the other
engine. Running them side by side would let them contend for the same node resources and
invalidate the comparison.

---

## 1. Environment

### 1.1 Cluster prerequisites

| Requirement | What the benchmark used | Notes |
|-------------|-------------------------|-------|
| Kubernetes | 3 worker nodes with headroom | Any conformant cluster; enough CPU/RAM to hold both apps + Kepler + the engine under test. |
| Service mesh | **Istio 1.29** | Traces/logs traverse the real mesh (this is deliberate — the export hop over the mesh is part of what is measured). |
| Trace/log source apps | **OpenTelemetry Demo** + **Online Boutique (hipster-shop)** | Provide realistic multi-service logs and OTLP spans. |
| Power/metrics stressor | **Kepler `release-0.8.0`** (Helm chart `kepler/kepler` `0.6.2`) | A deliberately expensive, high-cardinality metric source (~755 series/pod on `:9102`). Kepler 0.9+ has breaking config changes; pin `release-0.8.0`. |
| Telemetry backend | Dynatrace (Grail) via OTLP | Any OTLP backend works; the validity gate is "signal received at the backend". |

> Isolation rule: label the engine namespaces so your backend's node agent does **not**
> inject/wrap the engine under test — measuring an agent that is itself wrapped by another
> agent invalidates the CPU/memory numbers. In this benchmark the namespaces carry
> `oneagent: "false"` and the Dynatrace OneAgent observes the node, not the pod.

### 1.2 Pinned versions

Frozen for the whole benchmark — **do not bump mid-run** (version drift across tiers
invalidates the comparison). Full table and provenance in [`../VERSIONS.md`](../VERSIONS.md).

| Component | Pinned tag | Image |
|-----------|-----------|-------|
| OpenTelemetry Collector-contrib | `v0.159.0` | `otel/opentelemetry-collector-contrib:0.159.0` |
| Fluent Bit | `v5.1.1` | `fluent/fluent-bit:5.1.1` |
| Kepler | `release-0.8.0` | `quay.io/sustainable_computing_io/kepler:release-0.8.0` |

### 1.3 Backend credentials

Both engines export to an OTLP endpoint of the form
`https://YOUR_TENANT.live.dynatrace.com/api/v2/otlp/v1/{logs,metrics,traces}` and read the
token from an environment variable `DT_API_TOKEN` sourced from a Kubernetes secret `dt-otlp`.
Replace `YOUR_TENANT` in the config files with your own environment ID and create the secret:

```sh
kubectl -n bench-collector create secret generic dt-otlp --from-literal=DT_API_TOKEN='dt0c01.XXXX...'
kubectl -n bench-fluentbit create secret generic dt-otlp --from-literal=DT_API_TOKEN='dt0c01.XXXX...'
```

The token needs `openTelemetryTrace.ingest`, `metrics.ingest`, and `logs.ingest` scopes.

---

## 2. Observability pipeline configs (both engines, per tier)

Each tier **adds one signal** to the tier below it. Configs live under `tiers/tierN/`; the
shared base (namespaces + DaemonSet skeletons) is under `manifests/`.

| Tier | Signals | Collector config | Fluent Bit config |
|------|---------|------------------|-------------------|
| **T1** | logs | `tiers/tier1/collector-tier1-logs-only.yaml` | `tiers/tier1/fluentbit-tier1-logs-only.conf` |
| **T2** | logs + metrics | T1 + the metrics pipeline in `manifests/20-collector-daemonset.yaml` (StatefulSet: `prometheus` receiver → `cumulativetodelta` → drop-summary → OTLP) | T1 + the metrics pipeline in `manifests/30-fluentbit-daemonset.yaml` (`prometheus_scrape` input + native **metric conversion** path) |
| **T3** | + traces | `tiers/tier3/collector-tier3.yaml` | `tiers/tier3/fluentbit-tier3.yaml` |
| **T4** | + tail-sampling | `tiers/tier4/collector-tier4.yaml` (T3 + `tail_sampling` processor) | `tiers/tier4/fluentbit-tier4.yaml` — **note:** in the first pass this arm ran *without* a sampling stage; Fluent Bit v5 does support tail sampling (`sampling` `type: tail`) and a like-for-like re-run with both engines sampling is in progress (see `RESULTS.md` erratum) |

### 2.1 What each pipeline does

- **Logs** — node-level tail of `/var/log/pods/**`. Collector: `filelog` receiver on a
  DaemonSet. Fluent Bit: native `tail` input on a DaemonSet.
- **Metrics** — scrape the Istio control plane (`istiod :15014/metrics`) and **Kepler**
  (`:9102/metrics`). Collector: `prometheus` receiver → `cumulativetodelta` (Grail wants
  delta) → drop-summary → OTLP. Fluent Bit: `prometheus_scrape` input → native metric
  conversion → OTLP. These two metrics paths are **not architecturally identical**, so the
  metrics-tier result is a cost-of-the-shipped-config comparison, not a like-for-like
  transform benchmark.
- **Traces** — the OpenTelemetry Demo and Online Boutique export OTLP spans to the engine.
  The collector accepts **gRPC `:4317` and HTTP `:4318`**; **Fluent Bit accepts OTLP/HTTP
  `:4318` only** (no gRPC trace ingress), so on the Fluent Bit arm the apps must export
  OTLP/HTTP.
- **Tail sampling (T4)** — the collector uses a `tail_sampling` processor with policy
  `keep-errors OR (NOT healthcheck AND 30% probabilistic)`, `decision_wait=10s`,
  `num_traces=100000`. It is **stateful** — it buffers trace windows in memory before
  deciding — which is why it is the single most expensive add of the ladder.

### 2.2 Config gotchas worth knowing before you start

- **Collector `v0.159.0` telemetry schema** — `service.telemetry.metrics.address` was
  removed; the collector crashes with `'migration.MetricsConfigV030' has invalid keys:
  address`. Use the reader form instead:
  `service.telemetry.metrics.readers:[{pull:{exporter:{prometheus:{host,port}}}}]`
  (already applied in the committed configs).
- **Collector `v0.159.0`** deprecates `k8sattributes` in favour of `k8s_attributes`
  (warning only).
- **Fluent Bit `prometheus_scrape` buffer** — Kepler's ~223 KB high-cardinality payload
  exceeds Fluent Bit's default 32 KB scrape buffer and gets **truncated**
  (`cannot increase buffer: ... max=32000`). Raise `buffer_max_size` on the
  `prometheus_scrape` input (the committed T2+ configs set `buffer_max_size 1M`). Note
  `buffer_chunk_size` is rejected on this input in v5.1.1 — only `buffer_max_size` is valid.
- **Fluent Bit v5 mesh stability** — earlier v5.x releases had a reproducible SIGSEGV on the
  HTTP/2 export hop over the mesh that only surfaces on a multi-hour soak (not a short
  smoke). The 24-hour Tier-1 soak over the real mesh is the gate that confirms your pinned
  build is stable; treat a crash as a first-class benchmark finding, not a reason to abandon
  the arm. `http2: off` is not a viable production mitigation.

---

## 3. Load harness

The load has two parts, both pointed at the engine currently under test:

1. **Application traffic** — Locust against the OpenTelemetry Demo + k6 against the Online
   Boutique. Ramp **50 → 100 → 150 → 200 virtual users/app over 2 h** for the ramp-up gate,
   then hold **50 VU/app** for the 24 h soak.
2. **Raw signal rate** — `telemetrygen` at **200 spans/s** (and metrics), defined in
   `harness/telemetrygen-load.yaml` and driven by `harness/run-profile.sh`.

`run-profile.sh` renders the generators for the chosen arm and **always enforces a hard
`kubectl delete` backstop** at `T + duration + 120 s`, regardless of the generator's own
duration flag — a generator that ignores its duration flag can otherwise over-run the window
and skew the tail. Use **standard `telemetrygen` framing over the real mesh** (not
slowloris-style framing, which is not the real failure path).

```sh
# ramp-up (2 h validity gate) for the collector arm:
./harness/run-profile.sh 2h-rampup collector
# soak (24 h) for the collector arm:
./harness/run-profile.sh 24h-stable collector
# ... later, after teardown, the same two for the fluentbit arm:
./harness/run-profile.sh 2h-rampup  fluentbit
./harness/run-profile.sh 24h-stable fluentbit
```

---

## 4. KPI readout

Scripts live in `kpi/` (`KUBECONFIG` defaults to `$HOME/.kube/config`). **Run
`census-gate.sh` first** — every other readout is invalid if the census gate fails.

| Script | Purpose |
|--------|---------|
| `kpi/census-gate.sh [ns...]` | Validity gate: per-namespace, per-pod `phase==Running && restarts==0`. A "PASS" with restarts is invalid — assert **per-pod**, not aggregate. |
| `kpi/loss-accounting.sh <collector\|fluentbit>` | Loss = `refused==0 && send_failed==0`. Note `sent > accepted` on the collector is exporter fan-out, **not** negative loss — do not compute `1 − sent/accepted`. |
| `kpi/leak-readout.sh <arm> [samples] [iv]` | Memory trend. Verdict = **tail-flat** (last-third vs mid-third drift), not first-vs-last: warm-up floor-creep to a plateau is normal. |
| `kpi/cost-per-1m.sh <arm> [window_s]` | Headline unit: millicores per 1M records (`mc/1M`). |

For 24-hour sustained averages read your backend's history (the KPI scripts are live
oracles; backend history survives cluster teardown and is readable well after the run).

---

## 5. Full procedure (per tier, both engines)

For each tier `N` in `1..4`, and for each engine arm:

1. **Deploy the base** — `kubectl apply -f manifests/00-namespaces.yaml` then the engine's
   DaemonSet (`manifests/20-collector-daemonset.yaml` or `manifests/30-fluentbit-daemonset.yaml`),
   plus the tier config from the table in §2. Make sure the `dt-otlp` secret exists (§1.3).
2. **Census gate** — `./kpi/census-gate.sh bench-collector` (or `bench-fluentbit`) + the
   Kepler namespace. Expect all engine + infra pods `Running`, 0 restarts.
3. **Ramp-up gate (2 h)** — `./harness/run-profile.sh 2h-rampup <arm>`. The gate is GREEN
   only if: telemetry is **received at the backend**, census stays 0-restart, and load
   reaches the apps. No arm proceeds to a soak without a GREEN gate.
4. **Soak (24 h)** — `./harness/run-profile.sh 24h-stable <arm>`. During the soak, sample
   `leak-readout.sh` and `loss-accounting.sh`.
5. **Read out** — census PASS, loss (`accepted == sent`), memory tail-flat drift, CPU
   working-set, and `cost-per-1m.sh`. Record them in `tiers/tierN/tierN-<arm>-results.md`.
6. **Tear down** — delete the engine namespace and the load generators before deploying the
   other engine (serial single-engine). Then repeat steps 1–5 for the other arm.
7. **Compare** — fold both arms into `tiers/tierN/tierN-comparison.md`, then into
   [`RESULTS.md`](./RESULTS.md).

Tier 4 is collector-plus-`tail_sampling` vs a Fluent Bit no-tail-sampling control: the
headline is the collector's Tier-3 → Tier-4 trace-pod memory delta (the tail-sampling cost).

---

## 6. Dashboards

- **Static results page** — [`results.html`](./results.html): open it in any browser, no
  backend needed.
- **Importable Dynatrace dashboard** —
  [`../dashboards/fluentbit-vs-collector-benchmark.dashboard.json`](../dashboards/fluentbit-vs-collector-benchmark.dashboard.json).
  Import it into your own tenant; the cluster name is parameterized as a `$K8sCluster`
  variable, so it renders the ramp-up and soak views against your own Grail data.
