Under sustained real-world OTLP traffic, `df_engine` panics on every pipeline core and
the engine never recovers. The process stays alive and keeps accepting connections while
processing nothing, so orchestration sees a healthy pod.

Two distinct panic sites fired in one 30-second window:

1. `crates/pdata/src/encode/record/metrics.rs:266` — `panic!("boo {lens:?}")` in the
   metrics record encoder's column-length `check()`. **This appears to be already known:
   draft PR #2984 ("fix: stop metrics otap encode panic") root-causes it as a shared
   protobuf-cursor misuse producing inconsistent column row counts.** That PR is open,
   draft and unmerged, so the fix is not in main as of the commit above. Reporting it
   here only as an independent real-world reproduction — a data point for #2984, not a
   new bug.

2. `arrow-data-58.3.0/src/transform/mod.rs:680` — `MutableArrayData::new is infallible:
   DictionaryKeyOverflowError`. **I could not find any existing issue for this**, and it
   was the *majority* failure — 3 of 4 cores. It is not obviously metrics-specific;
   `MutableArrayData::new` is the generic array-merge path, so ordinary high-cardinality
   span or log attributes look sufficient to trigger it.

The most operationally serious part is neither panic but the aftermath: a core that dies
is never restarted and the failure is invisible to every process-level health signal.
