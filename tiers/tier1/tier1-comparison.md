# Tier 1 (logs only) — per-engine comparison → feeds the consolidated results

**Signal set:** LOGS ONLY (daemonset). **Methodology:** serial single-engine — one engine live at a time, exporting real logs to Dynatrace, validation gate = signal RECEIVED IN DYNATRACE + census PASS + load reaching app. **Cluster:** benchmark-cluster. **Load:** locust(otel-demo) + k6(hipster-shop).

Both arms ran a **2h rampup validity gate (GREEN required) → 24h+ soak**. Both gates went GREEN; both soaks completed clean and were torn down.

| KPI | ARM 1 — collector | ARM 2 — Fluent Bit v5 (5.1.1) | Winner |
|---|---|---|---|
| Soak duration | 24h (T0 2026-09-03 16:20Z*) | 26h (T0 2026-09-04 18:39Z) | — |
| Census gate | **PASS** (3/3 engine Running, 0 restarts) | **PASS** (3/3 engine Running, 0 restarts) | tie |
| Log ingest rate | 65,594,978 accepted / 24h ≈ **759 rec/s** | 70,542,166 input (cluster) / 26h ≈ **754 rec/s** | comparable load |
| Dynatrace receipt | RECEIVED — 394,153 recent sent, **0 send_failed** | RECEIVED — 43.35M proc, **0 dropped / 0 errors** | tie |
| Loss (accepted==sent) | **NO LOSS** — refused=0, send_failed=0 (fan-out 1.879× = 2 exporters) | **NO LOSS** — cluster in=70,542,166 out=70,541,631, loss%=0.0000 | tie |
| CPU (3-pod working-set snapshot) | 33+47+55 = **135 m** | 57+16+21 = **94 m** | **FB −30%** |
| Memory (working-set, tail plateau) | ~184 MiB total (~61 MiB/pod) | ~37 MiB total (~12 MiB/pod) | **FB ~5× lighter** |
| Leak / floor-creep (TAIL-flat check) | **TAIL-FLAT** — tail-drift −0.94% (mid 185.8 → tail 184.0 MiB) | **TAIL-FLAT** — tail-drift −2.55% (mid 39.2 → tail 38.2 MiB) | both flat |
| Cost-per-1M (cluster-derived, matched ~755 rec/s)** | **~2,964 mc/1M** | **~2,079 mc/1M** | **FB −30%** |

\* ARM 1 T0 16:20Z is the final relaunch after a 2h-gate RED that was root-caused to load config (not the engine) and fixed; the counted 24h soak ran clean from there.
\** Cost normalized on a consistent cluster-CPU-snapshot ÷ matched-throughput basis so the two arms compare apples-to-apples. Fluent Bit's driver also captured a per-pod 60s spot sample = 3,651 mc/1M (pod f4vpr, single pod); the cluster-derived figures above are the comparable ones.

## Verdict
- **Both engines PASS all Tier 1 validity + KPI gates** (census, DT-receipt, no-loss, tail-flat). Dataset VALID.
- **Fluent Bit v5 is the lighter logs-only engine**: ~30% lower CPU, ~5× lower memory, ~30% lower cost-per-1M at matched ingest (~755 rec/s). Directionally consistent with a prior clean 3-engine benchmark (fluentbit < collector on mc/1M).
- **No memory leak in either engine** over 24–26h (tail-flat, sub-3% drift = warm-up floor-creep, not runaway).
- App-tier churn (postgresql/redis/currencysvc OOMKills) was WARNING-only — log sources kept flowing; engine+infra pods stayed 0-restart, so validity holds.

## Provenance (delivered to)
- ARM 1 collector 2h gate GREEN: comment 2026-09-03T18:23Z · 24h COMPLETE VALID: 2026-09-04T18:26Z
- ARM 2 fluent-bit 2h gate GREEN: comment 2026-09-04T20:43Z · 24h COMPLETE VALID: 2026-09-05T20:47Z
- Raw readouts: `tier1-collector-results.md`, `tier1-fluentbit-results.md` (this dir). The tier runs both completed and tore down the load generators.
- Executed by backup_PM (agent fce265dd) after maintainer takeover 2026-09-04 17:20Z.
