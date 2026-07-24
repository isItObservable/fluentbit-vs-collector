# ISI-1859 step B — multi-signal OPL evidence (df_engine 0.50.0 @ 7502e7d)

Henrik's ask (2026-07-24): filter cumulative + Summary metrics (Dynatrace rejects
them) and re-run to cover the trace / span / metric / log scenario, not just logs.

**All runtime, off the wire** (debug sink), unchanged `7502e7d` image, no rebuild.
`--validate-and-exit` is worthless on this engine — every number is emitted bytes.

## Enum integers, pinned from source @ 7502e7d
`rust/otap-dataflow/crates/pdata/src/otlp/metrics.rs` — `#[repr(u8)] MetricType`:
`Empty=0 Gauge=1 Sum=2 Histogram=3 ExponentialHistogram=4 Summary=5`.
`aggregation_temporality` = OTLP enum: `UNSPECIFIED=0 DELTA=1 CUMULATIVE=2`.

Language support confirmed from the shipped OPL guide @ 7502e7d
(`.../query-engine-languages/docs/opl-user-guide/`): sources `logs`/`traces`/`metrics`/`signals`;
`is Log`/`is Metric`/`is Span`; verbs `where`, `drop`, `set`, `route_to`;
metric fields `metric_type`, `aggregation_temporality`, `is_monotonic` are readable.

## Predicate-isolation matrix (metrics root, 20 Gauge + 20 cumulative Sum sent)

| OPL query | Gauge kept | Sum kept | reading proven |
|---|---:|---:|---|
| `metrics \| set attributes["t"]="1"` (identity) | 20 | 20 | metrics traverse transform |
| `metrics \| where metric_type == 1` | 20 | 0 | `metric_type` read; Gauge=1 |
| `metrics \| where metric_type != 5` | 20 | 20 | Summary(5)-drop keeps non-Summary |
| `metrics \| where not(aggregation_temporality == 2)` | 20 | 0 | cumulative(2) dropped, Gauge kept |
| `metrics \| where aggregation_temporality == 2` | 0 | 20 | keeps only cumulative |
| `metrics \| where not(aggregation_temporality==2) and metric_type != 5` | **0** | **0** | ⚠️ `and` BUG: drops Gauges too |
| `metrics \| where not(aggregation_temporality==2) \| where metric_type != 5` | **20** | **0** | ✅ chained = correct drop |

**Finding:** a single `and` combining a `not(field==x)` predicate on an *absent*
field (Gauge has no `aggregation_temporality`) with a second predicate spuriously
drops the record. Each predicate is decisive alone and composes correctly when
**chained** (`| where … | where …`). Chained is the deliverable form.

## Full multi-signal run — `verify-multisignal.sh` = 11/11 PASS

OPL under test (`processor:transform`, `opl_query`):
```
signals
| if (is Metric) { where not(aggregation_temporality == 2) | where metric_type != 5 }
| if (is Log) { if (contains(body, "error")) { set severity_text = "ERROR" } else { set severity_text = "CLEARED" } }
| if (is Log) { if (matches(body, r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9._-]+")) { set attributes["pii.email.detected"] = "true", body = concat("REDACTED:", encode(sha256(body), "hex")) } }
| if (is Span) { set attributes["parity.seen"] = "true" }
```
Sent: 20 cumulative Sum, 20 Gauge, 40 spans, 50 error logs, 50 clean logs.

| observed off the wire | count | proves |
|---|---:|---|
| Gauge metrics kept | 20 | Dynatrace-accepted survives |
| cumulative Sum dropped | 0 (of 20) | cumulative drop fired |
| spans kept + tagged | 40 / 40 | traces traverse transform |
| logs total | 100 | logs unaffected by metric/span branches |
| severity ERROR / CLEARED | 50 / 50 | conditional severity (field read) |
| PII flagged / body redacted | 50 / 50 | field-read + redact |
| original e-mail leaked | 0 | redaction worked |
| engine panic / core death | 0 | transform path stable |

## Scope boundary (honest limits)
- Exercises the **OTLP-proto exporter path** at **telemetrygen scale / low
  cardinality**. Does **not** exercise or refute the separate **Arrow/OTAP
  metrics-encoder `boo` panic** / `DictionaryKeyOverflowError` (Q2) — those are
  encode-path defects on high-cardinality real workload, not transform limits.
- Does **not** synthesize a Summary *data point* on the wire (telemetrygen emits
  Gauge/Sum/Histogram only). The Summary drop is proven at the *predicate* level:
  `metric_type` is read at runtime (Gauge=1 case) and Summary=5 is pinned from
  source, so `metric_type != 5` is the correct, type-checked Summary filter.
- Does **not** re-open the benchmark arm (DNF, ISI-1849). Upstream-correctness item only.
