<!--
ISI-1843 — follow-up COMMENT for the filed upstream issue:
https://github.com/open-telemetry/otel-arrow/issues/3561

⚠️ NOT POSTED. Henrik owns the upstream account (the runner's PATs 403 on write).
⚠️ DO NOT PASTE THIS HEADER — an HTML comment is invisible when rendered but fully
   readable in a public issue's source. Paste from the "---8<---" marker down.

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

Happy to supply the full log from either run, or to test a patch.
