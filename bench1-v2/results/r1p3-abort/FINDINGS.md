# R1-P3-arrow — ABORTED AT THE GATE. `df_engine:0.50.0` cannot carry this workload.

**ISI-1817, 2026-07-23. No timed run was started. There is no R1-P3-arrow window to read.**

The validation gate went RED on CHECK 5 and the phase stopped there, exactly as the
runbook requires. This file is the evidence.

---

## Summary

`ghcr.io/isitobservable/df_engine:0.50.0` **panics on real telemetry from this
benchmark's workload and all four pipeline cores die within a minute.** It is
deterministic — reproduced on two independent pods. The engine cannot survive a
120-minute run, so R1P3 cannot produce a comparable measurement.

Deployment itself was clean. Every other gate check passed. The engine received data
and exported it correctly for the first ~3 minutes, then stopped permanently.

---

## The failure

Two distinct panic sites, both in the OTAP/Arrow encoding path:

| # | site | message | frequency |
|---|---|---|---|
| 1 | `crates/pdata/src/encode/record/metrics.rs:266:13` | `boo [21, 21, 21, 7, 21, 21, 21, 21, 21, 21]` | 1 of 4 cores (run 2), 3 of 4 (run 1) |
| 2 | `arrow-data-58.3.0/src/transform/mod.rs:680:31` | `MutableArrayData::new is infallible: DictionaryKeyOverflowError` | 3 of 4 cores (run 2), 1 of 4 (run 1) |

Panic 1 is an unfinished assertion in df_engine's own OTAP **metrics** record encoder —
the message is the literal string `boo`, and the array is ten lengths with one odd
element (`7` among `21`s), i.e. a column-length mismatch check.

Panic 2 is an Arrow **dictionary key overflow**: more distinct values than the
dictionary key type can index. It is *not* obviously metrics-specific, which matters
for remediation — see "What this does and does not tell us".

Each panic kills its pipeline core with
`otap-df-controller::controller.pipeline_runtime_failed`. **There is no restart, no
new generation, no recovery.** Once all four cores are down the process keeps running
and accepts connections while processing nothing.

## Timeline — reproduced twice

| run | pod | started | first core dead | all 4 dead | survival |
|---|---|---|---|---|---|
| 1 | `bench-otel-arrow-native-dffb66b55-thlng` | 10:43:13Z | 10:45:59Z | 10:46:21Z | **3m 08s** |
| 2 | `bench-otel-arrow-native-56677dc765-6tlc8` | 10:53:32Z | ~10:53:50Z | 10:54:20Z | **~48s** |

Run 2 died faster because the app SDKs had ~7 minutes of queued telemetry to retry, so
the engine met a burst immediately. **Time-to-death shortens as backlog grows**, which
rules out any "restart it periodically" workaround: after each death the next start
faces a larger backlog.

## Why the gate nearly passed it — read this part

The engine had been dead for six minutes when the gate ran, and the gate still reported:

```
CHECK 2 PASS app-spans      otel-demo=16541  hipster-shop=18090
CHECK 5b sink-side per-signal: spans=31426 logs=1950 metric-series=1
CHECK 5b cluster-filter safe for spans (31426 of 31426)
CHECK 6 PASS pod-census     pods=1  expected-replicas=1
```

Every one of those numbers is real and every one is **pre-panic data inside a 15-minute
lookback window**. Measured directly: `fetch spans ... from:now()-6m` returned **0**.

The pod is the reason this is dangerous. Kubernetes reports it `Ready`, `restarts=0`,
`Running` — because the *process* is alive; only its worker threads are gone. So:

- the liveness/readiness view is green,
- **the D12 pod census passes** (one pod, alive in every bucket, never replaced),
- and the throughput counters look healthy right up to the moment of death.

**Only the error-log-line check caught this.** Eight lines. Had CHECK 5 not counted
`observed_error`/`panic` lines, a 120-minute run would have been started on a dead
engine and produced a full set of plausible, comparable-looking, entirely fictional
numbers — the R1P2 lesson (a signal dead while aggregates look fine) in its most
complete form. A window can be perfectly valid and contain nothing.

## What this does and does not tell us

**Established:**
- The panic is deterministic, not a startup race, and not load-dependent in any way we
  can dodge — it fires at ordinary smoke volume.
- All three signals share **one** pipeline (`otlp_in → enrich → parity → batch → dt_out`,
  no per-signal routing), so any core panic is a total outage for traces *and* logs
  *and* metrics on that core.
- Dynatrace also returned `400 Bad Request` on `/v1/metrics` at 10:46:11 — the metrics
  payload the engine produced was rejected as malformed, independently corroborating a
  defect in the metrics encoder.

**Not established — do not assume:**
- **That excluding metrics would fix it.** Panic 2 (dictionary overflow) was the
  *majority* failure on the fresh pod and is a generic Arrow encoding fault. It may well
  fire on high-cardinality span/access-log attributes with metrics entirely absent. This
  is testable but was not tested, because testing it means changing the frozen config.
- Whether a later `df_engine` build fixes either panic.

## Consequences for the campaign

- **There is no R1-P3-arrow run register row**, because there is no run. Nothing was
  banked; nothing needs voiding.
- R1P1 (collector) and R1P2 (Fluent Bit) are unaffected and remain valid and comparable.
- The engine under test is the *only* thing that failed. Deployment, Istio wiring,
  sidecars, app health, and attribute landing were all correct — step 7b returned
  `spans=SAFE logs=SAFE metrics=SAFE`, matching the off-cluster prediction exactly, and
  `k8s.cluster.name` lands on 100% of all three signals for this engine.

## State left behind

The engine and both apps are **left deployed**, so a retry under a board decision is
immediate. No teardown was run: `teardown.sh` gates on a banked End timestamp and
census, and there is no run to bank. `hipster-shop/loadgenerator` untouched.

Evidence: `engine-panic.log` (full log of pod 2, token-free, 4× `pipeline_runtime_failed`).
