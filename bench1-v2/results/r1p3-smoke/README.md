# ISI-1843 — R1P3 reproducer smoke, and the arrow arm's engine-side gate

Two separate things live here. Read the second one even if you don't care about the first.

## 1. The smoke run (Q1 step 1)

Corrected `df_engine` 0.50.0 + `otel-demo` 0.40.10 on `observable-agentsandbox`, off the
benchmark cluster. `watcher.log` samples readiness, restarts, panic lines and sink
throughput every 30s. `smokewatch.sh` is the sampler.

⚠️ **This is a PARTIAL reproducer and a survival result is necessary but not sufficient.**
`observable-agentsandbox` has no Istio (so no mesh spans) and no hipster-shop. The R1P3
abort was fed by both. It cannot retire the `DictionaryKeyOverflowError` risk — that was
the *majority* failure and is generic Arrow encoding on high-cardinality attributes, not
something the metrics route touches. A **panic** here would be decisive; survival is not.

## 2. `engine-counters.sh` — the arrow arm has an engine-side gate after all

ISI-1817 recorded *"df_engine's admin port serves HTML, so there are no engine-side
counters"*. **That is wrong**, and the note has been corrected. The HTML is a UI that polls

    GET /api/v1/metrics?format=json&reset=false&keep_all_zeroes=true

returning the full internal metric set per node per core. Found by reading the UI's own
`/static/js/main.js` → `metrics-api.js`. *"The UI is HTML" is not evidence there is no API.*

`engine-counters.sh` fetches that and asserts 15 invariants. Against the live snapshot
(`engine-counters-T+11m.json`, T+11m under real otel-demo load): **15/15 PASS**.

    ./engine-counters.sh -n dfsmoke -d df-engine       # live
    ./engine-counters.sh --no-fetch engine-counters-T+11m.json   # replay

### Why these counters and not the sink's

`0 metrics at the sink` is satisfied three ways: a deliberate route, a **dead engine**, and
a generator that **never sent metrics**. Two of those are failures. The gate therefore
asserts the mechanism — `received.metrics > 0` **and** `routed.named.metrics == received`
**and** `exporter.metrics.exported == 0` — not the outcome.

Likewise `signals.routed.default.* == 0` is load-bearing: the router falls back to the node
default port when a named port is **not connected at all**, so a typo in `outputs:` still
"works", quietly, down the wrong path.

### The gate's own detection rate — measured, not asserted

A green gate is a claim. `mutants.py` mutates the known-good snapshot into eight ways this
arm can silently be wrong and requires the gate to fail on each: **8/8 caught.**

| mutant | what it models |
|---|---|
| `m_dead` | every counter zero — the classic tautology-satisfier |
| `m_neversent` | generator never sent metrics — the *other* tautology-satisfier |
| `m_typo` | `outputs:` typo, metrics fall through to the default port |
| `m_leak` | metrics reach the exporter; the drop silently stopped working |
| `m_batch3s` | batch reverted from 1s to 3s |
| `m_bErr` | batch conversion drops |
| `m_stall` | receiver accepts but never completes |
| `m_noenrich` | enrichment silently no-ops |

### One reading trap, which cost me a false alarm

Each `metric_set` is scoped to one **(node, core)**, and `mmsc` instruments expose
`{min,max,sum,count}`. **min/max are not summable across sets.** Summing them made
`flush.age.duration` read as ~8s against a configured 1s — an apparent regression that
did not exist. Aggregate `sum`/`count`; take min-of-min and max-of-max. Per node the real
figure is **1.000–1.004s on every core**, with `flushes.size = 0` and every flush driven by
the timer: `max_batch_duration: 1s` is confirmed in effect at runtime, and `otap.min_size:
1000` is never reached at this load (disclosed, unchanged, engine-idiomatic).
