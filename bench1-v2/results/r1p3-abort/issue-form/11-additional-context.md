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

⚠️ **This is a delay, not a fix — we have since disproven it as a workaround.** With that
change plus `max_batch_duration` reduced 3s -> 1s, a *reduced* reproducer ran 41 minutes
with zero panics. We flagged at the time that the reduced rig lacked the mesh-generated
spans of the real workload, so survival was necessary but not sufficient. Re-running the
**full** workload confirmed the caveat: the `boo` panic was indeed gone for good, but all
four cores still died of `DictionaryKeyOverflowError` — first core at +26m10s, last at
+33m34s, versus +23s and +30s before. So:

- excluding metrics removes panic site 1 **by construction**, and that part holds;
- the dictionary overflow (sites 2 and 3) is **accumulation-driven, not batch-size-gated**
  — smaller batches merge fewer distinct values per output array, so the key space is
  exhausted later rather than never. Higher load reaches it sooner.

We are reporting the workaround because the 68x difference is itself a clue about the
mechanism, not because it makes the engine usable.

**Separately, `--validate-and-exit` accepts configurations that cannot work at runtime.**
Happy to split these out if you'd prefer separate issues:
- `processor:filter` accepts `config: {__bogus__: 1}` and prints `Configuration is valid.`
- `processor:type_router` with `config: {}` and no `outputs:` declared at all validates
  clean, although nothing would be routed by name.
- the KQL `processor:transform` validates predicates it cannot evaluate at runtime —
  `contains`, `==`, `matches regex` and `replace_regex` all fail at runtime against a
  config that validates clean.

Happy to provide the full engine log or test a patch.
