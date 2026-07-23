<!--
✅ FILED as open-telemetry/otel-arrow#3561 — https://github.com/open-telemetry/otel-arrow/issues/3561
   This file is the source the filed body was built from. Correction pending:
   see UPSTREAM-3561-FOLLOWUP.md.
-->

<!--
ISI-1843 — the upstream report restructured for the repo's ISSUE FORM.
Supersedes the free-form body in UPSTREAM-ISSUE.md (which is kept for the fuller narrative).

File at: https://github.com/open-telemetry/otel-arrow/issues/new?template=bug_report.yaml

⚠️ DO NOT PASTE THIS HEADER. It names the internal issue. An HTML comment is invisible
when rendered but fully readable in a public issue's source. Everything below the
"=== FIELD:" markers is scrubbed; the markers themselves are paste guides, not content.

⚠️ TWO FIELDS ARE `render:` FIELDS. GitHub fences them automatically:
     config -> render: yaml     logs -> render: shell
   Paste RAW content into those two. Adding your own ``` fence double-fences it.

⚠️ THE DUPLICATE SEARCH IS REAL, AND IT CHANGED THE REPORT (2026-07-23):
   - `boo` panic  -> ALREADY KNOWN. Draft PR #2984 "fix: stop metrics otap encode panic"
     root-causes it (shared protobuf cursor => inconsistent column row counts) and is
     OPEN + DRAFT + UNMERGED, so absent from main @ 7502e7d. We are corroborating it,
     NOT reporting it as new.
   - `DictionaryKeyOverflowError` -> ZERO hits. This is the genuinely unreported bug and
     is the reason to file.
   - no-recovery/wedge -> #3401 is the same THEME (panic bypasses fail-fast) but a
     different path (controller extension, not pipeline core). Cross-reference, not dup.
   Re-run the searches before filing if time has passed; a search result decays.
-->

=== FIELD: Pre-filing checklist ===
[x] I searched existing issues and didn't find a duplicate
    (searched: "boo", DictionaryKeyOverflow, MutableArrayData, pipeline_runtime_failed,
     panic in:title, cores die — findings folded into the report below)

=== FIELD: Component(s)  [dropdown, pick exactly this] ===
Rust OTAP dataflow (rust/otap-dataflow/)

=== FIELD: OTel-Arrow Version  [single-line input] ===
7502e7dbe636b6bd14d15e0a69367fa00bc10343 (main, 2026-07-20)

=== FIELD: Bug Description ===
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

=== FIELD: Steps to Reproduce ===
1. Build `otap-df` at 7502e7dbe636b6bd14d15e0a69367fa00bc10343 (submodules recursive,
   upstream Dockerfile unmodified):
   `cargo build --locked --release --target=x86_64-unknown-linux-gnu`
   with `RUSTFLAGS=-C target-cpu=x86-64-v2`; runtime `gcr.io/distroless/cc-debian13:nonroot`.
2. Run it with 4 pipeline cores and the config in the Configuration field — one shared
   chain for all three signals, so a metrics panic takes traces and logs with it.
3. Point sustained OTLP traffic at it. We used the `opentelemetry-demo` Helm chart
   0.40.10 (appVersion 2.2.0, ~20 services) with every service's
   `OTEL_EXPORTER_OTLP_ENDPOINT` set to the engine, plus a service mesh emitting
   access-log spans and a second demo application. Ordinary smoke-test volume was
   enough — we never reached our intended load level.
4. Watch the engine log for `panicked at` and watch the pod's readiness.

Deterministic: reproduced on two independent pods. Time-to-death **shortens** with
backlog, because upstream SDKs queue telemetry and retry it as a burst — run 1 survived
3m08s, run 2 survived ~48s. That rules out periodic restarts as a mitigation, since each
restart meets a larger backlog than the last.

=== FIELD: Expected Behavior ===
1. Encoding a batch of ordinary OTLP telemetry should not panic.
2. If a pipeline core does panic, `pipeline_runtime_failed` should be recoverable —
   restart the core or start a new generation — rather than terminal.
3. An engine whose cores have all died should FAIL its health/readiness surface. Reporting
   `Running`/`Ready` while processing nothing is the failure mode that costs downstream
   users the most.

On (3) there may be an easy win: the admin server already has the data. `GET
/api/v1/metrics?format=json&keep_all_zeroes=true` returns the internal metric set **per
node per core**, so a dead core shows as its `receiver.otlp` / `processor.*` counters
going flat while sibling cores advance — no log grepping needed. This is not discoverable
from the admin UI, which looks like a static HTML page; we only found the endpoint by
reading the UI's own `metrics-api.js`. Documenting it would help, and surfacing the same
signal on a readiness endpoint would help more.

=== FIELD: Actual Behavior ===
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

=== FIELD: Environment ===
- Deployment: Kubernetes, 4-core pod, `gcr.io/distroless/cc-debian13:nonroot`
- Build: `cargo build --locked --release --target=x86_64-unknown-linux-gnu`,
  `RUSTFLAGS=-C target-cpu=x86-64-v2`
- `arrow-data` 58.3.0
- Load: `opentelemetry-demo` chart 0.40.10 (appVersion 2.2.0), ~20 services, traces +
  logs + metrics into one pipeline, plus mesh access-log spans and a second application
- Backend: an OTLP/HTTP endpoint that returns 400 on cumulative Sum/Histogram/Summary
  (relevant only as corroboration that the metrics payload was independently judged
  malformed at the same moment the encoder panicked)

=== FIELD: Configuration  [render: yaml — paste RAW, do NOT add a ``` fence] ===
version: otel_dataflow/v1
engine: {}
groups:
  default:
    pipelines:
      main:
        policies:
          channel_capacity:
            control: { node: 100, pipeline: 100 }
            pdata: 128
        nodes:
          otlp_in:
            type: receiver:otlp
            config:
              protocols:
                grpc: { listening_addr: 0.0.0.0:4317 }
                http: { listening_addr: 0.0.0.0:4318 }
          enrich:
            type: processor:attribute
            config:
              actions:
                - { key: some.static.key, action: upsert, value: some-value }
          parity:
            type: processor:transform
            config:
              kql_query: "logs | extend severity_text = 'ERROR'"
          batch:
            type: processor:batch
            config:
              otap: { min_size: 1000, sizer: items }
              max_batch_duration: 3s
          out:
            type: exporter:otlp_http
            config:
              endpoint: https://<otlp-endpoint>/api/v2/otlp
              client_pool_size: 4
              http:
                headers:
                  Authorization: "<redacted>"
        connections:
          - { from: otlp_in, to: enrich }
          - { from: enrich,  to: parity }
          - { from: parity,  to: batch }
          - { from: batch,   to: out }

=== FIELD: Log Output  [render: shell — paste RAW, do NOT add a ``` fence] ===
thread 'pipeline-default-main-core-3-gen-0' (14) panicked at crates/pdata/src/encode/record/metrics.rs:266:13:
boo [21, 21, 21, 7, 21, 21, 21, 21, 21, 21]
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
2026-07-23T10:53:34.869Z  ERROR otap-df-controller::controller.pipeline_runtime_failed: Pipeline terminated with a runtime error [core_id=3]

thread 'pipeline-default-main-core-1-gen-0' (12) panicked at /usr/local/cargo/registry/src/index.crates.io-.../arrow-data-58.3.0/src/transform/mod.rs:680:31:
MutableArrayData::new is infallible: DictionaryKeyOverflowError
2026-07-23T10:53:52.252Z  ERROR otap-df-controller::controller.pipeline_runtime_failed: Pipeline terminated with a runtime error [core_id=1] entity/pipeline.attrs: pipeline.id=main pipeline.group.id=default deployment.generation=0 core.id=1 numa.node.id=0

thread 'pipeline-default-main-core-0-gen-0' (11) panicked at /usr/local/cargo/registry/src/index.crates.io-.../arrow-data-58.3.0/src/transform/mod.rs:680:31:
MutableArrayData::new is infallible: DictionaryKeyOverflowError
2026-07-23T10:53:58.263Z  ERROR otap-df-controller::controller.pipeline_runtime_failed: Pipeline terminated with a runtime error [core_id=0]

thread 'pipeline-default-main-core-2-gen-0' (13) panicked at /usr/local/cargo/registry/src/index.crates.io-.../arrow-data-58.3.0/src/transform/mod.rs:680:31:
MutableArrayData::new is infallible: DictionaryKeyOverflowError
2026-07-23T10:53:59.582Z  ERROR otap-df-controller::controller.pipeline_runtime_failed: Pipeline terminated with a runtime error [core_id=2]

# after this point: process alive, pod Ready, restarts=0, zero records processed

=== FIELD: Additional Context ===
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
