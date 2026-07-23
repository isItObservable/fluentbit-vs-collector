Two more things from the same run that didn't make it into the comment above — one is a way to *detect* this state, the other is a check against current `main`.

### Detecting it: the admin API stops **serving** the pipeline metric sets

This is the part I'd most like to put in front of anyone else hitting it, because every process-level signal lies here. Querying `/api/v1/metrics?format=json&keep_all_zeroes=true`:

| | `metric_sets` | distinct names |
|---|---|---|
| healthy | 289 | 17 (`receiver.otlp`, `processor.attributes`, `otap.processor.batch`, `pipeline`, …) |
| after all four cores died | **1** | **1** (`engine` only) |

`keep_all_zeroes=true` matters here — it shows the sets are genuinely *absent*, not merely suppressed for reading zero, which is what makes this unambiguous where the frozen cumulative values are not. So the information needed to fail a readiness probe is already inside the engine; it just is not surfaced anywhere the orchestrator looks.

### Still present on current `main`

I checked before assuming, since my original report pins `7502e7d` (2026-07-20). As of `257cceb0` (2026-07-23 16:03Z) there are 14 commits in between and **none of them touch `rust/otap-dataflow/crates/pdata/src/otap/transform/`** — `concatenate.rs` is byte-identical across the whole range (same blob, `0d8b9f39`, 107944 bytes), and the only file that changed anywhere in the `pdata` crate is its `README.md`. The `arrow-*` lockfile bump 58.3.0 → 58.4.0 that landed in that range (#3546) doesn't help either: arrow-rs 58.4.0 is 7 commits, all parquet-encryption / CI / changelog, with **zero** changes under `arrow-data/src/transform/` or `arrow-select/src/coalesce`. So both panic sites should be unchanged on today's `main`.

Happy to supply the full log from either run, or to test a patch.
