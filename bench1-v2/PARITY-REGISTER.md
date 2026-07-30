# ISI-1779 B1-v2 — Parity and Disclosure Register

**Purpose.** Every asymmetry between the three engines that reaches the recording must be either
*closed* (same behaviour, same config knob) or *named here* with the exact sentence that goes on
camera. Nothing may arrive at the shoot as an undocumented difference.

**Owner / authority.** ISI-1845 (BigBoss, 2026-07-23). Decisions traced to ISI-1841
`b1v2-scope-decisions` document.

---

## D0 — The Freeze Rule (why asymmetries are closed on the arrow side only)

> **An arm holding a banked, valid Round-1 row is config-frozen for the rest of the campaign.**

The Collector arm (R1P1, ISI-1815) and the Fluent Bit arm (R1P2, ISI-1816) each have a completed,
gate-passing timed run. Their configs are frozen; changes to buy symmetry would void two valid two-
hour runs.

The OTel-Arrow-native arm has no banked row — R1P3 aborted at the gate before any load ran. Its
config is open for correction **until its retry starts**, then frozen from that instant.

Consequence: every parity gap is closed on the arrow side (or disclosed). "Level the other two arms
down" was rejected because it would void two valid, irreplaceable results.

---

## Parity Steps — What Each Engine Does

| Step | Work | Collector | Fluent Bit v5 | OTel-Arrow native |
|------|------|-----------|---------------|-------------------|
| 1 | Static attribute add (`benchmark.engine`, `k8s.cluster.name`, `benchmark.run`) | `resource/static` (OTTL upsert ×3) | `content_modifier action: upsert` ×3 per signal | `processor:attribute actions: upsert` ×3 per branch |
| 2 | Severity normalise → `severity_text = ERROR` | `set(severity_text,"ERROR") where IsMatch(body,"(?i)error")` — conditional | `content_modifier upsert` + regex condition | `kql_query: "logs | extend severity_text = 'ERROR'"` — constant write; **see disclosure P-SEV** |
| 3 | PII redact (e-mail → masked/hashed) | `replace_pattern(body, <e-mail-re>, "***REDACTED***")` — substring mask | `content_modifier action: hash key: log` on e-mail regex condition — whole-value SHA-256; **see disclosure P-PII** | Not implementable; **see disclosure P-PII** |
| 4 | Drop `log.file.path` | `delete_key(attributes, "log.file.path")` in `log_statements` + `trace_statements` | `content_modifier action: delete key: log.file.path` in `logs:` + `traces:` | `processor:attribute action: delete key: log.file.path` on both logs and traces branches; **ISI-1843 runtime-proven** |
| 5 | Batch before export | `send_batch_size 8192`, `send_batch_max_size 16384`, `timeout 1s` | `flush 1s` (plugin-level, no size knob); **see disclosure Q6** | `otap: {min_size: 1000, sizer: items}`, `max_batch_duration: 1s`; **see disclosure Q6** |

---

## Disclosed Asymmetries

### P-SEV — Severity normalise: constant write vs. conditional write

> ✅ **RETRACTED as an engine gap (ISI-1859, 2026-07-24).** The conditional read
> was a **KQL-surface limit, not a df_engine limit.** Rewritten in OPL and
> runtime-proven on `observable-agentsandbox` against the unchanged `7502e7d`
> image: `logs | if (contains(body, "error")) { set severity_text = "ERROR" }
> else { set severity_text = "CLEARED" }` produced 50 `ERROR` (matching bodies)
> and 50 `CLEARED` (non-matching) off the wire — the `if` predicate **read**
> `body` and branched, which KQL could not. Evidence:
> `engines/opl-proof/probe.yaml` + `verify.sh` (9/9 PASS),
> `results/opl-retest/FINDINGS.md`, `results/opl-retest/sink-evidence.log`.
> Retracted upstream on otel-arrow#3561 (paste-ready follow-up in
> `results/opl-retest/`). **Moot for the readout — the arm is DNF (ISI-1849) —**
> but corrected here because the register is a public correctness record.

The original disclosure (KQL surface) is kept below as history:

| | |
|---|---|
| **Arms affected** | OTel-Arrow native (Phase 3) vs. Collector (Phase 1) + Fluent Bit (Phase 2) |
| **What the frozen arms do** | Write `severity_text = ERROR` only when the log body matches `/(?i)error/` |
| **What the arrow arm did (on KQL)** | Write `severity_text = ERROR` unconditionally on every log record |
| **Root cause (KQL surface only)** | `processor:transform` with `kql_query` in df_engine 0.50.0 could write a field but not read one at runtime — every conditional (`body contains`, `body == "…"`, `matches regex`) raised an opaque runtime error while `--validate-and-exit` reported VALID. Tracked upstream as #1634. **The OPL surface (`opl_query`) does not have this limit** — see the retraction above. |
| **Camera sentence (superseded)** | ~~*"…the Arrow engine does it unconditionally, because its KQL transform can write a field but cannot read one."*~~ No longer true: OPL reads the field. If the arm ever ran, all three would write conditionally. |

---

### P-PII — PII redaction: hash vs. substring mask vs. not implemented

> ✅ **"Not implementable at all" RETRACTED (ISI-1859, 2026-07-24).** The
> conditional field-read + redact **is** implementable on the arrow side — in
> OPL, not KQL. Runtime-proven against the `7502e7d` image:
> `logs | if (matches(body, r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9._-]+")) { set
> attributes["pii.email.detected"] = "true", body = concat("REDACTED:",
> encode(sha256(body), "hex")) }` fired on exactly the 50 e-mail-bearing records,
> rewrote their body to a SHA-256, left the original e-mail nowhere in the output
> (0 occurrences), and did not touch the 50 clean records. Evidence as for P-SEV.
> **Remaining nuance (a semantic difference, not an inability):** OPL at `7502e7d`
> has no `regexp_replace` verb (only literal `replace`, plus `regexp_substr` /
> `regexp_capture`), so the Collector's *substring* mask is not a single OPL
> operation. The arrow arm redacts by whole-value hash — identical semantics to
> the Fluent Bit arm. So the three-way split becomes **substring-mask vs
> whole-value-hash vs whole-value-hash**, all implemented, rather than
> "…vs not implemented." Retracted upstream on #3561.

The original disclosure is kept below as history:

| | |
|---|---|
| **Arms affected** | All three; ~~arrow arm cannot implement it at all~~ arrow arm redacts by whole-value hash (see retraction) |
| **Collector** | `replace_pattern(body, <e-mail-regex>, "***REDACTED***")` — replaces only the matched substring; the rest of the body is unchanged |
| **Fluent Bit v5** | `content_modifier action: hash key: log` + e-mail regex condition — SHA-256s the **entire log value** when the body matches |
| **Arrow native (on OPL)** | `if (matches(body, r"…@…")) { set body = encode(sha256(body), "hex") }` — reads the field, forms the condition, hashes the whole value. Same semantics as Fluent Bit. The KQL surface could not read a field (see P-SEV / #1634); the OPL surface can. |
| **Camera sentence (updated)** | *"Three engines, three redaction approaches: the Collector masks the matched e-mail substring; Fluent Bit and the Arrow engine both hash the whole field value. All three read the body, detect the e-mail, and redact — the outputs differ because the verbs differ, not because one engine can't do it."* |

---

### P-MET — OPL can filter Dynatrace-rejected metrics, and carries all three signals (ISI-1859 step B)

> **Ask (Henrik, ISI-1859 2026-07-24):** can OPL drop the cumulative + Summary
> metrics Dynatrace rejects, and can the transform handle a
> traces / spans / metrics / logs scenario, not just logs?
> **Answer: yes to all — runtime-proven on the unchanged `7502e7d` image**
> (`engines/opl-proof/multisignal.yaml` + `verify-multisignal.sh`, **11/11 PASS**).
> As always on this engine the `--validate-and-exit` validator is worthless; every
> number below is read off the wire from a debug sink.

**Drop predicate (the deliverable):**

```
metrics | where not(aggregation_temporality == 2) | where metric_type != 5
```

- Drops **cumulative** (`aggregation_temporality == 2`) — covers cumulative Sum /
  Histogram / ExponentialHistogram.
- Drops **Summary** (`metric_type == 5`).
- Keeps **Gauge** (type 1, no temporality) and **delta** (temporality 1).

Enum integers pinned from source @ `7502e7d`
(`rust/otap-dataflow/crates/pdata/src/otlp/metrics.rs`, `#[repr(u8)] MetricType`):
`Empty=0 Gauge=1 Sum=2 Histogram=3 ExponentialHistogram=4 Summary=5`;
`aggregation_temporality` is the OTLP enum (`UNSPECIFIED=0 DELTA=1 CUMULATIVE=2`).

**Runtime evidence (off the wire):** 20 cumulative Sum + 20 Gauge + 40 spans + 100
logs fed through **one** `signals` pipeline. Emitted: Gauge **20/20 kept**,
cumulative Sum **0/20 (dropped)**, spans **40/40 kept + tagged**, logs **50 ERROR /
50 CLEARED** with **50 redacted / 0 e-mail leaked** — i.e. the metric drop, the
span pass-through, and the P-SEV/P-PII log parity all hold **simultaneously**. That
`metric_type` and `aggregation_temporality` are genuinely *read* (not the KQL
failure mode) is proven per-predicate in isolation: `where metric_type == 1` keeps
exactly the 20 Gauges; `where aggregation_temporality == 2` keeps exactly the 20
cumulative Sums.

| | |
|---|---|
| **Runtime finding (semantics)** | A single `and` combining `not(aggregation_temporality == 2)` with `metric_type != 5` **spuriously drops Gauges** — a Gauge has no `aggregation_temporality`, and the `and` mishandles the absent field (standalone `where not(absent == 2)` keeps the record; inside the `and` it drops). **Chained `where` filters are the correct form** and are what the deliverable uses. Worth a docs/semantics note upstream. |
| **Scope boundary (what this does NOT do)** | This exercises the **OTLP-proto exporter path** (`exporter:otlp_http`) at **telemetrygen scale / low cardinality**. It does **not** exercise or refute the separate **Arrow/OTAP metrics-*encoder* `boo` panic** and `DictionaryKeyOverflowError` (see Q2 below) — those are encode-path defects on high-cardinality real workload, not transform-language limits. It also does **not** re-open the benchmark arm (DNF, ISI-1849). This is purely the upstream-conversation capability answer. |
| **Relation to Q2** | Q2 routed metrics to a noop because the *encoder* panics. OPL's ability to *drop by type/temporality* is an orthogonal, now-demonstrated capability of the transform language; it would let an operator drop Dynatrace-rejected metrics explicitly rather than route the whole signal away — but only over an export path the metrics encoder survives. |

---

### Q2 — Arrow arm delivers logs and traces only; metrics tiles are empty BY DESIGN

> 🛑 **MOOT — the arrow arm is DNF and both its phases are cancelled** (ISI-1849 / ISI-1817 /
> ISI-1820, 2026-07-23). This decision is kept as the record of what was *decided and built*,
> not of what was measured: the arm died at the validation gate twice and produced no run, so
> nothing below was ever exercised under timed load. Read it as history. The one row that
> must **not** be applied as written is **Dashboard caveat** — see its superseding note.

> **Upstream:** reported as [open-telemetry/otel-arrow#3561](https://github.com/open-telemetry/otel-arrow/issues/3561) (2026-07-23, `bug` /
> `triage:deciding`). The `boo` metrics-encoder panic is separately root-caused upstream by
> draft PR #2984, unmerged at our build SHA. ⚠️ The `DictionaryKeyOverflowError` is **not**
> resolved by this arm's metrics routing: the retry shows it still kills all four cores at
> T+26m10s with metrics fully disconnected, from **two** sites — `arrow-data` and
> `crates/pdata/src/otap/transform/concatenate.rs:150`. Routing metrics away removes only
> the `boo` site. A correction to #3561 is drafted at
> `results/r1p3-abort/UPSTREAM-3561-FOLLOWUP.md` and **POSTED 2026-07-23T16:46:50Z** by
> @henrikrexed as
> <https://github.com/open-telemetry/otel-arrow/issues/3561#issuecomment-5061029145>
> (ISI-1850). ⚠️ **Partial.** The posted body is 3081 bytes against the prepared 4742: it
> carries the correction and the second panic site, but **not** the `metric_sets` 289→1
> detection mechanism, the still-present-on-current-`main` check, or the closing offer.
> Gap tracked as an addendum comment; paste-ready bytes are
> `results/r1p3-abort/UPSTREAM-3561-FOLLOWUP.paste.md` (full) and
> `UPSTREAM-3561-ADDENDUM.paste.md` (the delta). Post the `.paste.md` files, never the
> drafting file, which carries a non-public header.

| | |
|---|---|
| **Arms affected** | OTel-Arrow native (R1P3, R2P3) only |
| **What happens** | df_engine 0.50.0 panics inside its own metrics encoder (`crates/pdata/src/encode/record/metrics.rs`, panic message literally `boo`) and inside Arrow encoding (`DictionaryKeyOverflowError`). Both sites are hit within one minute of real workload telemetry; all four pipeline cores die with no restart. |
| **Config response** | `processor:type_router` splits the pipeline immediately after the receiver: `router["logs"]` and `router["traces"]` continue to the processing chain and the DT exporter; `router["metrics"]` routes to `exporter:noop`. Drop is explicit, deterministic, and counted by `processor.signal_type_router.signals_routed_named_metrics`. |
| **What the other two arms do** | Both carry metrics through a `cumulativetodelta` conversion and export them to DT. |
| **Relation to D0** | The arrow arm had no banked R1 row, so this config change was open. It is not a workaround to preserve an old result; it is the honest fix that makes the arm runnable while exposing what version 0.50.0 can and cannot do. |
| **attr-landing verdict** | `results/attr-landing.sh --gate` must predict `metrics=NO-DATA` for R1P3 and R2P3. `NO-DATA` is its own verdict and must never fold into `SAFE` ("did not run" ≠ "passed"). |
| **Dashboard caveat** | ~~R1P3/R2P3 metrics tiles will be empty or report zero, and must carry a "*metrics empty by design*" note.~~ **SUPERSEDED 2026-07-23 (ISI-1820).** The arrow arm never ran, so **every** arrow tile is empty — metrics, logs and traces alike — and the reason is DNF, not design. Do **not** put "empty by design" next to an arrow tile: on camera that reads as *the arm ran and chose to drop metrics*, which is false. The correct note is *"OTel-Arrow did not complete a run — see `results/r1p3-dnf/DNF.md`."* Better still, remove the arrow series from the comparison dashboard entirely rather than showing an empty column. |
| **Camera sentence** | *"The Arrow engine carries logs and traces in this benchmark. Metrics are routed to a noop exporter — by construction, not by failure. Version 0.50.0's metrics encoder panics on the cumulative-Sum workload this cluster produces, and it has no cumulative-to-delta converter. We are treating that as the finding it is: a production-readiness gap that this version has not yet closed."* |

---

### Q6 — Batch size stays engine-idiomatic; batch duration is aligned

| | |
|---|---|
| **Arms affected** | All three, different knob sets |
| **Collector** | `send_batch_size: 8192`, `send_batch_max_size: 16384`, `timeout: 1s` |
| **Fluent Bit v5** | No batch-size knob in the `opentelemetry` output; effective batch is whatever fills before `flush: 1s` |
| **Arrow native** | `otap: {min_size: 1000, sizer: items}`, `max_batch_duration: 1s` |
| **What is aligned** | **Duration** — all three flush within 1 s of the first record in a batch. This was the ISI-1843 correction on the arrow arm (`max_batch_duration: 1s`). |
| **What is not aligned** | **Size** — Collector batches up to 8 192 items, Arrow keeps its idiomatic 1 000, Fluent Bit has no equivalent knob. Forcing equality would require reading a knob Fluent Bit does not expose, or setting the Collector's batch 8× smaller in a frozen arm. Neither is possible. |
| **Same treatment as** | The hash-vs-mask asymmetry and the `k8sattributes`-vs-static enrichment gap: name it, measure both signal and outcome. |
| **Camera sentence** | *"We aligned the batch flush interval to one second across all three engines. The batch size — how many records each flush carries — stays engine-idiomatic: eight thousand for the Collector, a thousand for the Arrow engine, and whatever fits a second for Fluent Bit. That difference influences per-flush overhead; it is a configuration reality, not a hidden variable."* |

---

### Q7 — Export resilience is not aligned; loss is measured, not averaged away

| | |
|---|---|
| **Arms affected** | All three — different capability levels |
| **Collector** | `retry_on_failure: {enabled: true}` (exponential backoff, 300 s cap) + `sending_queue: {enabled: true, queue_size: 5000}` |
| **Fluent Bit v5** | `retry_limit: 5` in the `opentelemetry` output; no persistent queue |
| **Arrow native** | `client_pool_size: 4`, no retry config, no queue |
| **Why not aligned** | Normalising would erase a genuine product difference. The Collector's queue and backoff are features; demonstrating that they exist (and cost RAM) is part of the benchmark's value. Making all three identical would hide the Collector's advantage on a noisy network and the Arrow engine's lack of retry — exactly what a viewer of this content needs to understand. |
| **How loss is measured** | **Every RUN-REGISTER row must record:** (a) delivered-vs-emitted per signal (logs, traces, metrics) from the DT ingest counters and each engine's own telemetry; (b) engine-side 4xx/5xx count from the exporter's built-in metrics. Loss is never averaged across signals or folded into a summary number that obscures which signal was affected. |
| **Camera sentence** | *"Export resilience is intentionally different across the three engines. The Collector has retry-on-failure with an in-memory queue. Fluent Bit will retry up to five times per batch. The Arrow engine has neither retry nor queue in this version — what the exporter cannot deliver is dropped. We measure that difference on every run: delivered versus emitted, per signal."* |

---

### Q8 — Fluent Bit keeps its 256 Mi memory request

| | |
|---|---|
| **Arms affected** | Fluent Bit (Phase 2) vs. Collector and Arrow (both 512 Mi) |
| **Requests** | Fluent Bit: `cpu: 500m, memory: 256Mi`; Collector and Arrow: `cpu: 500m, memory: 512Mi` |
| **Limits** | All three: `cpu: 4, memory: 2Gi` — identical |
| **Metric used** | `dt.kubernetes.container.memory_working_set` — actual RSS-equivalent, unaffected by the request |
| **Why the request does not matter** | A `resources.requests` is a Kubernetes scheduler input. It sets the pod's guaranteed floor for scheduling decisions and QoS class; it neither caps nor floors what the container actually uses. All three arms land in the `Burstable` QoS class regardless, because none of them set `requests == limits`. The measured metric is `memory_working_set`, which reflects what the kernel has allocated to the process — a `256Mi` request does not constrain it below a `2Gi` limit. |
| **Refusal is falsifiable** | This decision reopens immediately if you can demonstrate a mechanism by which the request moves `memory_working_set` on this cluster under this workload. The load-bearing argument is the one above; if that argument is wrong, the evidence to refute it is to show the working-set difference across two identical configs differing only in the request value. |
| **Camera sentence** | *"Fluent Bit's memory request is half the other two engines' — 256 megabytes versus 512. The memory limit is two gigabytes on all three. The number we compare is the actual working-set reported by Kubernetes — that is what the kernel gave each process, regardless of what was requested. A scheduling input does not cap or floor the measured metric."* |

---

### SNUM — severity_text = ERROR does not imply severity_number = Error

| | |
|---|---|
| **Arms affected** | OTel-Arrow native (R1P3, R2P3) — but the issue is latent on all three arms for different reasons |
| **What happens** | The Arrow arm's `processor:transform` writes `severity_text = 'ERROR'` unconditionally (see P-SEV). It does **not** write `severity_number`. OTLP `severity_number` carries the original emitted value, which for most structured log sources is `Info (9)` or lower. A dashboard tile that colour-codes by level will show these records as INFO while `severity_text` says ERROR. |
| **Why severity is not a measured axis** | The parity work (step 2) is the timed processing — a real per-record write that takes CPU and memory. The semantic content of `severity_text` is not what we measure; CPU, memory, wire bytes, and loss are. |
| **What a readout must not do** | Treat `severity_text = ERROR` as a valid severity indicator for the arrow arm. A filter like `severity_text == "ERROR"` will return records whose `severity_number` is INFO, producing a believable but wrong distribution. |
| **Camera sentence** | *"The severity field we write is a processing marker, not a true severity indicator — we are measuring whether each engine can write a field under load, not whether the log was actually an error. Do not use it for filtering in the comparison dashboard."* |

---

### MEM-LIM — memory\_limiter is Collector-only

| | |
|---|---|
| **Arms affected** | Collector has `memory_limiter`; Fluent Bit and Arrow do not |
| **Collector** | `memory_limiter: {check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 20}` — must be first in the pipeline |
| **Fluent Bit v5** | `mem_buf_limit` on the input plugin — a storage-layer cap, not a pipeline processor |
| **Arrow native** | `channel_capacity: {control: {node: 100, pipeline: 100}, pdata: 128}` — back-pressure via channel depth, not memory sampling |
| **Why not aligned** | These are structurally different mechanisms attached at different layers. The Collector's `memory_limiter` adds approximately one predicate evaluation per record per second; at benchmark throughput this is noise, but it is a real difference. Fluent Bit's and Arrow's alternatives serve the same purpose (preventing OOM) via different primitives that are not equivalent config knobs. |
| **Camera sentence** | *"The Collector runs a memory-limiter processor that checks the process footprint once a second and starts dropping if it exceeds eighty percent of its limit. Fluent Bit and the Arrow engine use different back-pressure mechanisms. This is a per-engine design choice, not a benchmark variable."* |

---

## Run-Register Requirements (from Q7)

The following columns are **mandatory** in every RUN-REGISTER row to satisfy the Q7 disclosure:

| Column | Source | Notes |
|--------|--------|-------|
| `logs_emitted` | Engine self-telem (`otelcol_receiver_accepted_log_records` / FluentBit `fluentbit_input_records_total` / df_engine `otap.receiver_received`) | Before the processing chain |
| `logs_delivered` | DT ingest accepted count (DQL `fetch logs | summarize count()` scoped to window + `benchmark.engine`) | After export |
| `traces_emitted` | Same sources, spans dimension | |
| `traces_delivered` | DT `fetch spans | summarize count()` | |
| `metrics_emitted` | Same sources, metrics dimension | Arrow arm: `router["metrics"]` routed to noop → emitted count still measurable |
| `metrics_delivered` | Arrow arm: 0 BY DESIGN (noop). Others: DT metric-ingest count | |
| `exporter_4xx` | Engine telemetry export error counter | Collector: `otelcol_exporter_send_failed_*`; Fluent Bit: `fluentbit_output_retries_failed_total`; Arrow: `otlp_http.request_errors` or equivalent |
| `exporter_5xx` | Same as above, 5xx partition if available | |

A RUN-REGISTER row that does not carry these columns cannot be used to evaluate loss. It is not
acceptable to average delivered across signals or to cite a global "loss ≈ 0" without per-signal
breakdown when one signal (arrow metrics) is never delivered by construction.

---

## Status Summary

> 🛑 **The "Arrow native" column below describes a build, not a measurement.** The arm is DNF
> (ISI-1849) and both phases are cancelled (R1P3/ISI-1817, R2P3/ISI-1820), so no arrow value
> in this table was ever confirmed under timed load. The **only two engines in the campaign
> readout are Collector and Fluent Bit v5** — every arrow-vs-other comparison here is a
> comparison of *configurations*, never of results.

| Item | Collector | Fluent Bit v5 | Arrow native (DNF — config only) | Status |
|------|-----------|---------------|--------------|--------|
| Step 1: static attrs | ✅ | ✅ | ✅ | Closed |
| Step 2: severity normalise | ✅ conditional | ✅ conditional | ✅ conditional (OPL, ISI-1859) | **P-SEV RETRACTED** |
| Step 3: PII redact | ✅ substring mask | ⚠️ whole-value hash | ✅ whole-value hash (OPL, ISI-1859) | **P-PII retracted; hash-not-substring nuance** |
| Step 4: drop log.file.path | ✅ | ✅ | ✅ (ISI-1843) | Closed |
| Step 5: batch | ✅ size+duration | ⚠️ duration only | ⚠️ size 1 000, duration 1 s | **Disclosed Q6** |
| Q2: metrics signal | ✅ delivered | ✅ delivered | ⚠️ noop BY DESIGN | **Disclosed Q2** |
| Metric drop (cumulative + Summary) | ✅ filter/OTTL | ✅ Lua/selector | ✅ OPL `where` (OPL, ISI-1859) | **P-MET — runtime-proven, OTLP path** |
| Multi-signal transform (logs+metrics+traces) | ✅ | ✅ | ✅ one `signals` pipeline (OPL, ISI-1859) | **P-MET — 11/11 PASS** |
| Q7: export resilience | ✅ retry+queue | ⚠️ retry only | ❌ none | **Disclosed Q7 + measured** |
| Q8: memory request | 512 Mi | 256 Mi | 512 Mi | **Disclosed Q8** |
| severity\_number alignment | not an issue | not an issue | ⚠️ INFO despite text=ERROR | **Disclosed SNUM** |
| memory\_limiter | ✅ | ❌ (different mechanism) | ❌ (channel back-pressure) | **Disclosed MEM-LIM** |
