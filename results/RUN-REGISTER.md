# Run register

One row per phase. **This file is machine-read** — `benchmark/teardown.sh`
refuses to delete anything until this file carries a real End for the run
(gate G1) and an End census row (gate G2), because the End timestamp lives only
on the ramp pods that teardown is about to delete.

Keep the column order. Timestamps are ISO-8601 UTC to the second.

## Runs

| Run ID | Engine | Image | Round | Gate | Start (UTC) | End (UTC) |
|---|---|---|---|---|---|---|
| `R1-P1-collector` | otel-collector | `otel/opentelemetry-collector-contrib:0.154.0` | 1 | 6/6 | `2026-07-22T15:58:43Z` | `2026-07-22T17:59:21Z` |
| `R1-P2-fluentbit` | fluentbit-v5 | `fluent/fluent-bit:5.0.9` | 1 | 6/6 (blind on metrics — see note) | `2026-07-23T08:34:49Z` | `2026-07-23T10:35:12Z` |
| `R2-P1-collector` | otel-collector | | 2 | | | |
| `R2-P2-fluentbit` | fluentbit-v5 | | 2 | | | |

## Pod census

Per methodology rule D12: the engine must be **one continuous pod** for the whole
window, at ≥ 90% metric coverage. A pod *replacement* is invisible to restart
counters, so the census — not the restart tile — is the validity gate.

| Run ID | Point | Pod name | creationTimestamp | Pods | Restarts | Coverage | Verdict |
|---|---|---|---|---|---|---|---|
| `R1-P1-collector` | Start | `bench-otel-collector-collector-…` | recorded at run time | 1 | 0 | — | MATCH |
| `R1-P1-collector` | End | same pod | unchanged | 1 | 0 | 122/122 buckets | MATCH |
| `R1-P2-fluentbit` | Start | `bench-fluentbit-v5-67978b69d8-h8st4` | `2026-07-23T08:16:26Z` | 1 | 0 | — | MATCH |
| `R1-P2-fluentbit` | End | `bench-fluentbit-v5-67978b69d8-h8st4` | `2026-07-23T08:16:26Z` | 1 | 0 | 96.72% at capture / 98.36% replayed | MATCH |

> The two coverage figures for R1-P2 are the same window read ten minutes apart.
> **A coverage figure read minutes after a window closes understates itself** —
> the trailing buckets have not landed. The captured value is what the instrument
> read at capture time and stays in the record; the replay is annotated, not
> substituted. Replay before voiding a run over a near-threshold number.

## Attribute landing, per run, per signal

Recorded **before** the timed run. Without it, a later readout cannot tell a
signal the engine dropped from a signal the filter hid.

| Run ID | spans | logs | metrics |
|---|---|---|---|
| `R1-P1-collector` | SAFE | SAFE | SAFE |
| `R1-P2-fluentbit` | SAFE | **UNSAFE** — `k8s.cluster.name` lands on 0 of 2,782,904 logs | n/a — no metrics delivered |

## Run notes

- **R1-P1 / R1-P2** — both arms ran with a parallel collector pipeline (9 pods,
  ~932 mCores) on the same nodes. Constant across both, disclosed in
  [RESULTS.md](RESULTS.md), removed before Round 2.
- **R1-P2 gate** — recorded 6/6, but check 5 aggregated across signals and could
  not see the metrics signal fail at 100%. Check 5b was added afterwards and
  turns this red. The row is annotated **blind-gate-produced** rather than
  rewritten: 6/6 is what the instrument said at the time.
- **R1-P3** — aborted at the gate; `df_engine:0.50.0` panicked on all four
  pipeline cores within a minute of start. No timed run, nothing measured,
  nothing voided.
