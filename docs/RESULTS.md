# RESULTS — Extended benchmark: latest otel-collector vs Fluent Bit v5

> **Status: ALL FOUR TIERS COMPLETE AND CONSOLIDATED (E5 / ISI-3579).** Tiers **E1 (logs)**,
> **E2 (logs+metrics)**, **E3 (+traces)** and **E4 (+tail-sampling)** are all complete and folded in
> below. Doc is final pending PR. GitHub push is separately gated on the E0 branch remote + PAT
> (ISI-3574, coordinate with BigBoss).

**Epic:** ISI-3572 (follow-on to ISI-1779). **Engines under test:** OpenTelemetry Collector-contrib
`v0.159.0` vs Fluent Bit `v5.1.1` (pins frozen 2026-09-02, `VERSIONS.md`). **Cluster:**
`observable-otelarrow` (ISI-1777), Istio 1.29, otel-demo + hipster-shop load.
**Methodology:** pt9 serial single-engine — one engine live at a time, exporting real signals to
Dynatrace; validity gate = signal RECEIVED IN DYNATRACE + census PASS (engine+infra 0-restart) +
load reaching app. Every arm ran a **2h rampup validity gate (GREEN required) → 24h+ soak**.

---

## 1. Progressive signal-stack: per-tier, per-engine summary

Each tier ADDS a signal to the tier below it (logs → +metrics → +traces → +tail-sampling), so the
row-to-row delta is the **incremental cost of the added signal**. Tail-sampling is collector-only by
design (FB has no equivalent stage → FB is the no-TS control for Tier 4; see VERSIONS scoping).

| Tier | Signals | Engine | Census | Ingest (matched load) | CPU (working-set) | Memory (tail-flat) | Loss | DT receipt | Cost/1M |
|------|---------|--------|--------|-----------------------|-------------------|--------------------|------|------------|---------|
| **T1** | logs | collector v0.159.0 | PASS 0-restart | ~759 rec/s | **135 m** (3-pod) | ~184 MiB (~61/pod) | NONE | 0 send_failed | **~2,964 mc/1M** |
| **T1** | logs | Fluent Bit v5.1.1 | PASS 0-restart | ~754 rec/s | **94 m** (3-pod) | **~37 MiB (~12/pod)** | NONE | 0 dropped | **~2,079 mc/1M** |
| **T2** | logs+metrics | collector v0.159.0 | PASS 0-restart | 516 rec/s + 360 dp/s | not snapshotted† | metrics STS **~78 MiB** | NONE | 0 send_failed (logs+metrics) | see §3 |
| **T2** | logs+metrics | Fluent Bit v5.1.1 | PASS 0-restart | 503 rec/s + conv | logs ~92 m | metrics pod **~7 MiB** / logs ~36 MiB | NONE | 0 errors | see §3 |
| **T3** | +traces | collector v0.159.0 | PASS 0-restart (26h) | logs+metrics+traces @200 span/s (gRPC :4317) | **~180 m** (5-pod) | ~337 MiB (5-pod, tail-flat) | refused 0.006% / send_failed 0.0018% | 166.5M sent / 8,000 failed (0.011%) | see note‡ |
| **T3** | +traces | Fluent Bit v5.1.1 | PASS 0-restart (26h) | logs+metrics+traces @200 span/s (HTTP :4318) | **~100 m est** (5-pod) | **~200 MiB** (5-pod, tail-flat) | **NONE (0 dropped)** | 80.4M proc / 0 dropped | see note‡ |
| **T4** | +tail-sampling | collector v0.159.0 | PASS 0-restart | logs+metrics+traces @200 span/s (gRPC :4317) + tail_sampling | **~165 m** (5-pod: 50+30+47+11+27) | **~413 MiB** (5-pod: 62+59+60+81+152, tail-flat +0.00%) | refused 0.005% / send_failed 0.0013% | 126.6M sent / 0 send_failed | see note‡ |
| **T4** | +tail-sampling | Fluent Bit v5.1.1 (no-TS control) | PASS 0-restart | logs+metrics+traces @200 span/s (HTTP :4318), no TS stage | **~143 m** (5-pod: 66+19+16+3+39) | **~198 MiB** (5-pod: 17+14+8+9+150, tail-flat +1.81%) | **NONE (0 dropped)** | 71.1M proc / 0 dropped | see note‡ |

† T2 collector arm captured a **memory** plateau on both arms (the leak readout) but a symmetric
per-pod CPU snapshot was only taken on the FB arm, so the T2 cost/1M line is not reproduced like-for-like;
the T2 cost finding is carried by the metrics-pipeline **memory** delta (§3). Namespaces are torn down →
not re-measurable without a re-run.

‡ T3 cost/1M is **not cross-comparable** and is deliberately omitted rather than fabricated. The two
engines' DT-receipt record counts (collector 166.5M vs FB 80.4M over 26h) diverge for reasons that are
*counting artifacts, not efficiency*: the collector's exporter fan-out inflates its `sent` count 1.885×,
its metrics arm emits per-datapoint while FB emits per-scrape-event (30.8M vs 12.5K — §5.3 of the tier
doc), and FB's trace INPUT is HTTP-only (gRPC N/A). Normalizing CPU against these non-like-for-like
volumes would *reverse* the verdict purely on the fan-out artifact — so the T3 cost finding is carried by
the **resource delta** (CPU/mem, §4), consistent with the ISI-1779 methodology. FB is ~41% lighter on
memory and ~44% lighter on CPU at the full signal set with zero loss.

---

## 2. Incremental cost of each added signal (progressive-cost narrative)

The whole point of the tier ladder: what does each additional signal COST on each engine?

- **Baseline — logs only (T1):** both engines are cheap and leak-free over 24–26h. Fluent Bit is the
  lighter logs engine: **~30% lower CPU, ~5× lower memory, ~30% lower cost-per-1M** at matched
  ~755 rec/s. Direction matches the ISI-1779 clean 3-engine benchmark (fluentbit < collector on mc/1M).
- **+metrics (T1→T2):** the added signal is a high-cardinality istiod-CP + Kepler scrape landing on a
  dedicated metrics StatefulSet. This is where the engines diverge most: the collector metrics
  pipeline (prometheus → cumulativetodelta → drop-summary → OTLP) sits at a **~78 MiB tail-flat
  plateau**, while Fluent Bit's native metric-conversion metrics pod holds **~7 MiB / 2 m CPU** at
  comparable ingest — **~11× memory advantage for Fluent Bit on the metrics arm.** Neither leaks under
  the Kepler stressor (both tail-flat, sub-2% drift). Caveat: the two metrics pipelines are not
  architecturally identical (collector does server-side cumulative→delta + summary-drop; FB uses
  native conversion) → this is a cost-of-the-shipped-config comparison, not a like-for-like transform.
- **+traces (T2→T3):** adding the OTLP trace path (@200 span/s telemetrygen + otel-demo/hipster-shop
  app spans) on a dedicated traces Deployment. **Fluent Bit holds its lightness advantage:** ~200 MiB
  vs ~337 MiB (5-pod), ~100 m vs ~180 m CPU at T+24h — **~41% lighter memory, ~44% lighter CPU** — with
  **zero dropped** vs the collector's small but non-zero loss (refused 0.006% / send_failed 0.0018% /
  8,000 DT-failed of 166.5M = 0.011%). Both engines soaked 26h census-clean (0 engine restarts) and
  tail-flat. Two deployment-shape caveats, not performance differentiators: (1) FB's trace INPUT is
  **HTTP :4318 only** (no gRPC), vs the collector's native gRPC :4317; (2) the collector's FB traces
  pod ran heaviest of the FB components (~146 MiB at T+2h) — the one place the collector's richer
  pipeline is competitive on the trace arm specifically.
- **+tail-sampling (T3→T4):** **collector-only stage, and the most expensive single add of the
  ladder.** The tailsampling processor (keep-errors OR 30% probabilistic non-health, decision_wait=10s,
  num_traces=100000) is a **stateful** stage: it buffers trace windows before deciding. Cost on the
  collector: the traces pod goes **53 MiB → 152 MiB (~2.9×)** vs its T3 no-TS shape, pushing the 5-pod
  aggregate to **~413 MiB** (vs ~337 MiB at T3, +76 MiB ≈ the tail-sampling add) while total CPU is
  roughly flat (~165 m). The decision buffer rode its `num_traces=100000` cap the whole soak with
  `sampling_traces_on_memory=100000` — sized at the limit, not beyond it, and still tail-flat (+0.00%,
  the flattest run of the whole benchmark). Sampling stats: 37.5M new trace IDs, 11.2M sampled / 26.2M
  not-sampled under the 30% policy, 37.5M not-sampled under keep-errors. On the FB side there is no
  equivalent — its T4 control arm is its T3 shape plus 3 more days of soak drift (**~198 MiB, +1.81%**,
  still tail-flat, 0 dropped). **Verdict: tail sampling costs the collector ~2.9× traces-pod memory
  (76 MiB/pipeline, ~+23% 5-pod aggregate); FB cannot do it at all** — if you need in-pipeline tail
  sampling, that capability premium is what you pay.

---

## 3. Tier-2 headline — the Kepler high-cardinality cost delta

The metrics StatefulSet is where each engine absorbs the expensive scrape. Collector metrics pipeline
**~78 MiB tail-flat** vs Fluent Bit metrics pod **~7 MiB / 2 m CPU** → **~11× lighter for Fluent Bit
on the metrics arm.** Both engines DT-received logs+metrics with **0 send_failed / 0 errors**; both
tail-flat, no loss (metrics sent<accepted on collector is EXPECTED — cumulative→delta drops the first
sample/series + drop-summary, ISI-1843). Full table: `tiers/tier2/tier2-comparison.md`.

---

## 4. Collector-vs-Fluent-Bit verdict, per tier

- **T1 (logs):** ✅ both PASS all validity+KPI gates. **Fluent Bit lighter** (~30% CPU, ~5× mem, ~30% cost/1M).
- **T2 (logs+metrics):** ✅ both PASS. **Fluent Bit lighter, gap widest on the metrics arm (~11× mem).**
- **T3 (+traces):** ✅ both PASS all validity gates, 26h census-clean, both tail-flat. **Fluent Bit
  lighter** (~41% mem, ~44% CPU) **with zero loss**; collector had small non-zero loss (0.011% DT-failed).
  Trace ingress differs by design (FB HTTP :4318-only vs collector gRPC :4317) — a deployment choice, not
  a perf gap.
- **T4 (+tail-sampling):** ✅ both arms PASS all validity gates, 26h+ census-clean, both tail-flat
  (collector +0.00% — flattest of the benchmark; FB control +1.81%). **Fluent Bit lighter overall**
  (~413 MiB vs ~198 MiB 5-pod, ~2.1×; CPU ~165 m vs ~143 m) with **zero loss**; collector had the same
  small non-zero loss signature as T3 (refused 35,616 / send_failed 10,460 of 1.478B sent, ≤0.005%).
  **But T4 is the capability tier:** only the collector can tail-sample in-pipeline, and that capability
  costs ~2.9× traces-pod memory (53→152 MiB) with the decision buffer pinned at its 100k-trace cap.
- **Cross-tier final ranking (T1–T4):** Fluent Bit v5 is consistently the lighter engine — logs
  (~5× mem), logs+metrics (~11× mem on the metrics arm), logs+metrics+traces (~41% mem / ~44% CPU),
  and the T4 control (~2.1× mem). The ranking is stable across the whole ladder: **FB stays lighter at
  every tier.** No memory leak in either engine at any tier (tail-flat everywhere, ≤1.81% drift).
  FB hit Dynatrace with **zero loss at every tier**; the collector was loss-free through T2 and had a
  small non-zero loss at T3/T4 (≤0.011% DT-failed / ≤0.005% refused+failed). **Capability
  differentiator:** native gRPC trace ingress, per-datapoint metrics, and in-pipeline tail sampling are
  collector-only — the tail-sampling premium (~+76 MiB/pipeline) is the price of that stage.

---

## 5. Provenance
- **T1 / E1 (ISI-3575):** `tiers/tier1/tier1-comparison.md` (+ raw `tier1-collector-results.md`,
  `tier1-fluentbit-results.md`). Collector 24h VALID 2026-09-04; FB v5.1.1 26h VALID 2026-09-05.
- **T2 / E2 (ISI-3576):** `tiers/tier2/tier2-comparison.md` (+ `tier2-fluentbit-results.md`).
  Collector v0.159.0 24h VALID 2026-09-09; FB v5.1.1 24h VALID 2026-09-10.
- **T3 / E3 (ISI-3577):** `tiers/tier3/tier3-comparison.md` (+ `tier3-collector-results.md`,
  `tier3-collector-2h-gate.md`, arm readouts). Collector v0.159.0 26h VALID (T0 2026-09-12T21:00Z);
  FB v5.1.1 26h VALID (T0 2026-09-13T23:14Z). Folded 2026-09-15.
- **T4 / E4 (ISI-3578):** `tiers/tier4/tier4-collector-results.md` (24h VALID, readout
  2026-09-17, T0 2026-09-16) + `tiers/tier4/tier4-fluentbit-results.md` (24h VALID, readout
  2026-09-18). Configs: `collector-tier4.yaml` (T3 + tail_sampling) / `fluentbit-tier4.yaml`.
  Folded 2026-09-20.
- Pins: `VERSIONS.md` (frozen 2026-09-02, board interaction 2d1e7309). Consolidation owner: John (PM), ISI-3579.
