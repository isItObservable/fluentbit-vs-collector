# Tier 1 (logs only) — ARM 2 fluent-bit — 2h validity gate readout
generated: 2026-09-04T20:39:30Z · engine=fluent-bit 5.1.1 (single, collector torn down) · load=locust(otel-demo)+k6(hipster-shop)

## Census gate (validity FIRST — engine+infra STRICT, apps liveness-only)
NAMESPACE POD PHASE RESTARTS ROLE
bench-fluentbit bench-fluentbit-f4vpr Running 0 STRICT
bench-fluentbit bench-fluentbit-jsct8 Running 0 STRICT
bench-fluentbit bench-fluentbit-qq2vj Running 0 STRICT
kepler kepler-2xgll Running 0 STRICT
kepler kepler-5jsm7 Running 0 STRICT
kepler kepler-c4ldd Running 0 STRICT
kepler kepler-qhtc5 Running 0 STRICT
otel-demo accounting-65b5fb67bb-nswdk Running 0 source
otel-demo ad-6b645785b4-rzjl5 Running 0 source
otel-demo cart-5896c58756-5l68j Running 0 source
otel-demo checkout-79448f79f8-4z87w Running 0 source
otel-demo currency-675b4cd4d7-4sglp Running 0 source
otel-demo email-6b9cfc85d5-ww5fw Running 0 source
otel-demo flagd-dd694f745-tqqvv Running 0 source
otel-demo fraud-detection-7f644f7ffd-s9rs9 Running 0 source
otel-demo frontend-7b6d8b7bdf-fpvlx Running 0 source
otel-demo frontend-proxy-7f7cf96f6b-fjfqz Running 0 source
otel-demo image-provider-7b6bc86c5c-h8xxr Running 0 source
otel-demo kafka-56c88fdbcc-wzv22 Running 0 source
otel-demo llm-75f57cc658-nn89c Running 0 source
otel-demo load-generator-695bcd96dc-gb9g5 Running 0 source
otel-demo payment-6cd49fc797-d9vrh Running 0 source
otel-demo postgresql-6869b5c65-w6j9v Running 5 source
otel-demo product-catalog-788cc66c6b-z5pf6 Running 0 source
otel-demo product-reviews-7d9fd96d4c-szmdq Running 0 source
otel-demo quote-6689979fdb-t5sqb Running 0 source
otel-demo recommendation-84696bc4b6-mgrtz Running 0 source
otel-demo shipping-86b9954bc5-sqj9k Running 0 source
otel-demo valkey-cart-747697db59-9f96x Running 3 source
hipster-shop adservice-64db44f966-9nrl5 Running 0 source
hipster-shop cartservice-78c74fbbcf-vp5tm Running 0 source
hipster-shop checkoutservice-f4677b8c4-cl4z5 Running 0 source
hipster-shop currencyservice-59bd4fd785-b9qk2 Running 49 source
hipster-shop emailservice-6567d46c9d-s7rl2 Running 0 source
hipster-shop frontend-79cb8766c8-9lsdm Running 0 source
hipster-shop paymentservice-75f5c95477-6mlq5 Running 0 source
hipster-shop productcatalogservice-59dc6bb7d-hpzdj Running 0 source
hipster-shop recommendationservice-84c69dbdfd-xm64p Running 0 source
hipster-shop redis-cart-6b7c8c4556-bfbpg Running 171 source
hipster-shop shippingservice-669789cc48-sv5zx Running 0 source
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running.

## App churn during run (WARNING-only)
[app-churn] log-source pods restarted DURING run (WARNING, non-fatal — logs kept flowing): 3
    otel-demo/postgresql-6869b5c65-w6j9v rc=5 OOMKilled @2026-09-04T20:19:00Z
    hipster-shop/currencyservice-59bd4fd785-b9qk2 rc=49 Error @2026-09-04T20:38:48Z
    hipster-shop/redis-cart-6b7c8c4556-bfbpg rc=171 OOMKilled @2026-09-04T20:32:44Z

## Load reaching app gate (#6c)
[load] locust(otel-demo) pod=Running aggregated_reqs=424300 | k6(hipster-shop) pod=Running iterations=105288
[load] LOAD REACHING APP: PASS

## Dynatrace receipt gate (signal RECEIVED IN DYNATRACE)
[dt-receipt] FB otel-output proc=2558779 dropped=0 errors=0
[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (otel output, 0 dropped/errors)

## Leak readout — fluent-bit (tail-flat)
[leak] bench-fluentbit — 12 samples @ 15s (needs metrics-server)
  2026-09-04T20:39:37Z 40MiB
  2026-09-04T20:39:52Z 47MiB
  2026-09-04T20:40:07Z 38MiB
  2026-09-04T20:40:22Z 36MiB
  2026-09-04T20:40:37Z 39MiB
  2026-09-04T20:40:52Z 38MiB
  2026-09-04T20:41:07Z 44MiB
  2026-09-04T20:41:22Z 44MiB
  2026-09-04T20:41:37Z 43MiB
  2026-09-04T20:41:52Z 38MiB
  2026-09-04T20:42:07Z 39MiB
  2026-09-04T20:42:23Z 40MiB
[leak] mid-third mean=41.2MiB tail-third mean=40.0MiB tail-drift=-3.03%
[leak] VERDICT: TAIL-FLAT (ok)

## Loss accounting — fluent-bit
[fluentbit] input=2644894 output=2643510 dropped=0 errors=0
loss%=0.0000 (dropped/input)

## Live cost spot-sample (mc/1M; sustained = computed from gate->final records delta at processing)
[cost] t0 records=2647075; sampling CPU over 60s...
[cost] delta_records=30716 avg_millicores=115.0 window=60s
[cost] COST-PER-1M = 3743.98 millicores/1M records

## Resource snapshot (working-set)
bench-fluentbit-f4vpr 55m 18Mi
bench-fluentbit-jsct8 15m 9Mi
bench-fluentbit-qq2vj 19m 13Mi
