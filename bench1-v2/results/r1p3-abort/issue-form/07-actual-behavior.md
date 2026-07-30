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
