# R1P3 attempt 2 (the pre-authorised retry) — ABORTED AT THE GATE, again

**Verdict: `df_engine:0.50.0` still cannot carry this workload. No timed run was started,
no `R1-P3-arrow` window exists, nothing is banked and nothing needs voiding.**

The ISI-1843 corrections were deployed exactly as committed and they bought **~68× more
life** — and then the engine died the same way, on all four cores, on smoke-level load,
before the 120-minute window could open.

---

## The deployment was the corrected one — proven, not assumed

`results/r1p3-smoke/config-provenance.sh -n default -c bench-otel-arrow-native-config`
→ **PROVENANCE VERIFIED**, exit 0: 9 nodes, connection graph identical to
`engines/df-engine-config.tmpl.yaml`, including `router`, `metrics_noop`, `parity`,
`batch_logs`/`batch_traces`. The endpoint matched too (this is the real tenant, not the
smoke sink), so there is not even the one disclosed smoke deviation. Banked:
`deployed-config.yaml`.

## Timeline — both attempts, same cluster, same apps, same Istio config

Attempt 1 = `results/r1p3-abort/engine-panic.log` (3s batch, metrics in-band).
Attempt 2 = `engine.log` (1s batch, metrics → `exporter:noop`).

| | attempt 1 (pre-ISI-1843) | attempt 2 (corrected) |
|---|---|---|
| engine start | 10:53:29.238Z | 14:59:03.934Z |
| `boo` — `crates/pdata/src/encode/record/metrics.rs:266` | **T+5.6s** (core 3) | **never — 0 occurrences** |
| first `DictionaryKeyOverflowError` | **T+23.0s** (core 1) | **T+26m10.5s** (core 0) |
| all four cores dead | **T+30.3s** | **T+33m34.2s** |
| panic sites seen | metrics.rs:266 ×1, `arrow-data-58.3.0/src/transform/mod.rs:680` ×3 | `crates/pdata/src/otap/transform/concatenate.rs:150` ×2, `arrow-data…mod.rs:680` ×2 |

**First-dictionary-panic to first-dictionary-panic: 23.0s → 1570.5s = 68× longer.**
All-four-dead: 30.3s → 2014.2s = 66× longer.

## What the retry settles, and what it does not

**Settled — change #1 works, exactly as predicted by construction.** Routing metrics to
`exporter:noop` removes the `boo` metrics-encoder panic site: **zero** occurrences in
attempt 2 against T+5.6s in attempt 1. (`boo` is separately already root-caused upstream
by draft PR #2984, unmerged at our SHA — see `results/r1p3-abort/`.)

**Settled — the ISI-1843 confound now has a direction.** That issue could not attribute
survival to change #1 (metrics route) vs change #3 (`max_batch_duration` 3s→1s). Attempt
2 shows change #3 **delays** the `DictionaryKeyOverflowError` by ~68× but does **not**
prevent it. The overflow is therefore accumulation-driven, not batch-size-gated: smaller
batches mean fewer distinct values merged per output array, so the dictionary key space
is exhausted later — not never. **Do not revert `max_batch_duration` to 3s** — it is
load-bearing for how long the engine survives at all.

**Settled — the smoke's survival was correctly flagged as non-decisive.** ISI-1843 banked
41m41s of survival and stated plainly that its reproducer was *partial* (no Istio mesh
spans, no hipster-shop) and that "survival is necessary but not sufficient". The real
workload falsified it in 26 minutes. That caveat did its job; the result is a
confirmation of the caveat, not a surprise.

**New — a second panic site, in df_engine's own code, and it fires FIRST.**
`crates/pdata/src/otap/transform/concatenate.rs:150:43` → `Compatible schemas:
DictionaryKeyOverflowError`, on 2 of 4 cores, and it is the earliest death (T+26m10.5s).
Attempt 1 only ever showed the `arrow-data` site. So the overflow surfaces at **two
independent concatenation points**, one of them an `expect()` inside otap-dataflow
itself. This strengthens the upstream report materially: it is not a single unlucky
call-site in a dependency.

**Not settled — whether a newer upstream build fixes it.** That is the board's
pre-authorised step 2 and the only remaining path before DNF.

## Load context — this died on smoke load, not on the benchmark load

Attempt 2 was carrying only the two apps' own loadgenerators. The timed run ramps
50→100→150→200 VU **per app** for 120 minutes. Since the failure is accumulation-driven,
higher load reaches the overflow sooner. A 120-minute window on this build would not have
survived its first ramp step, and — per ISI-1817's original lesson — the gate would have
kept reporting large, real, pre-panic numbers the whole time.

## The dead engine looks perfectly healthy to Kubernetes — and to the admin API's values

At the moment of capture, **40 minutes after the last core died**:

- pod `bench-otel-arrow-native-dffb66b55-kq6w2`: `1/1 Running`, `restarts=0`, `Ready`,
  container state `running` since 14:59:03Z. D12's pod census would pass this window
  cleanly, because nothing was ever *replaced*.
- admin API still answers 200 and still reports `memory.rss` **growing** (66,809,856 →
  67,469,312 bytes over 45s) at `cpu.utilization` = 8.4e-05.

**What is unambiguous is not the values — it is which metric sets exist.** See
`engine-alive.sh`.

## `engine-alive.sh` — engine-side liveness in one HTTP GET

When the cores die, df_engine **deregisters** every pipeline metric set and serves only
the process-level `engine` set:

| input | metric_sets | distinct names | verdict |
|---|---|---|---|
| `../r1p3-smoke/engine-counters-END.json` (healthy, END of the 41m smoke) | 289 | 17 | **ALIVE**, exit 0 |
| `../r1p3-smoke/engine-counters-T+11m.json` (healthy, low load) | 289 | 17 | **ALIVE**, exit 0 |
| `engine-counters-DEAD-A.json` (this run, T+40m after death) | **1** | **1** | **DEAD**, exit 1 |

Validated in both directions against two known-good inputs and one known-bad, with the
exit code checked directly rather than through a pipe.

`keep_all_zeroes=true` is passed deliberately: it proves the sets are **absent**, not
suppressed for reading zero. A "counters are zero" check cannot tell those apart, and a
cumulative counter proves the engine *worked*, never that it *works*.

This is strictly cheaper and strictly earlier than every sink-side check: no Grail
round-trip, no lookback window, and it is true the instant the threads die rather than
after the buffered backlog drains. The dumb `grep -c panic` on the engine log remains the
other check that caught it — both are engine-side, and both beat every sophisticated
sink-side check for this failure mode.

## Files

| file | what |
|---|---|
| `engine.log` | full 49-line container log, ANSI stripped — the whole failure |
| `engine-pod.json` | pod state at capture: Ready, 0 restarts, running since 14:59:03Z |
| `deployed-config.yaml` | the ConfigMap that actually ran |
| `engine-counters-DEAD-A.json` / `-B.json` | admin API, 45s apart, cores long dead |
| `engine-alive.sh` | the liveness detector, with its controls documented in-file |
