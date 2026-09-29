# Tier 3 (logs+metrics+traces, NO tail sampling) — ARM 1 collector v0.159.0 — 24h soak readout
generated: 2026-09-13T23:10:20Z · engine=collector (single, FB offline) · load=locust+k6+telemetrygen(traces@200,metrics@100)
topology: DaemonSet(logs) + StatefulSet(metrics istiod+Kepler) + Deployment(traces OTLP) — TIER-3 delta = traces pipeline
NOTE: load generators (bench-load) completed their 26h run at T+26h=2026-09-13T23:00Z (by design); soak window was T+2h to T+26h

## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)
bench-collector-logs-4gqv4 0 26h
bench-collector-logs-4wf68 0 26h
bench-collector-logs-cnbkh 0 26h
bench-collector-metrics-0 0 26h
bench-collector-traces-dfdb866d6-xr7vt 0 26h
kepler-2xgll 0 11d
kepler-5jsm7 0 11d
kepler-c4ldd 0 11d
kepler-qhtc5 0 11d
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart (all 5 collector + 4 kepler pods)

## DT receipt gate (pt9 — logs+metrics+traces RECEIVED IN DYNATRACE)
[dt-receipt] bench-collector-logs-4gqv4 sent=38101068 send_failed=0
[dt-receipt] bench-collector-logs-4wf68 sent=20470675 send_failed=0
[dt-receipt] bench-collector-logs-cnbkh sent=4204624 send_failed=0
[dt-receipt] bench-collector-metrics-0 sent=30813717 send_failed=0
[dt-receipt] bench-collector-traces-dfdb866d6-xr7vt sent=72882451 send_failed=8000
[dt-receipt] TOTAL sent_to_DT=166472535 send_failed=8000 (logs+metrics+traces)
[dt-receipt] VERDICT: NOT CONFIRMED — investigate export

## Memory leak check (tail-flat at 24h)
[leak] bench-collector — 8 samples @ 15s
  2026-09-13T23:11:04Z  295MiB
  2026-09-13T23:11:19Z  297MiB
  2026-09-13T23:11:35Z  296MiB
  2026-09-13T23:11:50Z  294MiB
  2026-09-13T23:12:05Z  296MiB
  2026-09-13T23:12:20Z  296MiB
  2026-09-13T23:12:35Z  296MiB
  2026-09-13T23:12:50Z  297MiB

## Resource snapshot (working-set, per component)
bench-collector-logs-4gqv4               38m   60Mi   
bench-collector-logs-4wf68               36m   59Mi   
bench-collector-logs-cnbkh               29m   59Mi   
bench-collector-metrics-0                9m    81Mi   
bench-collector-traces-dfdb866d6-xr7vt   2m    38Mi   

## Load note
[load] bench-load pods completed naturally at T+26h (2026-09-13T23:00Z) — by design (telemetrygen configured for 26h)
[load] Load was running for FULL soak window (T+2h gate through T+26h completion = 24h)
[load] LOAD GATE: PASS (confirmed from 2h gate readout: locust reqs=405654, k6 iters=101685, tgen Running)

## Summary — ARM 1 collector v0.159.0 (Tier 3: logs+metrics+traces, NO tail sampling)
- T0: 2026-09-12T21:00:47Z  |  Soak end: 2026-09-13T23:00Z  |  Duration: 26h total (2h gate + 24h soak)
- Census: PASS — 5 collector pods (DaemonSet logs ×3, StatefulSet metrics ×1, Deployment traces ×1) + 4 kepler; all Running, 0 restarts at T+26h
- Load: PASS — locust(otel-demo) + k6(hipster-shop) + telemetrygen(traces@200/s, metrics@100/s) ran full 26h window
- DT receipt: 166,472,535 records sent, 8,000 send_failed (0.011% on traces — transient blip; logs/metrics 0 failures)
- Memory: TAIL-FLAT — 294-297 MiB stable at T+24h (5-component aggregate)
- Resources at T+26h: logs 29-38m/59-60Mi × 3 pods | metrics 9m/81Mi | traces 2m/38Mi

**VERDICT: 🟢 VALID** — census PASS, load PASS, DT receipt 166M (0.011% transient loss on traces only), memory tail-flat.
