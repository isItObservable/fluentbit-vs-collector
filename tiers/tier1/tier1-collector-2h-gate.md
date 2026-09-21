# Tier 1 (logs only) — ARM 1 collector — 2h validity gate readout
generated: 2026-09-03T18:20:35Z · engine=collector (single, FB offline) · load=locust(otel-demo)+k6(hipster-shop)

## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)
NAMESPACE POD PHASE RESTARTS ROLE
bench-collector bench-collector-jjgff Running 0 STRICT
bench-collector bench-collector-kpqzs Running 0 STRICT
bench-collector bench-collector-tnh2n Running 0 STRICT
kepler kepler-2xgll Running 0 STRICT
kepler kepler-5jsm7 Running 0 STRICT
kepler kepler-c4ldd Running 0 STRICT
kepler kepler-qhtc5 Running 0 STRICT
otel-demo accounting-7756857c78-h989p Running 0 source
otel-demo ad-66cf4cd84d-2hk6z Running 0 source
otel-demo cart-95bc64b54-khgxl Running 3 source
otel-demo checkout-5db7465b8-2fmd5 Running 0 source
otel-demo currency-6ff56cb665-86zkg Running 1 source
otel-demo email-84fcd866f9-2hhts Running 3 source
otel-demo flagd-859744cd4c-q85tl Running 0 source
otel-demo fraud-detection-5c55d775bd-jwv6p Running 2 source
otel-demo frontend-6568c455b7-cxb2c Running 3 source
otel-demo frontend-proxy-689bff9c7b-hxmmb Running 0 source
otel-demo image-provider-745d4ff6c9-7fs6w Running 0 source
otel-demo kafka-7c6f99768c-rbln2 Running 0 source
otel-demo llm-6c8d58d48-wx52q Running 3 source
otel-demo load-generator-66d88cfd9c-cgpkt Running 1 source
otel-demo payment-65ff47cd99-p5hkj Running 0 source
otel-demo postgresql-6869b5c65-w6j9v Running 4 source
otel-demo product-catalog-5948dc7974-dqm67 Running 16 source
otel-demo product-reviews-5765bc4c7c-6q4jd Running 7 source
otel-demo quote-6bd8768978-xf87v Running 2 source
otel-demo recommendation-5b848cf4b4-p5wmw Running 0 source
otel-demo shipping-85cfb5d8d5-fncg2 Running 0 source
otel-demo valkey-cart-747697db59-9f96x Running 3 source
hipster-shop adservice-fff6d8f8-5px5c Running 23 source
hipster-shop cartservice-7c4bd8945f-jgs5m Running 0 source
hipster-shop checkoutservice-5bd7d699f8-th7th Running 3 source
hipster-shop currencyservice-85787bc947-wh4j2 Running 22 source
hipster-shop emailservice-75684cb858-7gwdt Running 21 source
hipster-shop frontend-5b4d5bd96b-7m4lh Running 1 source
hipster-shop paymentservice-6fd5c59d8c-qfpqj Running 0 source
hipster-shop productcatalogservice-5bfd9d4d7b-v8pwk Running 0 source
hipster-shop recommendationservice-5dd9fbd7d-rxpq5 Running 18 source
hipster-shop redis-cart-6b7c8c4556-bfbpg Running 0 source
hipster-shop shippingservice-74b565b95d-8l9b4 Running 0 source
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running.

## App churn during run (WARNING-only)
[app-churn] log-source pods restarted DURING run (WARNING, non-fatal — logs kept flowing): 1
    hipster-shop/currencyservice-85787bc947-wh4j2 rc=22 Error @2026-09-03T18:16:41Z

## Load reaching app gate (#6c)
[load] locust(otel-demo) pod=Running aggregated_reqs=440269 | k6(hipster-shop) pod=Running iterations=177368
[load] LOAD REACHING APP: PASS

## Dynatrace receipt gate (signal RECEIVED IN DYNATRACE)
[dt-receipt] logs sent to Dynatrace=12830 send_failed=0
[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (2xx, 0 failed)

## Leak readout — collector (tail-flat)
[leak] bench-collector — 12 samples @ 15s (needs metrics-server)
  2026-09-03T18:20:41Z 176MiB
  2026-09-03T18:20:56Z 176MiB
  2026-09-03T18:21:11Z 178MiB
  2026-09-03T18:21:26Z 178MiB
  2026-09-03T18:21:41Z 176MiB
  2026-09-03T18:21:56Z 179MiB
  2026-09-03T18:22:11Z 183MiB
  2026-09-03T18:22:26Z 179MiB
  2026-09-03T18:22:41Z 172MiB
  2026-09-03T18:22:56Z 172MiB
  2026-09-03T18:23:11Z 181MiB
  2026-09-03T18:23:27Z 181MiB
[leak] mid-third mean=179.2MiB tail-third mean=176.5MiB tail-drift=-1.53%
[leak] VERDICT: TAIL-FLAT (ok)

## Loss accounting — collector
[collector] accepted=11498304 refused=0 sent=21478103 send_failed=0
fan-out ratio sent/accepted=1.868 (>1 = multi-exporter, expected)
LOSS VERDICT: NO LOSS (refused=0, send_failed=0)

## Resource snapshot (working-set)
bench-collector-jjgff 25m 57Mi
bench-collector-kpqzs 34m 57Mi
bench-collector-tnh2n 80m 68Mi
