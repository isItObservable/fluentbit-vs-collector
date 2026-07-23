<!--
ISI-1843 — follow-up COMMENT for the filed upstream issue:
https://github.com/open-telemetry/otel-arrow/issues/3561

✅ POSTED 2026-07-23T16:46:50Z by @henrikrexed —
https://github.com/open-telemetry/otel-arrow/issues/3561#issuecomment-5061029145
⚠️ BUT the posted body is the 04decf8-era draft, NOT this file. It is missing the two
   sections below the "Everything else in the original report stands" paragraph — the
   metric_sets 289→1 detection mechanism and the still-present-on-current-main check —
   plus the closing offer line. See UPSTREAM-3561-POSTED.md for the verified delta and
   UPSTREAM-3561-ADDENDUM.paste.md for the follow-up comment that closes the gap.
   Henrik owns the upstream account (the runner's PATs 403 on write).
⚠️ DO NOT PASTE THIS FILE — this header is an HTML comment: invisible when rendered,
   fully readable in a public issue's source, and it names an internal ticket and the
   account. PASTE UPSTREAM-3561-FOLLOWUP.paste.md INSTEAD — that file is this one from
   the "---8<---" marker down, with no header, so the whole file is the comment and
   there is nothing to remember not to paste.

   ./make-paste-block.sh          regenerate the paste file after editing this one
   ./make-paste-block.sh --check  fail if the paste file has drifted from this one
   ./scrub-paste-block.sh         re-certify the paste bytes (6 classes, control-proven)

   Running the scrubber against THIS file exits 1 — that is the intended demonstration
   that the header is exactly the thing that must not ship.

WHY THIS IS PRIORITY, not housekeeping: #3561 as filed says the workaround ran "41
minutes with zero panics". Newer evidence (results/r1p3-retry/) falsifies the implication.
The same corrected config on the real workload died at T+26m10s. A maintainer reading the
issue today would reasonably conclude the type_router workaround resolves the problem. It
does not — it DELAYS it. Correcting our own overstatement is on us, and it also carries
genuinely new information they need: a third panic site inside otap-dataflow itself.

Scrubbed: no tenant URL, cluster names, ticket ids, lab IPs, account or app names beyond
the public opentelemetry-demo chart. Verified by grep before writing. Re-check if edited.
-->

---8<--- paste from here ---8<---

### Correction and new data: the workaround delays the dictionary overflow, it does not prevent it

Correcting my own report above, and adding a panic site I hadn't seen when I filed.

In the original **Additional Context** I wrote that with `type_router` + metrics to `noop`, plus `max_batch_duration` cut 3s → 1s, "the same workload ran 41 minutes with zero panics". I flagged that we'd changed two things at once and couldn't attribute the improvement. That caveat was right, and it has now been settled the unhappy way — **please don't read the workaround as a fix.**

That 41-minute run was on a deliberately reduced reproducer (no service mesh, fewer applications). Running the **same corrected configuration** against the full original workload, the engine died the same way:

| | original config | corrected config (router → noop, batch 1s) |
|---|---|---|
| `boo` — `crates/pdata/src/encode/record/metrics.rs:266` | T+5.6s | **never — 0 occurrences** |
| first `DictionaryKeyOverflowError` | T+23.0s | **T+26m10.5s** |
| all four cores dead | T+30.3s | **T+33m34.2s** |

**What that settles:**

1. **Routing metrics away genuinely removes the `boo` site** — zero occurrences, as expected by construction, since the metrics encoder is no longer reachable. That part of the workaround works.
2. **The dictionary overflow is accumulation-driven, not batch-size-gated.** Cutting the batch window gives ~68× more life and then the identical failure. Smaller batches merge fewer distinct values into each output array, so the key space is exhausted *later*, not never. Anyone adopting the workaround should size their expectations in minutes, not treat it as a resolution.
3. Consequently the overflow is reachable on **traces and logs alone**, with the metrics path entirely disconnected. It is not metrics-specific.

### New: a second overflow site, inside `otap-dataflow` itself — and it fires first

The original report only ever saw the `arrow-data` call site. In this run the earliest death was in df_engine's own code:

```
thread 'pipeline-default-main-core-0-gen-0' (12) panicked at crates/pdata/src/otap/transform/concatenate.rs:150:43:
Compatible schemas: DictionaryKeyOverflowError
```

Two of four cores died there (T+26m10.5s, the earliest), the other two at the previously reported `arrow-data-58.3.0/src/transform/mod.rs:680`. So the overflow surfaces at **two independent concatenation points**, one of them an `expect()` inside this repository rather than in a dependency. That seems worth knowing: it isn't a single unlucky call site in `arrow-data`, and a fix confined to the dependency boundary would likely leave `concatenate.rs:150` exposed.

Everything else in the original report stands — including the part I'd still most like your view on: all four cores were dead while the process stayed up, the pod stayed `Ready` with `restarts=0`, and the cumulative counters held their last healthy values. In this second run the engine sat there for a further ~40 minutes, resident memory still climbing, looking healthy to every process-level signal.

One thing I found that *does* detect this reliably, in case it is useful to others or suggests where a health check might live: the admin API stops **serving** the pipeline metric sets once the cores die. Querying `/api/v1/metrics?format=json&keep_all_zeroes=true`:

| | `metric_sets` | distinct names |
|---|---|---|
| healthy | 289 | 17 (`receiver.otlp`, `processor.attributes`, `otap.processor.batch`, `pipeline`, …) |
| after all four cores died | **1** | **1** (`engine` only) |

`keep_all_zeroes=true` matters here — it shows the sets are genuinely *absent*, not merely suppressed for reading zero, which is what makes this unambiguous where the frozen cumulative values are not. So the information needed to fail a readiness probe is already inside the engine; it just is not surfaced anywhere the orchestrator looks.

### Still present on current `main`

I checked before assuming, since my original report pins `7502e7d` (2026-07-20). As of `257cceb0` (2026-07-23 16:03Z) there are 14 commits in between and **none of them touch `rust/otap-dataflow/crates/pdata/src/otap/transform/`** — `concatenate.rs` is byte-identical across the whole range (same blob, `0d8b9f39`), and the only file that changed anywhere in the `pdata` crate is its `README.md`. The `arrow-*` lockfile bump 58.3.0 → 58.4.0 that landed in that range (#3546) doesn't help either: arrow-rs 58.4.0 is 7 commits, all parquet-encryption / CI / changelog, with **zero** changes under `arrow-data/src/transform/` or `arrow-select/src/coalesce`. So both panic sites should be unchanged on today's `main`.

Happy to supply the full log from either run, or to test a patch.
