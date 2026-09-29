# Tier 1 (logs only) — ARM 1 collector — 24h soak readout
generated: 2026-09-04T18:23:32Z  ·  engine=collector (single, FB offline)  ·  load=locust(otel-demo)+k6(hipster-shop)

## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)
NAMESPACE          POD                                PHASE      RESTARTS  ROLE   
bench-collector    bench-collector-jjgff              Running    0         STRICT 
bench-collector    bench-collector-kpqzs              Running    0         STRICT 
bench-collector    bench-collector-tnh2n              Running    0         STRICT 
kepler             kepler-2xgll                       Running    0         STRICT 
kepler             kepler-5jsm7                       Running    0         STRICT 
kepler             kepler-c4ldd                       Running    0         STRICT 
kepler             kepler-qhtc5                       Running    0         STRICT 
otel-demo          accounting-65b5fb67bb-nswdk        Running    0         source 
otel-demo          ad-6b645785b4-rzjl5                Running    0         source 
otel-demo          cart-5896c58756-5l68j              Running    0         source 
otel-demo          checkout-79448f79f8-4z87w          Running    0         source 
otel-demo          currency-675b4cd4d7-4sglp          Running    0         source 
otel-demo          email-6b9cfc85d5-ww5fw             Running    0         source 
otel-demo          flagd-dd694f745-tqqvv              Running    0         source 
otel-demo          fraud-detection-7f644f7ffd-s9rs9   Running    0         source 
otel-demo          frontend-7b6d8b7bdf-fpvlx          Running    0         source 
otel-demo          frontend-proxy-7f7cf96f6b-fjfqz    Running    0         source 
otel-demo          image-provider-7b6bc86c5c-h8xxr    Running    0         source 
otel-demo          kafka-56c88fdbcc-wzv22             Running    0         source 
otel-demo          llm-75f57cc658-nn89c               Running    0         source 
otel-demo          load-generator-695bcd96dc-gb9g5    Running    0         source 
otel-demo          payment-6cd49fc797-d9vrh           Running    0         source 
otel-demo          postgresql-6869b5c65-w6j9v         Running    4         source 
otel-demo          product-catalog-788cc66c6b-z5pf6   Running    0         source 
otel-demo          product-reviews-7d9fd96d4c-szmdq   Running    0         source 
otel-demo          quote-6689979fdb-t5sqb             Running    0         source 
otel-demo          recommendation-84696bc4b6-mgrtz    Running    0         source 
otel-demo          shipping-86b9954bc5-sqj9k          Running    0         source 
otel-demo          valkey-cart-747697db59-9f96x       Running    3         source 
hipster-shop       adservice-64db44f966-9nrl5         Running    0         source 
hipster-shop       cartservice-78c74fbbcf-vp5tm       Running    0         source 
hipster-shop       checkoutservice-f4677b8c4-cl4z5    Running    0         source 
hipster-shop       currencyservice-59bd4fd785-b9qk2   Running    25        source 
hipster-shop       emailservice-6567d46c9d-s7rl2      Running    0         source 
hipster-shop       frontend-79cb8766c8-9lsdm          Running    0         source 
hipster-shop       paymentservice-75f5c95477-6mlq5    Running    0         source 
hipster-shop       productcatalogservice-59dc6bb7d-hpzdj Running    0         source 
hipster-shop       recommendationservice-84c69dbdfd-xm64p Running    0         source 
hipster-shop       redis-cart-6b7c8c4556-bfbpg        Running    154       source 
hipster-shop       shippingservice-669789cc48-sv5zx   Running    0         source 
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running.

## App churn during run (WARNING-only)
[app-churn] log-source pods restarted DURING run (WARNING, non-fatal — logs kept flowing): 2
    hipster-shop/currencyservice-59bd4fd785-b9qk2 rc=25 Error @2026-09-04T18:23:28Z
    hipster-shop/redis-cart-6b7c8c4556-bfbpg rc=154 OOMKilled @2026-09-04T18:17:02Z

## Load reaching app gate (#6c)
[load] locust(otel-demo) pod=Running aggregated_reqs=3149  |  k6(hipster-shop) pod=Running iterations=151909
[load] LOAD REACHING APP: PASS

## Dynatrace receipt gate (pt9 — signal RECEIVED IN DYNATRACE)
[dt-receipt] logs sent to Dynatrace=394153 send_failed=0
[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (2xx, 0 failed)

## Leak readout — collector (tail-flat)
[leak] bench-collector — 12 samples @ 15s (needs metrics-server)
  2026-09-04T18:23:38Z  179MiB
  2026-09-04T18:23:53Z  180MiB
  2026-09-04T18:24:08Z  186MiB
  2026-09-04T18:24:23Z  190MiB
  2026-09-04T18:24:38Z  191MiB
  2026-09-04T18:24:53Z  191MiB
  2026-09-04T18:25:08Z  181MiB
  2026-09-04T18:25:23Z  180MiB
  2026-09-04T18:25:38Z  183MiB
  2026-09-04T18:25:53Z  185MiB
  2026-09-04T18:26:08Z  184MiB
  2026-09-04T18:26:24Z  184MiB
[leak] mid-third mean=185.8MiB  tail-third mean=184.0MiB  tail-drift=-0.94%
[leak] VERDICT: TAIL-FLAT (ok)

## Loss accounting — collector
[collector] accepted=65594978 refused=0 sent=123227538 send_failed=0
fan-out ratio sent/accepted=1.879 (>1 = multi-exporter, expected)
LOSS VERDICT: NO LOSS (refused=0, send_failed=0)

## Resource snapshot (working-set)
bench-collector-jjgff   33m   59Mi   
bench-collector-kpqzs   47m   60Mi   
bench-collector-tnh2n   55m   65Mi   
