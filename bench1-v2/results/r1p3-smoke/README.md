# ISI-1843 — R1P3 reproducer smoke, and the arrow arm's engine-side gate

Two separate things live here. Read the second one even if you don't care about the first.

## 1. The smoke run (Q1 step 1) — RESULT: SURVIVED

**41m41s** (engine start `14:07:46Z` → watch end `14:49:27Z`), **0 restarts, 0 panic lines**,
8878 OTLP requests started and 8878 completed, demo fully up at 22 pods, 650–910 spans/60s
sustained. **19/19 gate PASS on the END snapshot.** Full output in `VERDICT.txt`.

R1P3 had all four cores dead **30 seconds** after start, so this ran **~83x longer** than
the failure it was built to reproduce.

The zero-panic assertion was checked against a positive control rather than taken at face
value: the engine log is 27 real lines, a word that *should* appear matches 14 of them, and
the panic-class pattern matches 0. A failed `kubectl logs` would also have grepped to 0.

⚠️ **This does NOT establish that excluding metrics fixed the engine — see the confound
below.** Two of the three shipped changes plausibly bear on the majority panic.


Corrected `df_engine` 0.50.0 + `otel-demo` 0.40.10 on `observable-agentsandbox`, off the
benchmark cluster. `watcher.log` samples readiness, restarts, panic lines and sink
throughput every 30s. `smokewatch.sh` is the sampler.

⚠️ **This is a PARTIAL reproducer and a survival result is necessary but not sufficient.**
`observable-agentsandbox` has no Istio (so no mesh spans) and no hipster-shop. The R1P3
abort was fed by both. It cannot retire the `DictionaryKeyOverflowError` risk — that was
the *majority* failure and is generic Arrow encoding on high-cardinality attributes, not
something the metrics route touches. A **panic** here would be decisive; survival is not.

### ⚠️ And survival has TWO candidate causes, which this smoke cannot separate

Whatever the outcome, **do not let it be read as "excluding metrics fixed the engine".**
Three changes shipped together and two of them plausibly bear on the majority panic:

| panic site | R1P3 timing | which change could remove it |
|---|---|---|
| `crates/pdata/src/encode/record/metrics.rs:266` — literal `boo` | core 3 at **T+5s** | **change #1** removes it *by construction* — the encoder is never reached, metrics die at `noop`. Certain. |
| `arrow-data-58.3.0/src/transform/mod.rs:680` — `DictionaryKeyOverflowError` | cores 1/0/2 at **T+23s / T+29s / T+30s** | **change #1 OR change #3.** Not established either way. |

`MutableArrayData::new` is the array **merge** path, and a dictionary key overflows when the
merged dictionary holds more distinct values than the key type can index. Change #3 cut
`max_batch_duration` 3s→1s, so at a fixed arrival rate roughly a third as many records are
merged into each output array — which cuts the distinct values per merged dictionary. That
is a mechanism by which the *batch* change alone could suppress the *majority* panic,
independently of the metrics route.

Two consequences:

1. **ISI-1817 may not conclude that routing metrics away is what fixed it.** The clean
   experiment (corrected routing, batch back at 3s) was never run and is not worth a
   benchmark slot — but the claim must not be made without it.
2. **Change #3 is now potentially load-bearing for stability, not just parity alignment.**
   Reverting `max_batch_duration` to 3s to "restore engine-idiomatic batching" would be
   changing a variable that may be holding the engine up. Note it before anyone proposes it.

Grounding: all 4 cores were dead **30 seconds** after start in R1P3 (engine up 10:53:29,
last panic 10:53:59). Read the smoke's elapsed time against that 30s, not against 120 min.

## 1b. `config-provenance.sh` — is the engine running the COMMITTED config?

Run this **before trusting any smoke or benchmark result**. "The repo is correct" and "the
cluster is running what the repo says" are two independent assertions, and the second
decays every time someone `kubectl edit`s. Here the smoke ConfigMap is even *named*
`df-nodeproof-config` — a leftover from the node-proof work — so the name is actively
misleading and only the content settles it.

**PROVENANCE VERIFIED**: all 9 nodes and the full connection graph are identical to
`engines/df-engine-config.tmpl.yaml`; the only deviation is the exporter destination
(`http://sink.dfsmoke...:4318` vs the tenant), which is the intended, disclosed smoke swap
and is redacted before comparison.

It compares the **semantic node graph, not the text**, for two reasons that both bit me:

- kubectl re-serialises the stored copy (comments stripped, flow maps expanded to block
  style), so a plain `diff` is ~100 lines of pure noise.
- `grep -c` is worse than useless — the template's *header comments* mention
  `processor:type_router` and `min_size: 1000`, so a naive count reports
  `template=2 deployed=1` and reads as a mismatch when nothing is wrong.

Verified against a known-bad input too: flipping `max_batch_duration` to 3s in the template
yields 2 FAILs and **exit 1** (both gates' exit codes were checked to propagate, not just
their printed verdicts — a gate that prints FAIL and exits 0 silently passes automation).

## 2. `engine-counters.sh` — the arrow arm has an engine-side gate after all

ISI-1817 recorded *"df_engine's admin port serves HTML, so there are no engine-side
counters"*. **That is wrong**, and the note has been corrected. The HTML is a UI that polls

    GET /api/v1/metrics?format=json&reset=false&keep_all_zeroes=true

returning the full internal metric set per node per core. Found by reading the UI's own
`/static/js/main.js` → `metrics-api.js`. *"The UI is HTML" is not evidence there is no API.*

`engine-counters.sh` fetches that and asserts 19 invariants. **19/19 PASS against both
banked snapshots** — `engine-counters-T+11m.json` (low load, ~1 req/s) and
`engine-counters-T+26m.json` (~4.5 req/s). Two known-good inputs, not one, on purpose.

    ./engine-counters.sh -n dfsmoke -d df-engine       # live
    ./engine-counters.sh --no-fetch engine-counters-T+26m.json   # replay

## ⚠️ On this arm `received != exported` is EXPECTED and is NOT loss

At T+26m the router had received 2147 log signals and the exporter had exported 1440. That
looks like a 33% loss. It is not. The 1s batch timer **coalesces** several inbound requests
into one outbound batch — measured **1.49× logs / 1.56× traces** at ~4.5 req/s, and 1.01×
at ~1 req/s, so the ratio *moves with load* and no fixed threshold can be right.

A naive run-day delivery check comparing `router.received` to `exporter.exported` would
therefore **false-FAIL a perfectly healthy engine**, and would do it worse the busier the
run got. Same class of error as the `attr-landing.sh` step-7b stale prediction.

The correct loss detector is the **conservation law at each hop**, which must hold exactly
and is independent of the coalescing ratio:

    router.signals.received.X == batch.consumed.batches.X     (nothing lost router -> batch)
    batch.produced.batches.X  == exporter.X.exported          (nothing lost batch -> exporter)

Both hold exactly on both snapshots. `mutants.py` covers the two ways this can silently
break (`m_loss`, `m_routerloss`) — the cases coalescing would otherwise mask.

Corollary worth carrying: `flushes.size = 0` on every core in both snapshots. Even at 4472
requests, `otap.min_size: 1000` is never reached, so **the 1s timer is the sole flush
driver** and the disclosed batch-size asymmetry has no measurable effect at this load.

### Why these counters and not the sink's

`0 metrics at the sink` is satisfied three ways: a deliberate route, a **dead engine**, and
a generator that **never sent metrics**. Two of those are failures. The gate therefore
asserts the mechanism — `received.metrics > 0` **and** `routed.named.metrics == received`
**and** `exporter.metrics.exported == 0` — not the outcome.

Likewise `signals.routed.default.* == 0` is load-bearing: the router falls back to the node
default port when a named port is **not connected at all**, so a typo in `outputs:` still
"works", quietly, down the wrong path.

### The gate's own detection rate — measured, not asserted

A green gate is a claim. `mutants.py` mutates a known-good snapshot into ten ways this
arm can silently be wrong and requires the gate to fail on each: **10/10 caught.**

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
| `m_loss` | silent loss between batch and exporter — the case coalescing masks |
| `m_routerloss` | silent loss between router and batch |

### One reading trap, which cost me a false alarm

Each `metric_set` is scoped to one **(node, core)**, and `mmsc` instruments expose
`{min,max,sum,count}`. **min/max are not summable across sets.** Summing them made
`flush.age.duration` read as ~8s against a configured 1s — an apparent regression that
did not exist. Aggregate `sum`/`count`; take min-of-min and max-of-max. Per node the real
figure is **1.000–1.004s on every core**, with `flushes.size = 0` and every flush driven by
the timer: `max_batch_duration: 1s` is confirmed in effect at runtime, and `otap.min_size:
1000` is never reached at this load (disclosed, unchanged, engine-idiomatic).

## Reproducing this smoke from scratch

    kubectl apply -f smoke.yaml                       # ns dfsmoke: df-engine + counting sink
    helm install otel-demo open-telemetry/opentelemetry-demo --version 0.40.10 \
      -n otel-demo --create-namespace -f demo-values-smoke.yaml
    ./config-provenance.sh                            # FIRST — is it the committed config?
    ./smokewatch.sh &                                 # samples every 30s
    ./engine-counters.sh -n dfsmoke -d df-engine      # 19 invariants

⚠️ The ConfigMap in `smoke.yaml` is named **`df-nodeproof-config`** — a leftover from the
node-proof work. The name is wrong and misleading; the *content* is the corrected arm
config, which is exactly why `config-provenance.sh` exists and must be run first.

Teardown is `kubectl delete ns dfsmoke otel-demo` plus `helm uninstall otel-demo -n
otel-demo`. Nothing else on `observable-agentsandbox` is touched — both namespaces were
created by this test and contained only its own objects (verified before deleting, the
same constant-vs-contaminant check that protected `hipster-shop/loadgenerator`).

**Teardown verified**: 14 namespaces before, 10 after, exactly the 4 this test created
(`otel-demo`, `dfsmoke`, `dfnodeproof`, `isi1843`), 0 leftover objects cluster-wide, 0 Helm
releases. ⚠️ One trap met on the way: `kubectl -n <ns> get all` prints
`No resources found in <ns> namespace.` for a namespace that **does not exist at all** —
identical to an empty one. It made a missing namespace read as "present but empty". To ask
whether a namespace exists, ask `kubectl get ns <name>`, which returns `NotFound`.
