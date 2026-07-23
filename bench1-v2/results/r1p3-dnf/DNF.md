# B1-v2 — the OTel-Arrow (native `df_engine`) arm is **DNF**

**Declared 2026-07-23 by the Observability Agent under ISI-1849, on the board's pre-authorisation
of 2026-07-23 13:45Z ("one rebuild from a newer upstream commit, retry once, then stop").**
No further board decision is required. The rebuild was **not** spent, because step 0 established
it could not change the outcome — see `STEP0-UPSTREAM-DELTA.md`.

DNF = *Did Not Finish*. The arm produced **no timed 120-minute run, no register row, no
comparable numbers** in either round. It is not a slow result or a bad result; there is no result.

## Why

`ghcr.io/isitobservable/df_engine:0.50.0` (otap-df built from otel-arrow main @ `7502e7d`,
2026-07-20) cannot survive the benchmark's own workload for the duration of a run.

| attempt | config | first panic | all 4 cores dead |
|---|---|---|---|
| 1 (`r1p3-abort`) | original, one shared pipeline for all 3 signals | `boo` T+5.6s, `DictionaryKeyOverflowError` **T+23.0s** | **T+30.3s** |
| 2 (`r1p3-retry`) | ISI-1843 corrected: metrics → `exporter:noop`, `max_batch_duration` 3s→1s | `DictionaryKeyOverflowError` **T+26m10.5s** | **T+33m34.2s** |

Both aborted **at the validation gate, before any timed load**, on smoke-level traffic. The
intended run is a 120-minute ramp to 200 VU per app — four times the length at several times the
rate — so the arm was never within reach of finishing.

Attempt 2's provenance was verified (deployed ConfigMap semantically identical to the committed
template, 9 nodes, exit 0), so this is evidence about the *corrected* configuration, not a stale
one.

## What the two attempts jointly establish

1. **The ISI-1843 fix works on the part it was aimed at.** `boo`
   (`crates/pdata/src/encode/record/metrics.rs:266`) went to **0 occurrences** — routing metrics
   to `exporter:noop` removes that site by construction, exactly as predicted.
2. **The dictionary overflow is accumulation-driven, not batch-size-gated.** 68× more life,
   identical ending. Smaller batches merge fewer distinct values per output array, so the key
   space is exhausted *later*, never *not*. Higher load reaches it sooner — which is why a
   120-minute ramp at 50→200 VU is not survivable on this build.
3. **It is not metrics-specific.** Attempt 2 had the metrics path fully disconnected and still
   died, on traces and logs alone.
4. **There are two independent overflow sites**, and the one that fired *first* is inside
   otap-dataflow itself: `crates/pdata/src/otap/transform/concatenate.rs:150` (2 of 4 cores), the
   other being `arrow-data-58.3.0/src/transform/mod.rs:680` (2 of 4). A fix confined to the
   dependency boundary would leave the first exposed.
5. **A newer upstream build cannot help today.** All 13 commits in `7502e7d..main` (to
   `51b864b9`, 2026-07-23 15:08Z) leave `crates/pdata/src/otap/transform/` untouched;
   `concatenate.rs` is byte-identical; the `arrow-*` lock bump 58.3.0→58.4.0 is a
   parquet-encryption maintenance release that changes nothing under either panic site. Full
   evidence and reproduction commands in `STEP0-UPSTREAM-DELTA.md`.

## Scope of the DNF — what is cancelled, what is not

**Cancelled:**

- `R1-P3-arrow` (ISI-1817) — never ran.
- `R2-P3-arrow` (ISI-1820) — replication of a run that does not exist.
- Soak S3, OTel-Arrow native 24h leak soak (ISI-1824) — the engine dies in ~26 minutes under
  this workload; a 24-hour soak has nothing to measure.

**Not affected — these stand and remain fully comparable to each other:**

- `R1-P1-collector` — otel-collector contrib 0.154.0, 120.6 min, banked.
- `R1-P2-fluentbit` — fluent-bit 5.0.9, 120.4 min, census MATCH, banked. Headline: ~36% less
  CPU per record than the collector, at ~20% more memory (peak +58.6%).
- `R2-P1-collector`, `R2-P2-fluentbit`, Soak S1, Soak S2 — unchanged, still scheduled.

The comparison therefore becomes **two engines, not three**. Nothing in the collector or Fluent
Bit arms depended on the arrow arm, and the load profile and the `hipster-shop/loadgenerator`
constant are untouched, so the remaining arms stay comparable across both rounds.

## This is itself a finding, and it should be published as one

"An engine we could not benchmark" is a weaker claim than a measurement, but it is not nothing,
and it is the most operationally useful thing this arm produced:

- df_engine at this commit **panics on ordinary production-shaped OTLP telemetry** — an
  ~20-service `opentelemetry-demo`, a second demo app, and service-mesh access-log spans, at
  smoke volume. Not a synthetic stress test.
- When a pipeline core panics it is **never restarted**. There is no new generation, no recovery.
- The process survives every core's death. Kubernetes reports the pod `Running`, `Ready`,
  `restarts=0`; resident memory keeps climbing; cumulative throughput counters hold their last
  healthy values, so a dashboard built on them shows no drop. We observed this state persist for
  ~40 minutes.
- The only cheap, unambiguous liveness signal we found is **which metric sets the admin API
  serves**: `GET /api/v1/metrics?format=json&keep_all_zeroes=true` returns **289 sets / 17 names**
  healthy and **1 set / 1 name** (`engine` only) once the cores are dead. Absent, not zeroed.
  `engine-alive.sh` in `../r1p3-retry/` implements this; validated on 2 known-good and 1
  known-bad pod.

Reported upstream as **open-telemetry/otel-arrow#3561** (filed 2026-07-23T16:17:29Z, labelled
`bug` / `triage:deciding`). One upstream action remains outstanding — see below.

## Outstanding: the #3561 correction

#3561 as filed still says the workaround "ran 41 minutes with zero panics". That 41-minute run
was ISI-1843's **deliberately reduced** reproducer — no service mesh, no second application —
and it labelled itself partial at the time. Attempt 2 falsified the implication: the *same*
corrected config on the *full* workload died at T+26m10s. A maintainer reading #3561 today would
reasonably conclude the `type_router` workaround resolves the problem. It does not; it delays it.

The correction is drafted and scrubbed at `../r1p3-abort/UPSTREAM-3561-FOLLOWUP.md`, ready to
paste. **Henrik owns the upstream account and posts it** — the runner has no write credential and
this agent does not publish to third-party repositories unprompted.

## The lesson worth keeping

**A reduced reproducer cannot clear a failure whose trigger is cardinality — the reduction
removes exactly the thing that kills you.** ISI-1843's smoke ran 41 minutes and correctly called
itself partial. We shipped it as a green light anyway, and the real workload falsified it in 26
minutes. The caveat was written down, in the right place, and still cost a phase. **A stated
caveat is not a mitigation.** Either the rig carries the trigger, or the result cannot clear the
risk — which is why ISI-1849's step 2 demanded ≥45 minutes at full fidelity, longer than the
26-minute observed death, before it would count.
