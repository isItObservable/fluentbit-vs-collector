# Tier 4 ARM1 (collector + tail_sampling) — mid-soak health + tgen-metrics RCA

generated: 2026-09-16T17:40Z (T0+8.6h) · engine=otel-collector-contrib v0.159.0 · FB offline
author: run run (backup_PM) · soak readout due ~2026-09-17T11:00Z (T0+26h)

## Mid-soak snapshot (T0+8.6h) — ALL HEALTHY

| check | value | verdict |
|---|---|---|
| driver pid | 314415 alive (bash./tier4-driver.sh, sleeping to T+26h readout) | ok |
| ARM2 chain-guard | pid 345927 armed (auto-launches FB no-TS control after valid ARM1 soak) | ok |
| bench-collector pods | 5/5 Running 8h+, 0 restarts (logs DS x3, metrics STS, traces Deploy) | ok |
| bench-load pods | locust/k6/tgen-traces Running; tgen-metrics crash-loop (see RCA — inert, by-design-kept) | ok* |
| tail_sampling ingress | new_trace_id_received = 12.50M | ok |
| sampling policy math | sampled=3.7527M / 12.50M = 30.02% (probabilistic-30 policy exact); keep-errors=0 matches (no ERROR traces in load — expected for telemetrygen+demo traffic) | ok |
| spans exported to DT | otelcol_exporter_sent_spans = 7.504M, in-flight=0, queue_size=0/1000 | ok |
| decision timer | 31,315 ticks (~1/s since T0), decision latency ≤10ms buckets | ok |
| resources (traces pod) | 21m CPU / 149Mi working-set (gate-time: 24m/135Mi) — mild mem growth = decision-buffer fill, watch at readout vs T3 baseline | ok |
| DT metrics ingest | 10.19M points at T0+8.5h (verified 17:30Z via DT receipt; scrape-based: istiod+Kepler) | ok |

## RCA: tgen-metrics crash-loop (Unimplemented MetricsService) — KNOWN, LEFT AS-IS

- symptom: tgen-metrics 446 backoffs since T0; `rpc error: code = Unimplemented desc = unknown service opentelemetry.proto.collector.metrics.v1.MetricsService`
- root cause: harness design, not a regression. `bench-collector-otlp` svc fronts the **traces-only** Deployment (otlp receiver → traces pipeline; no metrics pipeline exists in the collector-arm topology at all — metrics arrive via the STS prometheus scrape of istiod:15014 + Kepler:9102). There is NO OTLP metrics-push ingress in any tier-3/4 collector arm, so tgen-metrics@100/s can never land. The tgen-metrics Deployment is vestigial from the setup (era of full OTLP-ingress engines).
- comparability: T3 collector arm topology is IDENTICAL (same svc→traces-only Deployment, same v0.159.0, manifest held by no-drift rule) → tgen-metrics crash-looped in T3 too → **the T3→T4 tail-sampling delta remains apples-to-apples** (both arms: metrics signal = scrape-based only, synthetic metrics push absent).
- decision: DO NOT touch bench-load mid-soak. Deleting/fixing tgen-metrics now would diverge T4 load conditions from T3 and pollute the delta. The crash-loop is inert (no telemetry flows, ~1 restart/5min, negligible resources). Same expectation for ARM2 (FB arm is traces-only as well; arm2 span-ingest pre-check only checks traces — unaffected).
- ACTION for readout/comparison: (1) T4 readout header should say `telemetrygen(traces@200)` only — the gate header already does. (2) **Correction note for T3 artifacts**: `tier3-collector-results.md` line "telemetrygen(traces@200/s, metrics@100/s) ran full 26h window" is wrong re metrics@100/s — synthetic metrics never flowed in T3 either; metrics volume was scrape-based. Must be footnoted in tier4-comparison.md so the consolidated results consumes corrected facts. (3) Optional harness cleanup post-consolidation: drop tgen-metrics from telemetrygen-load.yaml or add an otlp-metrics ingress if a future tier wants synthetic metrics push.

## Timeline ahead (autonomous, no agent action needed unless RED)

- ~2026-09-17T11:00Z: driver posts 24h soak readout (census + KPI + leak + loss + tail-sampling cost snapshot) to the run log; writes tier4-collector-results.md; tears down bench-collector.
- chain-guard (pid 345927) then auto-launches ARM2 = Fluent Bit v5.1.1 no-TS control: 2h gate ~T+2h, 24h soak readout ~T+26h (≈2026-09-18T13:00Z).
- after ARM2: manual step = tier4-comparison.md (collector T4 vs T3 = tail-sampling CPU/mem/state cost; FB control = no-TS baseline) → the consolidated results.
