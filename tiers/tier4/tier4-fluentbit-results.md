# Tier 4 CONTROL ARM (FB v5.1.1 full stack, NO tail sampling) — 24h soak readout
generated: 2026-09-18T21:53:52Z · engine=fluentbit-v5.1.1 (single, collector offline) · load=locust+k6+telemetrygen(traces@200 --otlp-http :4318)
control framing: FB has NO tail sampling -> this arm = T3-shaped trace load; the T3->T4 tail-sampling cost is read on the COLLECTOR arm

## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)
NAMESPACE POD PHASE RESTARTS ROLE
bench-fluentbit bench-fluentbit-logs-cbm52 Running 0 STRICT
bench-fluentbit bench-fluentbit-logs-q59f2 Running 0 STRICT
bench-fluentbit bench-fluentbit-logs-wdqqq Running 0 STRICT
bench-fluentbit bench-fluentbit-metrics-0 Running 0 STRICT
bench-fluentbit bench-fluentbit-traces-744898b4b5-98g9h Running 0 STRICT
kepler kepler-4qvls Running 0 STRICT
kepler kepler-g727v Running 0 STRICT
kepler kepler-s2sdm Running 0 STRICT
kepler kepler-s55md Running 0 STRICT
otel-demo accounting-799d56d5f5-wkz2c Running 1 source
otel-demo ad-9c69f9686-5tcrw Running 1 source
otel-demo cart-7789dc7575-ptmwp Running 1 source
otel-demo checkout-86468654d7-g2htm Running 1 source
otel-demo currency-65d9467895-qfptq Running 1 source
otel-demo email-8c8564f57-sg5zm Running 1 source
otel-demo flagd-6946bb88cd-g9qgh Running 1 source
otel-demo fraud-detection-b87fffcdf-4fcvg Running 1 source
otel-demo frontend-5b7fb8844f-5f8v2 Running 1 source
otel-demo frontend-proxy-6bb789597d-dj9wh Running 1 source
otel-demo image-provider-76c46f5d69-4hm6c Running 1 source
otel-demo kafka-5bd9dc6bb9-g429x Running 1 source
otel-demo llm-6c9779b558-tb9fp Running 1 source
otel-demo load-generator-57fd5dddff-b9qhv Running 6 source
otel-demo payment-745df48ddf-wsrv7 Running 1 source
otel-demo postgresql-775ccb994b-xx8tb Running 30 source
otel-demo product-catalog-7875bcb8dd-ccxq5 Running 15 source
otel-demo product-reviews-b78b54859-f4464 Running 1 source
otel-demo quote-5c4fcdc84d-qr7rq Running 1 source
otel-demo recommendation-758765697d-jmgqh Running 1 source
otel-demo shipping-84f8b5dfd7-rzk6g Running 1 source
otel-demo valkey-cart-6c74b8cc4c-hw69k Running 1 source
hipster-shop adservice-64db44f966-9nrl5 Running 16 source
hipster-shop cartservice-78c74fbbcf-vp5tm Running 9 source
hipster-shop checkoutservice-f4677b8c4-cl4z5 Running 6 source
hipster-shop currencyservice-59bd4fd785-b9qk2 Running 2711 source
hipster-shop emailservice-6567d46c9d-s7rl2 Running 9 source
hipster-shop frontend-79cb8766c8-9lsdm Running 9 source
hipster-shop paymentservice-75f5c95477-6mlq5 Running 38 source
hipster-shop productcatalogservice-59dc6bb7d-hpzdj Running 6 source
hipster-shop recommendationservice-84c69dbdfd-xm64p Running 12 source
hipster-shop redis-cart-6b7c8c4556-bfbpg Running 1740 source
hipster-shop shippingservice-669789cc48-sv5zx Running 1 source
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running.

## Load reaching app gate (#6c)
[load] locust(otel-demo) pod=Running reqs=4617 | k6(hipster-shop) pod=Running | tgen-traces pod=Running (@200 span/s --otlp-http)
[load] LOAD REACHING APP: PASS (app load + telemetrygen traces into FB OTLP input)

## Dynatrace receipt gate (FB output proc_records / dropped)
[dt-receipt] bench-fluentbit-logs-cbm52 proc=36735215 dropped=0
[dt-receipt] bench-fluentbit-logs-q59f2 proc=21644027 dropped=0
[dt-receipt] bench-fluentbit-logs-wdqqq proc=3479222 dropped=0
[dt-receipt] bench-fluentbit-metrics-0 proc=12511 dropped=0
[dt-receipt] bench-fluentbit-traces-744898b4b5-98g9h proc=9187120 dropped=0
[dt-receipt] TOTAL proc_records=71058095 dropped=0 (logs+metrics+traces)
[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (all signals processed, 0 dropped)

## Leak readout — fluentbit (all components, tail-flat)
[leak] bench-fluentbit — 12 samples @ 15s (needs metrics-server)
  2026-09-18T21:54:13Z 185MiB
  2026-09-18T21:54:28Z 193MiB
  2026-09-18T21:54:43Z 194MiB
  2026-09-18T21:54:58Z 186MiB
  2026-09-18T21:55:13Z 186MiB
  2026-09-18T21:55:28Z 198MiB
  2026-09-18T21:55:43Z 194MiB
  2026-09-18T21:55:58Z 197MiB
  2026-09-18T21:56:13Z 199MiB
  2026-09-18T21:56:28Z 200MiB
  2026-09-18T21:56:44Z 192MiB
  2026-09-18T21:56:59Z 198MiB
[leak] mid-third mean=193.8MiB tail-third mean=197.2MiB tail-drift=+1.81%
[leak] VERDICT: TAIL-FLAT (ok)

## Resource snapshot (working-set, per component)
bench-fluentbit-logs-cbm52 66m 17Mi
bench-fluentbit-logs-q59f2 19m 14Mi
bench-fluentbit-logs-wdqqq 16m 8Mi
bench-fluentbit-metrics-0 3m 9Mi
bench-fluentbit-traces-744898b4b5-98g9h 39m 150Mi
