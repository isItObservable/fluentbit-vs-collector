**Relationship to existing issues** (from the pre-filing search):
- Panic site 1 looks like the bug draft PR #2984 already fixes. The `boo` string is a
  column-length consistency `check()` and the reported lengths `[21, 21, 21, 7, 21, ...]`
  show exactly the one-column row-count mismatch that PR describes. Treat this report as
  corroboration that it still reproduces on main and does so under ordinary load.
- Issue #3401 ("Controller extension panic bypasses fail-fast shutdown and wedges the
  engine in run_forever") is the same *theme* as our recovery complaint but a different
  path — that one is a controller extension, ours is a pipeline core. Whatever policy
  comes out of #3401 would ideally cover both.
- I found nothing for `DictionaryKeyOverflowError` / `MutableArrayData` in this engine.

**Workaround we adopted**, in case it helps others: insert `processor:type_router`
immediately after the receiver and terminate the metrics port in `exporter:noop`, so the
metrics encoder is never reached:

    router:       { type: processor:type_router, outputs: [logs, metrics, traces], config: {} }
    metrics_noop: { type: exporter:noop, config: {} }
    # connections: otlp_in -> router; router["metrics"] -> metrics_noop; router["logs"|"traces"] -> ...

With that plus `max_batch_duration` reduced 3s -> 1s, the same workload ran **41 minutes
with zero panics** where it previously died in 30 seconds. ⚠️ We changed two things at
once and cannot attribute the improvement: cutting the batch window also reduces how many
records merge into each array, which plausibly suppresses the dictionary overflow on its
own. So this is **not** evidence that excluding metrics is sufficient — panic site 2 was
never addressed and we believe it can still fire on high-cardinality traces or logs.

**Separately, `--validate-and-exit` accepts configurations that cannot work at runtime.**
Happy to split these out if you'd prefer separate issues:
- `processor:filter` accepts `config: {__bogus__: 1}` and prints `Configuration is valid.`
- `processor:type_router` with `config: {}` and no `outputs:` declared at all validates
  clean, although nothing would be routed by name.
- the KQL `processor:transform` validates predicates it cannot evaluate at runtime —
  `contains`, `==`, `matches regex` and `replace_regex` all fail at runtime against a
  config that validates clean.

Happy to provide the full engine log or test a patch.
