# Tier 3 (logs+metrics+traces, NO tail sampling) — ARM 2 FB v5.1.1 — 2h validity gate
generated: 2026-09-14T01:16:13Z · engine=fluentbit-v5.1.1 · load=locust+k6+telemetrygen(traces@200 --otlp-http :4318)

## Census gate
bench-fluentbit-logs-6mzv2 0 122m
bench-fluentbit-logs-7njbz 0 122m
bench-fluentbit-logs-tg2hn 0 122m
bench-fluentbit-metrics-0 0 122m
bench-fluentbit-traces-744898b4b5-q8vkn 0 122m
kepler-2xgll 0 11d
kepler-5jsm7 0 11d
kepler-c4ldd 0 11d
kepler-qhtc5 0 11d
NAMESPACE          POD                                PHASE      RESTARTS  ROLE   
bench-fluentbit    bench-fluentbit-logs-6mzv2         Running    0         STRICT 
bench-fluentbit    bench-fluentbit-logs-7njbz         Running    0         STRICT 
bench-fluentbit    bench-fluentbit-logs-tg2hn         Running    0         STRICT 
bench-fluentbit    bench-fluentbit-metrics-0          Running    0         STRICT 
bench-fluentbit    bench-fluentbit-traces-744898b4b5-q8vkn Running    0         STRICT 
kepler             kepler-2xgll                       Running    0         STRICT 
kepler             kepler-5jsm7                       Running    0         STRICT 
kepler             kepler-c4ldd                       Running    0         STRICT 
kepler             kepler-qhtc5                       Running    0         STRICT 
otel-demo          accounting-799d56d5f5-wkz2c        Running    0         source 
otel-demo          ad-9c69f9686-5tcrw                 Running    0         source 
otel-demo          cart-7789dc7575-ptmwp              Running    0         source 
otel-demo          checkout-86468654d7-g2htm          Running    0         source 
otel-demo          currency-65d9467895-qfptq          Running    0         source 
otel-demo          email-8c8564f57-sg5zm              Running    0         source 
otel-demo          flagd-6946bb88cd-g9qgh             Running    0         source 
otel-demo          fraud-detection-b87fffcdf-4fcvg    Running    0         source 
otel-demo          frontend-5b7fb8844f-5f8v2          Running    0         source 
otel-demo          frontend-proxy-6bb789597d-dj9wh    Running    0         source 
otel-demo          image-provider-76c46f5d69-4hm6c    Running    0         source 
otel-demo          kafka-5bd9dc6bb9-g429x             Running    0         source 
otel-demo          llm-6c9779b558-tb9fp               Running    0         source 
otel-demo          load-generator-57fd5dddff-b9qhv    Running    5         source 
otel-demo          payment-745df48ddf-wsrv7           Running    0         source 
otel-demo          postgresql-775ccb994b-xx8tb        Running    27        source 
otel-demo          product-catalog-7875bcb8dd-ccxq5   Running    10        source 
otel-demo          product-reviews-b78b54859-f4464    Running    0         source 
otel-demo          quote-5c4fcdc84d-qr7rq             Running    0         source 
otel-demo          recommendation-758765697d-jmgqh    Running    0         source 
otel-demo          shipping-84f8b5dfd7-rzk6g          Running    0         source 
otel-demo          valkey-cart-6c74b8cc4c-hw69k       Running    0         source 
hipster-shop       adservice-64db44f966-9nrl5         Running    13        source 
hipster-shop       cartservice-78c74fbbcf-vp5tm       Running    8         source 
hipster-shop       checkoutservice-f4677b8c4-cl4z5    Running    5         source 
hipster-shop       currencyservice-59bd4fd785-b9qk2   Running    1492      source 
hipster-shop       emailservice-6567d46c9d-s7rl2      Running    6         source 
hipster-shop       frontend-79cb8766c8-9lsdm          Running    8         source 
hipster-shop       paymentservice-75f5c95477-6mlq5    Running    25        source 
hipster-shop       productcatalogservice-59dc6bb7d-hpzdj Running    5         source 
hipster-shop       recommendationservice-84c69dbdfd-xm64p Running    9         source 
hipster-shop       redis-cart-6b7c8c4556-bfbpg        Running    1021      source 
hipster-shop       shippingservice-669789cc48-sv5zx   Running    0         source 
CENSUS GATE: PASS — engine+infra (STRICT) Running & 0-restart; all log-source apps Running.

## Load check
[load] locust pod=Running reqs=446830 | k6 pod=Running | tgen-traces pod=Running (--otlp-http :4318)
[load] LOAD REACHING APP: PASS

## DT receipt (FB output proc_records / dropped)
[dt-receipt] bench-fluentbit-logs-6mzv2 proc=1311023 dropped=0
[dt-receipt] bench-fluentbit-logs-7njbz proc=512628 dropped=0
[dt-receipt] bench-fluentbit-logs-tg2hn proc=2778478 dropped=0
[dt-receipt] bench-fluentbit-metrics-0 proc=976 dropped=0
[dt-receipt] bench-fluentbit-traces-744898b4b5-q8vkn proc=730295 dropped=0
[dt-receipt] TOTAL proc_records=5333400 dropped=0 (logs+metrics+traces)
[dt-receipt] VERDICT: RECEIVED IN DYNATRACE (all signals processed, 0 dropped)

## Resource snapshot
bench-fluentbit-logs-6mzv2                26m   13Mi    
bench-fluentbit-logs-7njbz                14m   8Mi     
bench-fluentbit-logs-tg2hn                76m   21Mi    
bench-fluentbit-metrics-0                 2m    6Mi     
bench-fluentbit-traces-744898b4b5-q8vkn   39m   146Mi   
