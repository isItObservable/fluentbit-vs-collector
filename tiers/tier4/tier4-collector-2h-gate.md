# Tier 4 (logs+metrics+traces+TAIL SAMPLING) — ARM 1 collector v0.159.0 — 2h validity gate readout
generated: 2026-09-16T10:55:53Z · engine=collector (single, FB offline) · load=locust+k6+telemetrygen(traces@200,metrics@100)
topology: DaemonSet(logs) + StatefulSet(metrics istiod+Kepler) + Deployment(traces OTLP + tail_sampling) — TIER-4 delta = tail_sampling processor
tail-sampling policy: keep-errors OR (NOT healthcheck AND 30% probabilistic); decision_wait=10s num_traces=100000

## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)
NAMESPACE POD PHASE RESTARTS ROLE
bench-collector bench-collector-logs-4m9gh Running 0 STRICT
bench-collector bench-collector-logs-6gw8m Running 0 STRICT
bench-collector bench-collector-logs-mww5w Running 0 STRICT
bench-collector bench-collector-metrics-0 Running 0 STRICT
bench-collector bench-collector-traces-5848df76f9-fs2sm Running 0 STRICT
kepler kepler-2xgll Running 0 STRICT
kepler kepler-5jsm7 Running 0 STRICT
kepler kepler-c4ldd Running 0 STRICT
kepler kepler-qhtc5 Running 0 STRICT
otel-demo accounting-799d56d5f5-wkz2c Running 0 source
otel-demo ad-9c69f9686-5tcrw Running 0 source
otel-demo cart-7789dc7575-ptmwp Running 0 source
otel-demo checkout-86468654d7-g2htm Running 0 source
otel-demo currency-65d9467895-qfptq Running 0 source
otel-demo email-8c8564f57-sg5zm Running 0 source
otel-demo flagd-6946bb88cd-g9qgh Running 0 source
otel-demo fraud-detection-b87fffcdf-4fcvg Running 0 source
otel-demo frontend-5b7fb8844f-5f8v2 Running 0 source
otel-demo frontend-proxy-6bb789597d-dj9wh Running 0 source
otel-demo image-provider-76c46f5d69-4hm6c Running 0 source
otel-demo kafka-5bd9dc6bb9-g429x Running 0 source
otel-demo llm-6c9779b558-tb9fp Running 0 source
otel-demo load-generator-57fd5dddff-b9qhv Running 5 source
otel-demo payment-745df48ddf-wsrv7 Running 0 source
otel-demo postgresql-775ccb994b-xx8tb Running 27 source
otel-demo product-catalog-7875bcb8dd-ccxq5 Running 10 source
otel-demo product-reviews-b78b54859-f4464 Running 0 source
otel-demo quote-5c4fcdc84d-qr7rq Running 0 source
otel-demo recommendation-758765697d-jmgqh Running 0 source
otel-demo shipping-84f8b5dfd7-rzk6g Running 0 source
otel-demo valkey-cart-6c74b8cc4c-hw69k Running 0 source
hipster-shop adservice-64db44f966-9nrl5 Running 13 source
hipster-shop cartservice-78c74fbbcf-vp5tm Running 8 source
hipster-shop checkoutservice-f4677b8c4-cl4z5 Running 5 source
hipster-shop currencyservice-59bd4fd785-b9qk2 Running 1889 source
hipster-shop emailservice-6567d46c9d-s7rl2 Running 6 source
hipster-shop frontend-79cb8766c8-9lsdm Running 8 source
hipster-shop paymentservice-75f5c95477-6mlq5 Running 30 source
hipster-shop productcatalogservice-59dc6bb7d-hpzdj Running 5 source
hipster-shop recommendationservice-84c69dbdfd-xm64p Running 9 source
hipster-shop redis-cart-6b7c8c4556-bfbpg Running 1244 source
hipster-shop shippingservice-669789cc48-sv5zx Running 0 source
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running.

## App churn during run (WARNING-only)
[app-churn] log-source pods restarted DURING run (WARNING, non-fatal): 2
    hipster-shop/currencyservice-59bd4fd785-b9qk2 rc=1889 Error @2026-09-16T10:51:18Z
    hipster-shop/redis-cart-6b7c8c4556-bfbpg rc=1244 OOMKilled @2026-09-16T10:51:53Z

## Load reaching app gate (#6c)
[load] locust(otel-demo) pod=Running reqs=441360 | k6(hipster-shop) pod=Running iters=112236 | telemetrygen-traces pod=Running (@200 span/s)
[load] LOAD REACHING APP: PASS (app load + telemetrygen traces into engine OTLP)

## Dynatrace receipt gate (logs+metrics+traces RECEIVED IN DYNATRACE)
[dt-receipt] bench-collector-logs-4m9gh sent=2808094 send_failed=0
[dt-receipt] bench-collector-logs-6gw8m sent=378032 send_failed=0
[dt-receipt] bench-collector-logs-mww5w sent=1283291 send_failed=0
[dt-receipt] bench-collector-metrics-0 sent=0 send_failed=0
[dt-receipt] bench-collector-traces-5848df76f9-fs2sm sent=1726136 send_failed=0
[dt-receipt] TOTAL sent_to_DT=6195553 send_failed=0 (logs+metrics+traces)
[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (logs+metrics+traces exported, 0 send_failed)

## Tail-sampling processor stats (the Tier 4 measurement — sampled/dropped/decision buffer)
[tail-sampling] traces pod=bench-collector-traces-5848df76f9-fs2sm
   otelcol_processor_tail_sampling_count_traces_sampled{decision="not_sampled",policy="keep-errors",sampled="false"} 2.8807e+06
   otelcol_processor_tail_sampling_count_traces_sampled{decision="not_sampled",policy="sample-non-health-30pct",sampled="false"} 2.016697e+06
   otelcol_processor_tail_sampling_count_traces_sampled{decision="sampled",policy="sample-non-health-30pct",sampled="true"} 864003
   otelcol_processor_tail_sampling_global_count_traces_sampled{decision="not_sampled",sampled="false"} 2.016697e+06
   otelcol_processor_tail_sampling_global_count_traces_sampled{decision="sampled",sampled="true"} 864003
   otelcol_processor_tail_sampling_new_trace_id_received 2.88495e+06
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="10000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="1000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="100"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="10"} 7249
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="150"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="1"} 6143
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="20000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="2000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="200"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="25"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="2"} 7019
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="30000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="3000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="300"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="4000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="400"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="50000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="5000"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="500"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="50"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="5"} 7216
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="750"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="75"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_bucket{le="+Inf"} 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_count 7250
   otelcol_processor_tail_sampling_sampling_decision_timer_latency_sum 8787
   otelcol_processor_tail_sampling_sampling_policy_evaluation_error 0
   otelcol_processor_tail_sampling_sampling_trace_dropped_too_early 0
   otelcol_processor_tail_sampling_sampling_traces_on_memory 100000

## Leak readout — collector (all components, tail-flat)
[leak] bench-collector — 12 samples @ 15s (needs metrics-server)
  2026-09-16T10:56:18Z 395MiB
  2026-09-16T10:56:33Z 399MiB
  2026-09-16T10:56:48Z 391MiB
  2026-09-16T10:57:03Z 392MiB
  2026-09-16T10:57:19Z 393MiB
  2026-09-16T10:57:34Z 393MiB
  2026-09-16T10:57:49Z 390MiB
  2026-09-16T10:58:04Z 398MiB
  2026-09-16T10:58:19Z 391MiB
  2026-09-16T10:58:34Z 392MiB
  2026-09-16T10:58:49Z 403MiB
  2026-09-16T10:59:04Z 396MiB
[leak] mid-third mean=393.5MiB tail-third mean=395.5MiB tail-drift=+0.51%
[leak] VERDICT: TAIL-FLAT (ok)

## Loss accounting — collector (accepted vs sent, all signals)
[collector] accepted=725981100 refused=35616 sent=1368774378 send_failed=10460
fan-out ratio sent/accepted=1.885 (>1 = multi-exporter, expected)
LOSS VERDICT: LOSS DETECTED (refused=35616, send_failed=10460)

## Resource snapshot (working-set, per component — WATCH the traces pod: tail_sampling cost)
bench-collector-logs-4m9gh 58m 65Mi
bench-collector-logs-6gw8m 30m 58Mi
bench-collector-logs-mww5w 45m 59Mi
bench-collector-metrics-0 9m 79Mi
bench-collector-traces-5848df76f9-fs2sm 24m 135Mi
