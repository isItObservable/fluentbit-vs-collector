# Tier 3 (logs+metrics+traces, NO tail sampling) — ARM 1 collector v0.159.0 — 2h validity gate readout
generated: 2026-09-12T22:59:48Z · engine=collector (single, FB offline) · load=locust+k6+telemetrygen(traces@200,metrics@100)
topology: DaemonSet(logs) + StatefulSet(metrics istiod+Kepler) + Deployment(traces OTLP) — TIER-3 delta = traces pipeline

## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)
NAMESPACE POD PHASE RESTARTS ROLE
bench-collector bench-collector-logs-4gqv4 Running 0 STRICT
bench-collector bench-collector-logs-4wf68 Running 0 STRICT
bench-collector bench-collector-logs-cnbkh Running 0 STRICT
bench-collector bench-collector-metrics-0 Running 0 STRICT
bench-collector bench-collector-traces-dfdb866d6-xr7vt Running 0 STRICT
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
otel-demo postgresql-775ccb994b-xx8tb Running 1 source
otel-demo product-catalog-7875bcb8dd-ccxq5 Running 3 source
otel-demo product-reviews-b78b54859-f4464 Running 0 source
otel-demo quote-5c4fcdc84d-qr7rq Running 0 source
otel-demo recommendation-758765697d-jmgqh Running 0 source
otel-demo shipping-84f8b5dfd7-rzk6g Running 0 source
otel-demo valkey-cart-6c74b8cc4c-hw69k Running 0 source
hipster-shop adservice-64db44f966-9nrl5 Running 0 source
hipster-shop cartservice-78c74fbbcf-vp5tm Running 0 source
hipster-shop checkoutservice-f4677b8c4-cl4z5 Running 0 source
hipster-shop currencyservice-59bd4fd785-b9qk2 Running 1176 source
hipster-shop emailservice-6567d46c9d-s7rl2 Running 0 source
hipster-shop frontend-79cb8766c8-9lsdm Running 0 source
hipster-shop paymentservice-75f5c95477-6mlq5 Running 17 source
hipster-shop productcatalogservice-59dc6bb7d-hpzdj Running 0 source
hipster-shop recommendationservice-84c69dbdfd-xm64p Running 1 source
hipster-shop redis-cart-6b7c8c4556-bfbpg Running 830 source
hipster-shop shippingservice-669789cc48-sv5zx Running 0 source
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running.

## App churn during run (WARNING-only)
[app-churn] log-source pods restarted DURING run (WARNING, non-fatal): 3
    hipster-shop/currencyservice-59bd4fd785-b9qk2 rc=1176 Error @2026-09-12T22:53:27Z
    hipster-shop/paymentservice-75f5c95477-6mlq5 rc=17 OOMKilled @2026-09-12T21:01:32Z
    hipster-shop/redis-cart-6b7c8c4556-bfbpg rc=830 OOMKilled @2026-09-12T22:54:01Z

## Load reaching app gate (#6c)
[load] locust(otel-demo) pod=Running reqs=405654 | k6(hipster-shop) pod=Running iters=101685 | telemetrygen-traces pod=Running (@200 span/s)
[load] LOAD REACHING APP: PASS (app load + telemetrygen traces into engine OTLP)

## Dynatrace receipt gate (logs+metrics+traces RECEIVED IN DYNATRACE)
[dt-receipt] bench-collector-logs-4gqv4 sent=2568227 send_failed=0
[dt-receipt] bench-collector-logs-4wf68 sent=1348779 send_failed=0
[dt-receipt] bench-collector-logs-cnbkh sent=220900 send_failed=0
[dt-receipt] bench-collector-metrics-0 sent=2433001 send_failed=0
[dt-receipt] bench-collector-traces-dfdb866d6-xr7vt sent=5763500 send_failed=0
[dt-receipt] TOTAL sent_to_DT=12334407 send_failed=0 (logs+metrics+traces)
[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (logs+metrics+traces exported, 0 send_failed)

## Leak readout — collector (all components, tail-flat)
[leak] bench-collector — 12 samples @ 15s (needs metrics-server)
  2026-09-12T23:00:09Z 317MiB
  2026-09-12T23:00:24Z 321MiB
  2026-09-12T23:00:39Z 321MiB
  2026-09-12T23:00:54Z 320MiB
  2026-09-12T23:01:09Z 317MiB
  2026-09-12T23:01:24Z 321MiB
  2026-09-12T23:01:39Z 320MiB
  2026-09-12T23:01:54Z 114MiB
  2026-09-12T23:02:09Z 113MiB
  2026-09-12T23:02:24Z 124MiB
  2026-09-12T23:02:39Z 183MiB
  2026-09-12T23:02:54Z 123MiB
[leak] mid-third mean=268.0MiB tail-third mean=135.8MiB tail-drift=-49.35%
[leak] VERDICT: TAIL-FLAT (ok)

## Loss accounting — collector (accepted vs sent, all signals)

## Resource snapshot (working-set, per component)
bench-collector-logs-4gqv4 38m 59Mi
bench-collector-logs-4wf68 46m 64Mi
bench-collector-logs-cnbkh 36m 57Mi
bench-collector-metrics-0 9m 79Mi
bench-collector-traces-dfdb866d6-xr7vt 10m 66Mi
