# Tier 2 (logs+metrics) — fluentbit — 2h validity gate readout
generated: 2026-09-09T11:06:48Z · engine=fluentbit (single, other offline) · load=locust+k6

## Census gate (engine+infra STRICT, apps liveness-only)
NAMESPACE POD PHASE RESTARTS ROLE
bench-fluentbit bench-fluentbit-logs-7kcq7 Running 0 STRICT
bench-fluentbit bench-fluentbit-logs-hgvlt Running 0 STRICT
bench-fluentbit bench-fluentbit-logs-kzlhl Running 0 STRICT
bench-fluentbit bench-fluentbit-metrics-0 Running 0 STRICT
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
otel-demo load-generator-57fd5dddff-b9qhv Running 3 source
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
hipster-shop currencyservice-59bd4fd785-b9qk2 Running 799 source
hipster-shop emailservice-6567d46c9d-s7rl2 Running 0 source
hipster-shop frontend-79cb8766c8-9lsdm Running 0 source
hipster-shop paymentservice-75f5c95477-6mlq5 Running 9 source
hipster-shop productcatalogservice-59dc6bb7d-hpzdj Running 0 source
hipster-shop recommendationservice-84c69dbdfd-xm64p Running 1 source
hipster-shop redis-cart-6b7c8c4556-bfbpg Running 609 source
hipster-shop shippingservice-669789cc48-sv5zx Running 0 source
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running.

## Load reaching app gate (#6c)
[load] locust pod=Running reqs=435368 | k6 pod=Running
[load] LOAD REACHING APP: PASS

## Dynatrace receipt gate (logs+metrics)
[dt-receipt] FB output proc_records=2683358 errors=0
[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (proc>0, 0 errors)

## Leak readout (tail-flat)
[leak] bench-fluentbit — 12 samples @ 15s (needs metrics-server)
  2026-09-09T11:07:00Z 45MiB
  2026-09-09T11:07:15Z 48MiB
  2026-09-09T11:07:30Z 47MiB
  2026-09-09T11:07:45Z 46MiB
  2026-09-09T11:08:00Z 46MiB
  2026-09-09T11:08:15Z 43MiB
  2026-09-09T11:08:30Z 45MiB
  2026-09-09T11:08:45Z 48MiB
  2026-09-09T11:09:00Z 44MiB
  2026-09-09T11:09:15Z 43MiB
  2026-09-09T11:09:30Z 50MiB
  2026-09-09T11:09:45Z 38MiB
[leak] mid-third mean=45.5MiB tail-third mean=43.8MiB tail-drift=-3.85%
[leak] VERDICT: TAIL-FLAT (ok)

## Loss accounting

## Kepler high-cardinality cost note — active-series + working-set at this engine
bench-fluentbit-logs-7kcq7 80m 14Mi
bench-fluentbit-logs-hgvlt 21m 12Mi
bench-fluentbit-logs-kzlhl 15m 7Mi
bench-fluentbit-metrics-0 3m 5Mi
