# Results — OpenTelemetry Collector vs Fluent Bit v5

A progressive, signal-stacking benchmark comparing the **OpenTelemetry Collector**
(`contrib v0.159.0`) against **Fluent Bit v5** (`v5.1.1`) as node-level telemetry agents.
Each tier adds one signal on top of the previous one — **logs → +metrics → +traces →
+tail-sampling** — so every row-to-row delta is the *incremental cost of the added signal*.

Every arm was run **one engine at a time** (no side-by-side contention) exporting real
telemetry to a live backend, and each arm passed a **2-hour ramp-up validity gate** before
committing to a **24-hour soak**. This mirrors the two views in the companion Dynatrace
dashboard: a **ramp-up view** (does the pipeline stay healthy while load climbs?) and a
**soak view** (does it stay flat and leak-free for a day under steady load?).

> **Want to reproduce this?** See [`RERUN-GUIDE.md`](./RERUN-GUIDE.md) for the full
> environment, pinned versions, both engine pipelines, the load harness, and the
> step-by-step ramp-up → soak procedure. Version pins are frozen in
> [`../VERSIONS.md`](../VERSIONS.md).

- **Engines under test:** OpenTelemetry Collector-contrib `v0.159.0` vs Fluent Bit `v5.1.1`
  (pins frozen; see `VERSIONS.md`).
- **Cluster:** Kubernetes with Istio 1.29, plus the OpenTelemetry Demo and the Online
  Boutique (hipster-shop) as trace/log sources.
- **Load:** Locust against the OpenTelemetry Demo + k6 against the Online Boutique, ramped
  50 -> 100 -> 150 -> 200 virtual users/app over 2 h, then held at 50 VU/app for the 24 h soak.
- **Validity gate (must be GREEN before a soak counts):** telemetry received at the backend
  **+** pod census clean (engine and infra pods, 0 restarts) **+** load actually reaching the app.
- **KPIs:** throughput (records or spans/sec), CPU (working-set), memory (tail-flat leak
  check), loss (accepted == sent), and cost-per-1M records.

---

## 1. Ramp-up view — 2-hour validity gate (per tier, per engine)

The ramp-up gate is a pass/fail health check as load climbs from 50 to 200 VU/app. Every
arm below passed: the engine stayed up (0 restarts), telemetry kept landing at the backend
with no loss, and load reached the apps. No arm was allowed into a soak without a GREEN gate.

| Tier | Signals | Engine | Ramp-up gate | Peak load reaching app | Loss at peak |
|------|---------|--------|--------------|------------------------|--------------|
| T1 | logs | Collector v0.159.0 | GREEN | 200 VU/app | none |
| T1 | logs | Fluent Bit v5.1.1 | GREEN | 200 VU/app | none |
| T2 | logs+metrics | Collector v0.159.0 | GREEN | 200 VU/app | none |
| T2 | logs+metrics | Fluent Bit v5.1.1 | GREEN | 200 VU/app | none |
| T3 | +traces | Collector v0.159.0 | GREEN | 200 VU/app + 200 span/s | none |
| T3 | +traces | Fluent Bit v5.1.1 | GREEN | 200 VU/app + 200 span/s | none |
| T4 | +tail-sampling | Collector v0.159.0 | GREEN | 200 VU/app + 200 span/s | none |
| T4 | +tail-sampling | Fluent Bit v5.1.1 (no-TS control) | GREEN | 200 VU/app + 200 span/s | none |

Each tier's consolidated per-engine ramp-up + soak KPIs are in `tiers/tierN/tierN-comparison.md`.

---

## 2. Soak view — 24 h+ steady-state (per tier, per engine)

Each arm soaked for 24 h+ at 50 VU/app. The **memory** column is the tail-flat leak check:
we compare the mid-third average against the tail-third average — a flat tail means no leak
or floor-creep. Tail sampling is **collector-only by design** (Fluent Bit has no equivalent
in-pipeline stage), so at Tier 4 Fluent Bit runs the same trace pipeline as Tier 3 and acts
as the no-tail-sampling control.

| Tier | Signals | Engine | Census | Ingest (matched load) | CPU (working-set) | Memory (tail-flat) | Loss | Cost/1M |
|------|---------|--------|--------|-----------------------|-------------------|--------------------|------|---------|
| **T1** | logs | Collector v0.159.0 | PASS 0-restart | ~759 rec/s | **135 m** (3-pod) | ~184 MiB (~61/pod) | NONE | **~2,964 mc/1M** |
| **T1** | logs | Fluent Bit v5.1.1 | PASS 0-restart | ~754 rec/s | **94 m** (3-pod) | **~37 MiB (~12/pod)** | NONE | **~2,079 mc/1M** |
| **T2** | logs+metrics | Collector v0.159.0 | PASS 0-restart | 516 rec/s + 360 dp/s | not snapshotted (see note) | metrics pod **~78 MiB** | NONE | see §4 |
| **T2** | logs+metrics | Fluent Bit v5.1.1 | PASS 0-restart | 503 rec/s + conv | logs ~92 m | metrics pod **~7 MiB** / logs ~36 MiB | NONE | see §4 |
| **T3** | +traces | Collector v0.159.0 | PASS 0-restart (26h) | logs+metrics+traces @200 span/s (gRPC :4317) | **~180 m** (5-pod) | ~337 MiB (5-pod, tail-flat) | 0.011% backend-failed | see note |
| **T3** | +traces | Fluent Bit v5.1.1 | PASS 0-restart (26h) | logs+metrics+traces @200 span/s (HTTP :4318) | **~100 m** (5-pod) | **~200 MiB** (5-pod, tail-flat) | **NONE (0 dropped)** | see note |
| **T4** | +tail-sampling | Collector v0.159.0 | PASS 0-restart | logs+metrics+traces @200 span/s (gRPC :4317) + tail_sampling | **~165 m** (5-pod) | **~413 MiB** (5-pod, tail-flat +0.00%) | <=0.005% refused+failed | see note |
| **T4** | +tail-sampling | Fluent Bit v5.1.1 (no-TS control) | PASS 0-restart | logs+metrics+traces @200 span/s (HTTP :4318), no TS stage | **~143 m** (5-pod) | **~198 MiB** (5-pod, tail-flat +1.81%) | **NONE (0 dropped)** | see note |

**Note (T2 CPU):** both arms captured a memory plateau (the leak readout) but a symmetric
per-pod CPU snapshot was only taken on the Fluent Bit arm, so the T2 cost/1M line is not
reproduced like-for-like; the T2 cost finding is carried by the metrics-pipeline **memory**
delta (§4).

**Note (T3/T4 cost/1M):** deliberately omitted rather than fabricated. The two engines'
backend record counts diverge for reasons that are *counting artifacts, not efficiency*: the
collector's exporter fan-out inflates its `sent` count ~1.885x, its metrics arm emits
per-datapoint while Fluent Bit emits per-scrape-event, and Fluent Bit's trace input is
HTTP-only. Normalizing CPU against those non-like-for-like volumes would *reverse* the
verdict purely on the fan-out artifact — so the trace-tier cost finding is carried by the
**resource delta** (CPU/mem, §5).

---

## 3. Incremental cost of each added signal

- **Baseline — logs only (T1):** both engines are cheap and leak-free over 24–26 h. Fluent
  Bit is the lighter logs engine: **~30% lower CPU, ~5x lower memory, ~30% lower cost-per-1M**
  at matched ~755 rec/s.
- **+metrics (T1 -> T2):** the added signal is a high-cardinality control-plane + Kepler
  power scrape on a dedicated metrics pipeline. This is where the engines diverge most: the
  collector metrics pipeline (prometheus -> cumulative-to-delta -> drop-summary -> OTLP) sits
  at a **~78 MiB tail-flat plateau**, while Fluent Bit's native metric conversion holds
  **~7 MiB / 2 m CPU** at comparable ingest — **~11x memory advantage for Fluent Bit on the
  metrics arm.** Neither leaks under the Kepler stressor. Caveat: the two metrics pipelines
  are not architecturally identical, so this is a cost-of-the-shipped-config comparison, not
  a like-for-like transform.
- **+traces (T2 -> T3):** adding the OTLP trace path (@200 span/s + app spans). Fluent Bit
  holds its lightness advantage: **~200 MiB vs ~337 MiB (5-pod), ~100 m vs ~180 m CPU** at
  T+24 h — **~41% lighter memory, ~44% lighter CPU** — with **zero dropped** vs the
  collector's small but non-zero loss (0.011% backend-failed). Both soaked 26 h census-clean
  and tail-flat. Two deployment-shape caveats, not performance differentiators: (1) Fluent
  Bit's trace input is **HTTP :4318 only** (no gRPC), vs the collector's native gRPC :4317;
  (2) the collector's trace pod ran heaviest of its components — the one place its richer
  pipeline is competitive on the trace arm specifically.
- **+tail-sampling (T3 -> T4):** **collector-only stage, and the most expensive single add of
  the ladder.** The tail-sampling processor (keep-errors OR 30% probabilistic non-health,
  `decision_wait=10s`, `num_traces=100000`) is a **stateful** stage that buffers trace
  windows before deciding. Cost on the collector: the trace pod goes **53 MiB -> 152 MiB
  (~2.9x)** vs its T3 no-TS shape, pushing the 5-pod aggregate to **~413 MiB** (+76 MiB ~= the
  tail-sampling add) while total CPU stays roughly flat (~165 m). The decision buffer rode its
  `num_traces=100000` cap the whole soak — sized at the limit, not beyond it, and still
  tail-flat (+0.00%, the flattest run of the whole benchmark). Fluent Bit has no equivalent;
  its T4 control arm is its T3 shape plus soak drift (~198 MiB, +1.81%, still tail-flat, 0
  dropped). **Verdict: tail sampling costs the collector ~2.9x trace-pod memory (~76 MiB per
  pipeline, ~+23% of the 5-pod aggregate); Fluent Bit cannot do it at all** — if you need
  in-pipeline tail sampling, that capability premium is what you pay.

---

## 4. Tier-2 headline — the Kepler high-cardinality cost delta

The metrics pipeline is where each engine absorbs the expensive scrape. Collector metrics
pipeline **~78 MiB tail-flat** vs Fluent Bit metrics pod **~7 MiB / 2 m CPU** -> **~11x
lighter for Fluent Bit on the metrics arm.** Both engines received logs+metrics at the
backend with **0 send-failures / 0 errors**; both tail-flat, no loss (the collector's
`sent < accepted` is expected — cumulative-to-delta drops the first sample per series, plus
drop-summary). Full table: `tiers/tier2/tier2-comparison.md`.

---

## 5. Verdict, per tier

- **T1 (logs):** both PASS all validity + KPI gates. **Fluent Bit lighter** (~30% CPU,
  ~5x mem, ~30% cost/1M).
- **T2 (logs+metrics):** both PASS. **Fluent Bit lighter, gap widest on the metrics arm
  (~11x mem).**
- **T3 (+traces):** both PASS, 26 h census-clean, both tail-flat. **Fluent Bit lighter**
  (~41% mem, ~44% CPU) **with zero loss**; collector had small non-zero loss (0.011%
  backend-failed). Trace ingress differs by design (Fluent Bit HTTP :4318-only vs collector
  gRPC :4317) — a deployment choice, not a perf gap.
- **T4 (+tail-sampling):** both arms PASS, 26 h+ census-clean, both tail-flat (collector
  +0.00% — flattest of the benchmark; Fluent Bit control +1.81%). **Fluent Bit lighter
  overall** (~198 MiB vs ~413 MiB 5-pod; CPU ~143 m vs ~165 m) with **zero loss**. **But T4
  is the capability tier:** only the collector can tail-sample in-pipeline, and that
  capability costs ~2.9x trace-pod memory with the decision buffer pinned at its 100k-trace cap.
- **Cross-tier final ranking (T1–T4):** Fluent Bit v5 is consistently the lighter engine —
  logs (~5x mem), logs+metrics (~11x mem on the metrics arm), logs+metrics+traces (~41% mem /
  ~44% CPU), and the T4 control (~2.1x mem). **The ranking is stable across the whole ladder:
  Fluent Bit stays lighter at every tier.** No memory leak in either engine at any tier
  (tail-flat everywhere, <=1.81% drift). Fluent Bit hit the backend with **zero loss at every
  tier**; the collector was loss-free through T2 and had a small non-zero loss at T3/T4
  (<=0.011% backend-failed / <=0.005% refused+failed). **Capability differentiator:** native
  gRPC trace ingress, per-datapoint metrics, and in-pipeline tail sampling are collector-only
  — the tail-sampling premium (~+76 MiB/pipeline) is the price of that stage.

---

## 6. Dashboards

Two views are provided to match how the runs were actually monitored:

- **Static results page** — [`results.html`](./results.html), a self-contained dark-mode
  page you can open in any browser (no backend needed). It renders the soak + ramp-up
  summary above.
- **Importable Dynatrace dashboard** — [`../dashboards/fluentbit-vs-collector-benchmark.dashboard.json`](../dashboards/fluentbit-vs-collector-benchmark.dashboard.json).
  Import it into your own Dynatrace tenant (the cluster name is parameterized as a
  `$K8sCluster` variable). It combines a soak/results style (retention-proof summary tiles)
  with a compare style (live line-charts overlaying each engine's run aligned by relative
  interval).

---

## 7. Provenance (source data)

Each tier's per-engine comparison table:

- **T1 (logs):** `tiers/tier1/tier1-comparison.md` · configs `tiers/tier1/collector-tier1-logs-only.yaml`, `tiers/tier1/fluentbit-tier1-logs-only.conf`
- **T2 (logs+metrics):** `tiers/tier2/tier2-comparison.md` (metrics pipelines wired in `manifests/20-collector-daemonset.yaml` / `manifests/30-fluentbit-daemonset.yaml`)
- **T3 (+traces):** `tiers/tier3/tier3-comparison.md` · configs `tiers/tier3/collector-tier3.yaml`, `tiers/tier3/fluentbit-tier3.yaml`
- **T4 (+tail-sampling):** `tiers/tier4/tier4-comparison.md` · configs `tiers/tier4/collector-tier4.yaml` (T3 + `tail_sampling`), `tiers/tier4/fluentbit-tier4.yaml`
- Version pins: `../VERSIONS.md`. Architecture: `ARCHITECTURE.md`. Reproduce: `RERUN-GUIDE.md`.
