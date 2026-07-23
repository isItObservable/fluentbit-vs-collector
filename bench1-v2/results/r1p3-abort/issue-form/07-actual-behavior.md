Each panic kills its pipeline core and logs `pipeline_runtime_failed`. There is no
restart, no new generation, no recovery. Once all four cores are down:

- the process is still running and still accepting connections,
- Kubernetes reports the pod `Running`, `Ready`, `restarts=0`,
- throughput counters keep their last healthy cumulative values, so a dashboard built on
  cumulative counters shows no drop.

We nearly banked a two-hour benchmark run on an engine that had been dead for six
minutes, because every liveness signal derived from the *process* was green. The only
thing that caught it was grepping the log for `panic`.

Sequence in one run (engine up 10:53:29):
core 3 at +5s (`boo`), core 1 at +23s, core 0 at +29s, core 2 at +30s (all three
`DictionaryKeyOverflowError`). All four cores dead 30 seconds after start.

Sequence in a later run on the same cluster and workload, with metrics routed away from
the pipeline and `max_batch_duration` cut 3s -> 1s (engine up 14:59:03):
core 0 at +26m10s (`concatenate.rs:150`), core 3 at +32m20s (same),
core 2 at +32m56s (`arrow-data…mod.rs:680`), core 1 at +33m34s (same).
All four cores dead 33 minutes after start — all four `DictionaryKeyOverflowError`, no
`boo`. **68x longer to the first dictionary panic, same ending.** 40 minutes after the
last core died the pod was still `Ready`, `restarts=0`, and the admin API still reported
resident memory *growing*.

One usable engine-side signal: when the cores die, the admin API
(`GET /api/v1/metrics?format=json&keep_all_zeroes=true`) stops serving the pipeline
metric sets entirely — 289 metric sets across 17 names while healthy, exactly 1 (the
process-level `engine` set) once the cores are gone. Absence of the sets is unambiguous
where their *values* are not, since the cumulative counters simply freeze.
