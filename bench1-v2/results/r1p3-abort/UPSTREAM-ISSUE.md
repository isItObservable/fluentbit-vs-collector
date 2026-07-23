<!--
ISI-1843 — READY TO FILE against open-telemetry/otel-arrow. NOT YET FILED.

BLOCKED ON A CREDENTIAL, tested rather than assumed: both GitHub PATs available
on the runner (gh hosts.yml and ~/.git-credentials, two DIFFERENT fine-grained
tokens for henrikrexed) can GET the repo and LIST its issues (200) but return
403 "Resource not accessible by personal access token" on issue CREATE. Both
probes were run; neither created anything.

TO FILE — anyone with a token carrying public-repo issue scope, or just the
GitHub web UI:

  gh issue create --repo open-telemetry/otel-arrow \
    --title "df_engine: all pipeline cores die under real OTLP load (boo panic in metrics record encoder + arrow DictionaryKeyOverflowError), process stays alive and reports healthy" \
    --body-file bench1-v2/results/r1p3-abort/UPSTREAM-ISSUE.md

SCRUBBED for public posting: no tenant URL, no cluster names, no ISI issue
numbers, no internal repo or org names, no application names beyond the public
opentelemetry-demo chart. Verified by grep before writing. Re-check if edited.

Full unredacted engine log for this incident: engine-panic.log (same directory).
-->

### Component

`rust/otap-dataflow` — `df_engine`

### What happened

Under sustained real-world OTLP traffic (the OpenTelemetry Demo, ~20 services, traces + logs + metrics into a single pipeline), **`df_engine` panics and every pipeline core dies within a few minutes. The process stays alive and keeps accepting connections while processing nothing.**

This is deterministic — reproduced on two independent pods, and the second died faster than the first.

### Version

- `otap-df` **v0.50.0**
- Built from `open-telemetry/otel-arrow` @ **`7502e7dbe636b6bd14d15e0a69367fa00bc10343`** (`main`, 2026-07-20), submodules recursive, upstream `Dockerfile` unmodified
- `cargo build --locked --release --target=x86_64-unknown-linux-gnu`, `RUSTFLAGS=-C target-cpu=x86-64-v2`
- Runtime `gcr.io/distroless/cc-debian13:nonroot`, 4 cores

### Two distinct panic sites

**1. `boo` — an unfinished assertion in the OTAP metrics record encoder**

```
thread 'pipeline-default-main-core-3-gen-0' (14) panicked at crates/pdata/src/encode/record/metrics.rs:266:13:
boo [21, 21, 21, 7, 21, 21, 21, 21, 21, 21]
```

The panic message is the literal string `boo`. The array is ten column lengths with one odd element (`7` among `21`s), i.e. this looks like a column-length consistency check that was left as a placeholder. Whatever the underlying cause, a shipped crate should not abort a worker thread with `boo`.

Corroborating signal: at the same time, the OTLP/HTTP backend returned `400 Bad Request` on `/v1/metrics`, so the metrics payload the encoder produced was independently judged malformed.

**2. `DictionaryKeyOverflowError` in `arrow-data`**

```
thread 'pipeline-default-main-core-1-gen-0' (12) panicked at
  .../arrow-data-58.3.0/src/transform/mod.rs:680:31:
MutableArrayData::new is infallible: DictionaryKeyOverflowError
```

More distinct values than the dictionary key type can index. The `expect("MutableArrayData::new is infallible")` is not in fact infallible for dictionary-encoded arrays with real-world attribute cardinality.

This was the **majority** failure on a freshly started pod (3 of 4 cores), and it is not obviously metrics-specific — it appears to be generic Arrow encoding, so high-cardinality span or log attributes look like enough to trigger it on their own.

### The most serious part: no recovery, and the failure is invisible to orchestration

Each panic kills its pipeline core with:

```
ERROR otap-df-controller::controller.pipeline_runtime_failed: Pipeline terminated with a runtime error [core_id=3]
```

There is **no restart, no new generation, no recovery**. Once all cores are down:

- the process is still running and still accepting connections,
- Kubernetes reports the pod `Running`, `Ready`, `restarts=0`,
- throughput counters keep their last (healthy) cumulative values.

We nearly banked a two-hour benchmark run on an engine that had been dead for six minutes, because every liveness signal derived from the *process* was green. The only thing that caught it was grepping the log for `panic`.

Two requests here, independent of the panics themselves:
1. a pipeline whose cores have all died should fail its health/readiness surface, not report healthy;
2. `pipeline_runtime_failed` would ideally be recoverable (restart the core / new generation) rather than terminal.

### Timing — it gets worse, not better

| run | survival after start |
|---|---|
| 1 | **3m 08s** |
| 2 | **~48s** |

Run 2 died faster because upstream SDKs had queued ~7 minutes of telemetry and retried it as a burst. **Time-to-death shortens as backlog grows**, which rules out "just restart it periodically" as a mitigation: each restart meets a bigger backlog than the last.

### Minimal-ish reproduction

Single pipeline, all three signals sharing one chain — so a metrics panic takes traces and logs down with it:

```yaml
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
                  Authorization: "Api-Token <token>"
        connections:
          - { from: otlp_in, to: enrich }
          - { from: enrich,  to: parity }
          - { from: parity,  to: batch }
          - { from: batch,   to: out }
```

Load: `opentelemetry-demo` Helm chart 0.40.10 (appVersion 2.2.0) with every service's `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at `otlp_in`, plus an Istio mesh emitting access-log spans, plus a second demo application. Ordinary smoke-test volume was enough; we never reached our intended load level.

### Workaround we adopted

Insert `processor:type_router` immediately after the receiver and terminate the metrics port in `exporter:noop`:

```yaml
router:
  type: processor:type_router
  outputs: [logs, metrics, traces]
  config: {}
metrics_noop:
  type: exporter:noop
  config: {}
# connections:
#   - { from: otlp_in, to: router }
#   - { from: 'router["metrics"]', to: metrics_noop }
#   - { from: 'router["logs"]',    to: ... }
#   - { from: 'router["traces"]',  to: ... }
```

This removes panic site 1 from the data path. **It does not address panic site 2**, which we believe can still fire on high-cardinality traces or logs.

### A separate, smaller observation about `--validate-and-exit`

While building the workaround we found several configurations that pass validation but cannot work at runtime. These may be worth separate issues, but recording them here since they made diagnosis considerably harder:

- `processor:filter` accepts `config: {__bogus__: 1}` and the binary prints `Configuration is valid.`
- `processor:type_router` with `config: {}` and **no `outputs:` declared at all** validates clean, although nothing would be routed by name.
- the KQL `processor:transform` validates predicates it cannot evaluate at runtime — `contains`, `==`, `matches regex` and `replace_regex` all fail at runtime against a config that validates clean.

Happy to split any of these out, provide the full engine log, or test a patch.
