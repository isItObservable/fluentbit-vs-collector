# ISI-1879 arrow-rebuild smoke — VERDICT: **PASS** (the #3574/#3582 fix holds at runtime)

**2026-07-25, observable-agentsandbox.** The df_engine DNF (ISI-1849) is retired at the
smoke level: the rebuilt engine survives, under a concurrent positive control, the exact
workload that kills the DNF build.

## Result
`PASS_NEW_SURVIVES_OLD_FAILED : new_age=2780s : new_sets=633 : old=collapsed_to_1set_boo_metrics.rs266`

- **engine-new `df_engine:0.51.0` @ `git-eaf8f4cca694` (digest `sha256:0f85174d…`) — SURVIVED**
  46m20s continuous under live otel-demo fan-out load: 633 metric_sets, **0 DictionaryKeyOverflowError,
  0 `boo`, 0 `panicked`, 0 restarts, same pod** across 22 samples (`liveness2.csv`).
- **engine-old `df_engine:0.50.0` @ `7502e7d` (control) — DIED** on byte-identical load:
  collapsed to **1 set (`engine`)** via **2 `boo` panics at `crates/pdata/src/encode/record/metrics.rs:266`**
  (`boo [21,21,21,7,…]` = the DNF signature), both cores, 0 restarts (`engine-old-control-death.log`).

Same load, same window, one dies + one lives ⇒ the fix is the cause, not luck.

## What it validates
- **#3582 (boo metrics encoder) — CONFIRMED fixed at runtime.** Metrics were routed THROUGH the
  full pipeline (not to `noop`), so both engines' metrics OTAP-encode path was exercised; the old
  build panicked there, the new build did not.
- **#3574 (dictionary-overflow in OTAP concat) — strongly supported.** The new build ran the OTAP
  batch-concatenation path continuously for 46 min, far past the DNF's T+23s dictionary-overflow
  point, with 0 `DictionaryKeyOverflowError`. Site #2 (`arrow-data 58.4.0/transform/mod.rs:680`,
  unfixed at the dep level) did not trigger — #3574's `convert()` fallback keeps oversized
  dictionaries off that merge path, as designed.

## Rig / method
- Fan-out collector duplicates every signal from otel-demo (loadgen on) to both engines → local
  sinks. `smoke-rebuild.yaml` + `otel-demo-values-smoke.yaml`.
- Liveness = `engine-alive-051.sh` (0.51.0-aware; the DNF-era `engine-alive.sh` required a set
  named `receiver.otlp` that 0.51.0 renamed/split — see the false-positive note below). Proven
  non-blind: ALIVE exit0 on the 633-set snapshot, DEAD exit1 on the 1-set snapshot.
- Driver + corrected monitor ran detached (`setsid nohup`) surviving ~6 session teardowns.

## Caveat — the first driver banked a FALSE `FAIL_NEW_OVERFLOW`
Root cause: stale metric-set name, not an overflow. 0.51.0 split `receiver.otlp` →
`receiver.otlp.{requests,acknowledgements,rejections,transport}` (upstream #3437 per-signal
metrics, #3532 enum attributes) and total sets rose ~145→633, so the old grader flagged a
633-set HEALTHY pipeline as dead. Refuted directly (0 panic/boo/overflow in full logs); grader
fixed and re-validated both directions. `verdict` (the false one) is kept alongside `verdict2`
(the corrected one) as the record.

## Next (per ISI-1879)
R1P3-arrow (120-min ramp→200VU) → R2P3 replication → S3 24h soak on observable-otelarrow
(ISI-1779 D14 order, RUN-REGISTER, D12 census) → fold arrow back (2→3 engines) → report #3561.
