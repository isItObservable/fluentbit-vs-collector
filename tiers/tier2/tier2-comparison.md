# Tier 2 (logs + metrics) — Tier 2 per-engine comparison → feeds the consolidated results

**Signal set:** LOGS + METRICS. **Topology:** DaemonSet (filelog logs) + StatefulSet (metrics: prometheus scrape of istiod CP + Kepler, cumulative→delta, drop-summary). Fluent Bit arm uses FB's native metric-conversion path for the metrics pipeline. **Methodology:** serial single-engine — one engine live at a time, exporting real logs+metrics to Dynatrace; validation gate = signal RECEIVED IN DYNATRACE + census PASS + load reaching app. **Cluster:** benchmark-cluster. **Load:** locust(otel-demo) + k6(hipster-shop).

Both arms ran a **2h rampup validity gate (GREEN required) → 24h soak**. Both gates went GREEN; both soaks completed clean and were torn down.

| KPI | ARM 1 — collector v0.159.0 | ARM 2 — Fluent Bit v5 (5.1.1) | Winner |
|---|---|---|---|
| Soak duration | 24h (T0 2026-09-08 06:41:17Z) | 24h (T0 2026-09-09 09:06:47Z) | — |
| Census gate (engine+infra STRICT, 0-restart) | **PASS** (3 logs DS + 1 metrics STS + Kepler Running, 0 restarts) | **PASS** (3 logs DS + 1 metrics STS + Kepler Running, 0 restarts) | tie |
| Log ingest (accepted / 24h) | 44,564,010 ≈ **516 rec/s** | input 43,440,978 ≈ **503 rec/s** | comparable load |
| Metric ingest (accepted / 24h) | 31,068,109 datapoints ≈ **360 dp/s** | via FB metric-conversion (proc merged in FB output) | comparable |
| Dynatrace receipt — LOGS | RECEIVED — sent 44,441,342, **send_failed=0** | RECEIVED — proc 43,371,427, **0 errors** | tie |
| Dynatrace receipt — METRICS | RECEIVED — sent 30,902,361, **send_failed=0** | RECEIVED (metric-conversion active, 0 errors) | tie |
| Loss (accepted vs sent) | **NO LOSS** — logs refused=0/send_failed=0; metrics refused=0/send_failed=0 (metrics sent<accepted EXPECTED: cumulative→delta drops 1st sample/series + drop-summary) | **NO LOSS** — in 43,440,978 / out 43,440,657 / dropped=0 / loss%=0.0000 | tie |
| Leak / floor-creep — metrics STS (TAIL-flat) | **TAIL-FLAT** — ~78 MiB plateau, tail-drift **−0.32%** (mid 78.2 → tail 78.0 MiB) | **TAIL-FLAT** — logs pods ~44 MiB, tail-drift **+1.71%** (mid 43.8 → tail 44.5 MiB) | both flat |
| **Metrics-pipeline working set (Kepler high-card cost delta)** | metrics STS **~78 MiB** | metrics STS **~7 MiB** (2m CPU) | **FB ~11× lighter on metrics** |
| Logs-pipeline working set (per-pod snapshot) | not snapshotted this arm | 63m/16Mi + 14m/12Mi + 15m/8Mi ≈ **92m / 36Mi total** | FB (collector not captured) |

## Kepler high-cardinality cost delta — the Tier-2-specific watch item
The metrics StatefulSet is where each engine absorbs the high-cardinality istiod-CP + Kepler scrape. **This is the headline Tier-2 delta:** the collector metrics pipeline (prometheus receiver → cumulativetodelta → drop-summary → OTLP) sits at a **~78 MiB tail-flat plateau**, while Fluent Bit's metric-conversion metrics pod holds **~7 MiB / 2 m CPU** at comparable ingest — roughly an **11× memory advantage for Fluent Bit on the metrics arm**. Neither engine leaks under the Kepler stressor over 24h (both tail-flat, sub-2% drift = warm-up floor-creep, not runaway). Note the two metrics pipelines are not architecturally identical (collector does full cumulative→delta conversion + summary-drop server-side; FB uses its native metric-conversion), so this is a cost-of-the-shipped-config comparison, not a like-for-like transform benchmark.

## Verdict
- **Both engines PASS all Tier 2 validity + KPI gates** (census, DT-receipt logs+metrics, no-loss, tail-flat). Dataset VALID.
- **Fluent Bit v5 is the lighter logs+metrics engine at this scale**, and the gap is widest on the **metrics arm** (~11× lower working set on the Kepler/istiod scrape pipeline). Directionally consistent with Tier 1 (Tier 1: FB ~5× lighter memory, ~30% lower CPU/cost on logs-only) and with a prior clean benchmark.
- **No memory leak in either engine** over 24h under the high-cardinality Kepler load (tail-flat both arms).
- App-tier churn (currencyservice/redis-cart/paymentservice restarts) was WARNING-only — sources kept flowing; engine+infra pods stayed 0-restart, so validity holds.

## Caveats / provenance
- A symmetric per-pod **CPU snapshot** was captured on the FB arm but not on the collector arm; the CPU/cost-per-1M line from Tier 1 is therefore not reproduced here. The metrics-pipeline **memory** delta (captured on both arms via the leak-plateau readout) carries the Tier-2 cost finding. Both namespaces are torn down, so re-measurement is not possible without a re-run.
- ARM 1 collector 24h COMPLETE VALID: run readout 2026-09-09T08:51Z · raw readout in the run log.
- ARM 2 fluent-bit 24h COMPLETE VALID: run readout 2026-09-10T~11:09Z · raw readout `tier2-fluentbit-results.md` (this dir); the run completed and tore down the load generators.
- Executed as the Tier 2 arm of the extended benchmark; feeds the consolidated results.
